`timescale 1ns/1ps

// P2：歌曲已播放时间 MM:SS（video_clk 域，进度条右侧）
//   秒 = 样本数 / SAMPLE_RATE，分 = 秒 / 60，余数为秒；超过 99:59 显示 99:59。
//   每帧起点做两次串行除法（17 步 + 11 步，共约 30 拍），结果整帧不变。
//   字体与 timestamp_osd 相同：4×6 点阵，纵向放大 2 倍，每字 CHAR_W×12 像素。
//   像素输出是组合逻辑，和 pixel_x / pixel_y / de 同拍，后级不会错位。
module song_time_osd #(
    parameter integer TXT_X  = 520,
    parameter integer TXT_Y  = 464,
    parameter integer CHAR_W = 8,
    parameter integer SAMPLE_RATE = 48000
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
    output wire [23:0] rgb_out
);
    // ---------------- 每帧两次除法 ----------------
    // A：秒 = n / SAMPLE_RATE，商 17 位（2^32 / 48000 < 2^17），除数从 SAMPLE_RATE << 16 开始右移
    // B：分 = 秒 / 60，商 11 位（2^17 / 60 < 2^11），除数从 60 << 10 开始右移；余数就是秒
    localparam [5:0] ST_IDLE = 6'd0, ST_A = 6'd1, ST_B = 6'd18, ST_FIN = 6'd29;
    localparam [32:0] DA = SAMPLE_RATE;          // 先放进 33 位无符号，避免整数左移 16 位后变成负数
    reg        vs_q;
    wire       frame_start = vs_q && !vsync;
    reg [5:0]  step;
    reg [32:0] rem;
    reg [32:0] dsh;
    reg [16:0] q;
    wire       ge  = (rem >= dsh);
    wire [16:0] q_n = {q[15:0], ge};
    reg [3:0]  mm_t, mm_o, ss_t, ss_o;
    // 收尾：分 q（≤ 1491）、秒 rem（< 60）
    wire        over  = (q[10:0] > 11'd99);
    wire [6:0]  mm_c  = over ? 7'd99 : q[6:0];
    wire [5:0]  ss_c  = over ? 6'd59 : rem[5:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b0; step <= ST_IDLE; rem <= 33'd0; dsh <= 33'd0; q <= 17'd0;
            mm_t <= 4'd0; mm_o <= 4'd0; ss_t <= 4'd0; ss_o <= 4'd0;
        end else begin
            vs_q <= vsync;
            if (frame_start) begin
                step <= ST_A;
                rem  <= {1'b0, sample_count};
                dsh  <= DA << 16;
                q    <= 17'd0;
            end else if (step == ST_FIN) begin
                mm_t <= mm_c / 7'd10;
                mm_o <= mm_c % 7'd10;
                ss_t <= ss_c / 6'd10;
                ss_o <= ss_c % 6'd10;
                step <= ST_IDLE;
            end else if (step == ST_B - 6'd1) begin       // A 的最后一步：商就是秒，作为 B 的被除数
                rem  <= {16'd0, q_n};
                dsh  <= 33'd60 << 10;
                q    <= 17'd0;
                step <= ST_B;
            end else if (step != ST_IDLE) begin
                q    <= q_n;
                if (ge) rem <= rem - dsh;
                dsh  <= dsh >> 1;
                step <= step + 6'd1;
            end
        end
    end

    // ---------------- 字体（同 timestamp_osd）----------------
    function font_pixel;
        input [3:0] digit;
        input [3:0] col;   // 0..3
        input [3:0] row;   // 0..5 (logical row before doubling)
        begin
            case (digit)
                4'd0: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==0||col==3)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd1: font_pixel = (col==2) ||
                                   (row==0 && col==1) ||
                                   (row==2 && (col==1||col==3)) ||
                                   (row==5 && (col==1||col==2||col==3));
                4'd2: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && col==1) ||
                                   (row==4 && col==0) ||
                                   (row==5 && (col==1||col==2||col==3));
                4'd3: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                4'd4: font_pixel = (row==0 && (col==0||col==3)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==0||col==1||col==2||col==3)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && col==3);
                4'd5: font_pixel = (row==0 && (col==0||col==1||col==2||col==3)) ||
                                   (row==1 && col==0) ||
                                   (row==2 && (col==0||col==1||col==2)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                4'd6: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==0) ||
                                   (row==2 && (col==0||col==1||col==2)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd7: font_pixel = (row==0 && (col==0||col==1||col==2||col==3)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && col==2) ||
                                   (row==3 && col==2) ||
                                   (row==4 && col==2) ||
                                   (row==5 && col==2);
                4'd8: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd9: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==1||col==2||col==3)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                default: font_pixel = 1'b0;
            endcase
        end
    endfunction

    // ---------------- 像素 ----------------
    wire [11:0] dx   = pixel_x - TXT_X[11:0];
    wire [11:0] dy   = pixel_y - TXT_Y[11:0];
    wire        in_r = enable && de && (pixel_x >= TXT_X) && (pixel_x < TXT_X + 5 * CHAR_W) &&
                       (pixel_y >= TXT_Y) && (pixel_y < TXT_Y + 12);
    wire [2:0]  ci   = dx / CHAR_W;
    wire [3:0]  fcol = dx % CHAR_W;
    wire [3:0]  frow = dy[4:1];                   // 0..5
    reg         px_on;
    always @* begin
        px_on = 1'b0;
        if (in_r && fcol < 4) begin
            case (ci)
                3'd0: px_on = font_pixel(mm_t, fcol, frow);
                3'd1: px_on = font_pixel(mm_o, fcol, frow);
                3'd2: px_on = (fcol >= 1 && fcol <= 2) && (frow == 1 || frow == 4);   // 冒号
                3'd3: px_on = font_pixel(ss_t, fcol, frow);
                3'd4: px_on = font_pixel(ss_o, fcol, frow);
                default: px_on = 1'b0;
            endcase
        end
    end

    assign rgb_out = px_on ? 24'hffffff : rgb_in;
endmodule
