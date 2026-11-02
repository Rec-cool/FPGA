`timescale 1ns/1ps

// 平滑版音频柱状图（端口与 promax_audio_waveform 一致，可直接替换例化）
//   1. 每根柱子 = 一段 DECIMATE 个样本的绝对值最大值（包络），不再点抽样
//   2. 每 UPDATE_DIV 帧更新一次目标值，降低数据刷新率
//   3. 每帧按"快升慢落"向目标值逼近（ATTACK_SHIFT / RELEASE_SHIFT）
//   4. 右侧峰值条同样平滑，并带峰值保持横线（保持 PEAK_HOLD 帧后缓慢下落）
// 注意：pcm_tap_valid 必须是单拍握手脉冲（wav_valid && wav_ready）
//
// 资源结构（A2 优化）：
//   - 采集包络存进 2x32 乒乓 RAM：采满一组只翻转 cap_wsel，不再 32 路并行拷贝到目标组；
//   - 显示值存进 32 项 RAM：帧起点后在场消隐期用一套"快升慢落"单元逐根处理
//     （2 拍/根，共 64 拍，场同步脉冲就有 1600 拍），不再 32 套并行展开；
//   - 显示侧用 pixel_x+1 提前一拍读 RAM，像素输出与原并行写法逐拍一致。
module promax_audio_bars #(
    parameter integer WAVE_X        = 64,
    parameter integer WAVE_Y        = 400,
    parameter integer WAVE_WIDTH    = 512,
    parameter integer WAVE_HEIGHT   = 64,
    parameter integer DECIMATE      = 40,   // 每根柱子覆盖的样本数，32*DECIMATE 需明显小于 800*UPDATE_DIV
    parameter integer UPDATE_DIV    = 2,    // 每 N 帧更新一次目标值
    parameter integer ATTACK_SHIFT  = 1,    // 上升：每帧走差值的 1/2（须 >=1）
    parameter integer RELEASE_SHIFT = 3,    // 下落：每帧走差值的 1/8，越大落得越慢
    parameter integer PEAK_HOLD     = 30,   // 峰值横线保持帧数
    parameter integer BAR_GAP       = 3     // 柱间空隙像素
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire        waveform_active
);
    localparam integer SAMPLE_COUNT   = 32;
    localparam integer SAMPLE_SPACING = WAVE_WIDTH / SAMPLE_COUNT;
    localparam integer HALF_H         = WAVE_HEIGHT / 2;
    localparam integer CENTER_Y       = WAVE_Y + HALF_H;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // 0~128 的绝对值（-128 取反加一仍为 8'h80=128）
    wire [7:0] sample_abs = pcm_tap_left[15] ?
                            (~pcm_tap_left[15:8] + 1'b1) : pcm_tap_left[15:8];

    reg [5:0] cap_idx;
    reg [7:0] dec_cnt;
    reg [7:0] seg_max;
    reg [7:0] cap_peak;
    reg [7:0] tgt_peak;
    reg [7:0] lvl_peak;
    reg [7:0] hold_peak;
    reg [7:0] hold_cnt;
    reg [3:0] div_cnt;
    reg       display_valid;
    reg       cap_wsel;          // 采集写哪一组；另一组就是目标组

    wire [7:0] seg_max_next = (sample_abs > seg_max) ? sample_abs : seg_max;
    wire       cap_we = !frame_start && pcm_tap_valid && cap_idx < SAMPLE_COUNT &&
                        dec_cnt == DECIMATE - 1;

    // ---------------- 采集 + 目标组翻转 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y        <= 12'd0;
            de_q          <= 1'b0;
            vs_q          <= 1'b1;
            cap_idx       <= 6'd0;
            dec_cnt       <= 8'd0;
            seg_max       <= 8'd0;
            cap_peak      <= 8'd0;
            tgt_peak      <= 8'd0;
            div_cnt       <= 4'd0;
            display_valid <= 1'b0;
            cap_wsel      <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                if (div_cnt == UPDATE_DIV - 1) begin
                    div_cnt <= 4'd0;
                    if (cap_idx == SAMPLE_COUNT) begin
                        cap_wsel      <= ~cap_wsel;    // 刚采满的一组成为目标组
                        tgt_peak      <= cap_peak;
                        display_valid <= 1'b1;
                    end
                    cap_idx  <= 6'd0;
                    dec_cnt  <= 8'd0;
                    seg_max  <= 8'd0;
                    cap_peak <= 8'd0;
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end else if (pcm_tap_valid && cap_idx < SAMPLE_COUNT) begin
                if (dec_cnt == DECIMATE - 1) begin
                    if (seg_max_next > cap_peak) cap_peak <= seg_max_next;
                    cap_idx <= cap_idx + 1'b1;
                    dec_cnt <= 8'd0;
                    seg_max <= 8'd0;
                end else begin
                    dec_cnt <= dec_cnt + 1'b1;
                    seg_max <= seg_max_next;
                end
            end
        end
    end

    // ---------------- 每帧平滑：逐根顺序处理 ----------------
    // 帧起点锁存"旧"目标组与 display_valid，等价于原写法里同拍非阻塞读到的旧 tgt_bank。
    // 目标组翻转后变成采集组，但采集要再过 DECIMATE 个样本才写第一项，64 拍内不会被覆盖。
    reg       sm_busy;
    reg       sm_phase;          // 0=发读地址 1=计算并回写
    reg [4:0] sm_idx;
    reg       sm_tsel;
    reg       sm_tvalid;         // 目标组是否有效（无效时按 0 处理，同原复位值）
    reg       sm_clear;          // 复位后第一遍：显示值清零（RAM 没有复位）
    reg       lvl_clear_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_busy           <= 1'b0;
            sm_phase          <= 1'b0;
            sm_idx            <= 5'd0;
            sm_tsel           <= 1'b0;
            sm_tvalid         <= 1'b0;
            sm_clear          <= 1'b0;
            lvl_clear_pending <= 1'b1;
        end else if (frame_start) begin
            sm_busy           <= 1'b1;
            sm_phase          <= 1'b0;
            sm_idx            <= 5'd0;
            sm_tsel           <= ~cap_wsel;
            sm_tvalid         <= display_valid;
            sm_clear          <= lvl_clear_pending;
            lvl_clear_pending <= 1'b0;
        end else if (sm_busy) begin
            sm_phase <= ~sm_phase;
            if (sm_phase) begin
                sm_idx <= sm_idx + 1'b1;
                if (sm_idx == SAMPLE_COUNT - 1)
                    sm_busy <= 1'b0;
            end
        end
    end

    // 采集 RAM：{组, 柱号}，一写一读
    reg [7:0] cap_ram [0:2*SAMPLE_COUNT-1];
    reg [7:0] cap_q;
    always @(posedge clk) begin
        if (cap_we)
            cap_ram[{cap_wsel, cap_idx[4:0]}] <= seg_max_next;
        cap_q <= cap_ram[{sm_tsel, sm_idx}];
    end

    // 显示值 RAM：写口给平滑单元；读口平滑时给平滑单元，其余时间给显示（提前一拍）
    wire [9:0] disp_off  = pixel_x + 10'd1 - WAVE_X;
    wire [4:0] disp_addr = disp_off / SAMPLE_SPACING;
    wire [4:0] lvl_raddr = sm_busy ? sm_idx : disp_addr;
    reg  [7:0] lvl_ram [0:SAMPLE_COUNT-1];
    reg  [7:0] lvl_q;

    wire [7:0] sm_tgt = sm_tvalid ? cap_q : 8'd0;
    wire [7:0] sm_lvl = lvl_q;
    wire [7:0] sm_next = sm_clear         ? 8'd0 :
                         (sm_tgt > sm_lvl) ? sm_lvl + (((sm_tgt - sm_lvl) >> ATTACK_SHIFT) + 8'd1) :
                         (sm_tgt < sm_lvl) ? sm_lvl - (((sm_lvl - sm_tgt) >> RELEASE_SHIFT) + 8'd1) :
                                             sm_lvl;
    wire       lvl_we  = sm_busy && sm_phase;

    always @(posedge clk) begin
        if (lvl_we)
            lvl_ram[sm_idx] <= sm_next;
        lvl_q <= lvl_ram[lvl_raddr];
    end

    // 峰值条只有一份，保持原寄存器写法
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lvl_peak  <= 8'd0;
            hold_peak <= 8'd0;
            hold_cnt  <= 8'd0;
        end else if (frame_start) begin
            if (tgt_peak > lvl_peak)
                lvl_peak <= lvl_peak + (((tgt_peak - lvl_peak) >> ATTACK_SHIFT) + 8'd1);
            else if (tgt_peak < lvl_peak)
                lvl_peak <= lvl_peak - (((lvl_peak - tgt_peak) >> RELEASE_SHIFT) + 8'd1);

            // 峰值保持：刷新到更高值后保持 PEAK_HOLD 帧，再每帧落 1
            if (lvl_peak >= hold_peak) begin
                hold_peak <= lvl_peak;
                hold_cnt  <= PEAK_HOLD;
            end else if (hold_cnt != 8'd0) begin
                hold_cnt <= hold_cnt - 1'b1;
            end else begin
                hold_peak <= hold_peak - 1'b1;
            end
        end
    end

    // ---------------- 显示 ----------------
    integer sample_index;
    integer col_off;
    integer bar_h;
    integer dy;
    integer peak_h;
    integer hold_h;
    reg bar_pixel;
    reg bar_tip;
    reg axis_pixel;
    reg peak_pixel;
    reg hold_pixel;

    always @* begin
        sample_index = 0;
        col_off      = 0;
        bar_h        = 0;
        dy           = 0;
        peak_h       = (lvl_peak  * WAVE_HEIGHT) >> 7;
        hold_h       = (hold_peak * WAVE_HEIGHT) >> 7;
        bar_pixel    = 1'b0;
        bar_tip      = 1'b0;
        axis_pixel   = 1'b0;
        peak_pixel   = 1'b0;
        hold_pixel   = 1'b0;

        if (enable && de && pixel_x >= WAVE_X &&
            pixel_x < WAVE_X + WAVE_WIDTH &&
            line_y >= WAVE_Y && line_y < WAVE_Y + WAVE_HEIGHT) begin
            axis_pixel   = (line_y == CENTER_Y);
            sample_index = (pixel_x - WAVE_X) / SAMPLE_SPACING;
            col_off      = (pixel_x - WAVE_X) % SAMPLE_SPACING;
            dy           = (line_y >= CENTER_Y) ? (line_y - CENTER_Y) : (CENTER_Y - line_y);
            if (display_valid && sample_index < SAMPLE_COUNT &&
                col_off < SAMPLE_SPACING - BAR_GAP) begin
                bar_h     = (lvl_q * HALF_H) >> 7;                      // 以中心线上下对称
                bar_pixel = (dy <= bar_h);
                bar_tip   = bar_pixel && (dy >= (HALF_H * 3) / 4);    // 接近满幅的部分变色
            end
        end

        if (enable && de && pixel_x >= WAVE_X + WAVE_WIDTH + 8 &&
            pixel_x < WAVE_X + WAVE_WIDTH + 16 &&
            line_y >= WAVE_Y && line_y < WAVE_Y + WAVE_HEIGHT) begin
            peak_pixel = (line_y >= WAVE_Y + WAVE_HEIGHT - peak_h);
            hold_pixel = (hold_h != 0) &&
                         (line_y == WAVE_Y + WAVE_HEIGHT - hold_h ||
                          line_y == WAVE_Y + WAVE_HEIGHT - hold_h + 1);
        end
    end

    assign waveform_active = bar_pixel || axis_pixel || peak_pixel || hold_pixel;
    assign rgb_out = bar_tip    ? 24'hffd040 :
                     bar_pixel  ? 24'h20ff90 :
                     hold_pixel ? 24'hffffff :
                     peak_pixel ? 24'hffb020 :
                     axis_pixel ? 24'h406060 : rgb_in;
endmodule
