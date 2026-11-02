`timescale 1ns/1ps

// 平滑版音频柱状图（端口与 promax_audio_waveform 一致，可直接替换例化）
//   1. 每根柱子 = 一段 DECIMATE 个样本的绝对值最大值（包络），不再点抽样
//   2. 每 UPDATE_DIV 帧更新一次目标值，降低数据刷新率
//   3. 每帧按"快升慢落"向目标值逼近（ATTACK_SHIFT / RELEASE_SHIFT）
//   4. 右侧峰值条同样平滑，并带峰值保持横线（保持 PEAK_HOLD 帧后缓慢下落）
// 注意：pcm_tap_valid 必须是单拍握手脉冲（wav_valid && wav_ready）
module promax_audio_bars_old #(
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

    reg [7:0] cap_bank [0:SAMPLE_COUNT-1];   // 采集中的包络
    reg [7:0] tgt_bank [0:SAMPLE_COUNT-1];   // 目标值（每 UPDATE_DIV 帧刷新）
    reg [7:0] lvl_bank [0:SAMPLE_COUNT-1];   // 显示值（每帧平滑一次）
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

    wire [7:0] seg_max_next = (sample_abs > seg_max) ? sample_abs : seg_max;

    integer i;

    // ---------------- 采集 + 目标值更新 ----------------
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
            for (i = 0; i < SAMPLE_COUNT; i = i + 1)
                tgt_bank[i] <= 8'd0;
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
                        for (i = 0; i < SAMPLE_COUNT; i = i + 1)
                            tgt_bank[i] <= cap_bank[i];
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
                    cap_bank[cap_idx] <= seg_max_next;
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

    // ---------------- 每帧平滑：快升慢落 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < SAMPLE_COUNT; i = i + 1)
                lvl_bank[i] <= 8'd0;
            lvl_peak  <= 8'd0;
            hold_peak <= 8'd0;
            hold_cnt  <= 8'd0;
        end else if (frame_start) begin
            for (i = 0; i < SAMPLE_COUNT; i = i + 1) begin
                if (tgt_bank[i] > lvl_bank[i])
                    lvl_bank[i] <= lvl_bank[i] + (((tgt_bank[i] - lvl_bank[i]) >> ATTACK_SHIFT) + 8'd1);
                else if (tgt_bank[i] < lvl_bank[i])
                    lvl_bank[i] <= lvl_bank[i] - (((lvl_bank[i] - tgt_bank[i]) >> RELEASE_SHIFT) + 8'd1);
            end

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
                bar_h     = (lvl_bank[sample_index] * HALF_H) >> 7;   // 以中心线上下对称
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
