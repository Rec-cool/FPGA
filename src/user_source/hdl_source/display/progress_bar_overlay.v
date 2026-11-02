`timescale 1ns/1ps

// P1：歌曲播放进度条（video_clk 域，叠加在音频柱状图下方）
//   进度 = 已播放样本数 / (扇区数 × SAMPLES_PER_SECTOR)，换算成 0~BAR_W 像素：
//     fill = 样本数 × BAR_W / (扇区数 × 256) = 样本数 × BAR_MUL / (扇区数 << DIV_SHIFT)
//     BAR_W = 512：BAR_MUL = 2，DIV_SHIFT = 0；BAR_W = 448：BAR_MUL = 7，DIV_SHIFT = 2（乘 7 由综合做成移位加）
//   每帧起点做一次 11 步移位相减除法（商超过 BAR_W 就钳到 BAR_W），约 12 拍，整帧使用同一个值。
//   扇区数来自 sd_card_clk 域，只在切歌时变：2FF 同步后连续两拍相同才采用。
//   像素输出是组合逻辑，和 pixel_x / pixel_y / de 同拍（同 promax_audio_bars），后级不会错位。
module progress_bar_overlay #(
    parameter integer BAR_X  = 64,
    parameter integer BAR_Y  = 468,
    parameter integer BAR_W  = 448,
    parameter integer BAR_H  = 4,
    parameter integer KNOB_W = 2,        // 游标宽
    parameter integer KNOB_EXT = 2,      // 游标上下各比进度条多出的行数
    parameter integer BAR_MUL   = 7,     // BAR_W × 2^DIV_SHIFT / 256，必须是整数（≤ 15）
    parameter integer DIV_SHIFT = 2,
    parameter integer W_SHIFT   = 9      // fill 位宽 - 1：BAR_W < 2^(W_SHIFT+1)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [23:0] rgb_in,
    input  wire        enable,           // 有歌在放（含放完到下一首之间）
    input  wire [31:0] sample_count,     // clk 域：当前歌已播放样本数
    input  wire [23:0] total_sectors,    // 异步（sd_card_clk 域），切歌时才变
    output wire [23:0] rgb_out
);
    // ---------------- 扇区数跨时钟域 ----------------
    (* ASYNC_REG = "TRUE" *) reg [23:0] sec_s1, sec_s2;
    reg [23:0] sec_s3, sec_v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_s1 <= 24'd0; sec_s2 <= 24'd0; sec_s3 <= 24'd0; sec_v <= 24'd0;
        end else begin
            sec_s1 <= total_sectors;
            sec_s2 <= sec_s1;
            sec_s3 <= sec_s2;
            if (sec_s3 == sec_s2) sec_v <= sec_s3;
        end
    end

    // ---------------- 每帧一次除法 ----------------
    // 被除数 = sample_count × BAR_MUL（36 位），除数 = sec_v << DIV_SHIFT；商 ≥ 2^QB 时算饱和
    localparam integer QB = W_SHIFT + 2;            // 求商的位数（多 1 位用来判断是否超过 BAR_W）
    localparam integer RB = 36;                     // 余数位宽（被除数 ≤ (2^32-1) × 15 < 2^36）
    localparam integer DB = 24 + DIV_SHIFT;         // 除数位宽
    wire [RB-1:0] dvd = sample_count * BAR_MUL[3:0];
    wire [DB-1:0] dvs = sec_v << DIV_SHIFT;          // 位宽按左边 DB 位计算，不会截掉高位；DIV_SHIFT=0 也合法
    reg         vs_q;
    wire        frame_start = vs_q && !vsync;
    reg  [3:0]  step;                               // 0 = 空闲
    reg  [RB-1:0] rem;
    reg  [DB+QB-2:0] dsh;                           // 除数 << (QB-1)，逐步右移
    reg  [QB-1:0] q;
    reg  [W_SHIFT:0] fill;                          // 0 ~ BAR_W
    reg         sat;                                // 被除数 ≥ 除数 << QB：一定超过 BAR_W
    wire        ge = ({{(DB+QB-1){1'b0}}, rem} >= {{RB{1'b0}}, dsh});
    wire [QB-1:0] q_n = {q[QB-2:0], ge};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b0; step <= 4'd0; rem <= {RB{1'b0}}; dsh <= {(DB+QB-1){1'b0}};
            q <= {QB{1'b0}}; fill <= {(W_SHIFT+1){1'b0}}; sat <= 1'b0;
        end else begin
            vs_q <= vsync;
            if (frame_start) begin
                step <= QB[3:0];
                rem  <= dvd;
                dsh  <= {dvs, {(QB-1){1'b0}}};
                sat  <= (dvd >> QB) >= {{(RB-DB){1'b0}}, dvs};
                q    <= {QB{1'b0}};
            end else if (step != 4'd0) begin
                q    <= q_n;
                if (ge) rem <= rem - dsh;                   // ge 时 dsh ≤ rem，结果截回 RB 位不丢信息
                dsh  <= dsh >> 1;
                step <= step - 4'd1;
                if (step == 4'd1)
                    fill <= (sec_v == 24'd0)                        ? {(W_SHIFT+1){1'b0}} :
                            (sat || q_n > BAR_W[QB-1:0])            ? BAR_W[W_SHIFT:0] : q_n[W_SHIFT:0];
            end
        end
    end

    // ---------------- 像素 ----------------
    wire [11:0] dx      = pixel_x - BAR_X[11:0];
    wire        in_x    = (pixel_x >= BAR_X) && (pixel_x < BAR_X + BAR_W);
    wire        in_bar  = enable && de && in_x && (pixel_y >= BAR_Y) && (pixel_y < BAR_Y + BAR_H);
    wire        in_kbox = enable && de && in_x && (pixel_y >= BAR_Y - KNOB_EXT) && (pixel_y < BAR_Y + BAR_H + KNOB_EXT);
    // 游标落在已播放部分的最后 KNOB_W 列；还没开始播时落在最左边
    wire [11:0] k0      = (fill >= KNOB_W) ? ({1'b0, fill} - KNOB_W) : 12'd0;
    wire        knob    = in_kbox && (dx >= k0) && (dx < k0 + KNOB_W);
    wire        played  = in_bar && (dx < {1'b0, fill});

    assign rgb_out = knob   ? 24'hffffff :
                     played ? 24'hffd040 :
                     in_bar ? 24'h404040 : rgb_in;
endmodule
