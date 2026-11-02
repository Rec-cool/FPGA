`timescale 1ns/1ps

// 10-29 CS：卡状态提示（video_clk 域）。图片加载完成前，屏幕中间显示一行读卡状态：
//   1 READING TF CARD...      2 PLEASE CHECK TF CARD     3 TF CARD MUST BE FAT32
//   4 NO PIC1-4.BMP ON CARD   5 CARD READ ERROR          6 LOADING PHOTO n/4
//   7 CARD ERROR - REPOWER    8 NO VALID BMP PHOTO       0 = 不显示
// 1、6 是正常过程，白字；其余是故障，琥珀色字。
// 状态来自 sd_card_bmp 的 card_status（sd_card_clk 域，慢变）：2FF + 第 3 级，连续两拍相同才采用，帧起点锁存。
// 字库同 playlist_panel（5×7），横竖各放大 3 倍，字符格 16×24；一行固定 24 格，文字已在字符串里居中。
// 像素用 pixel_x+1 提前一拍算好再寄存，输出只剩一级选择，和 pixel_x / pixel_y / de 同拍。
module card_status_osd #(
    parameter integer TXT_X = 128,          // 24 格 × 16 = 384 像素，居中
    parameter integer TXT_Y = 228
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [23:0] rgb_in,
    input  wire        enable,              // 图片还没加载完时为 1
    input  wire [5:0]  status,              // 异步：{msg[3:0], 正在加载的图号[1:0]}
    output wire [23:0] rgb_out
);
    localparam integer NCH = 24;
    localparam integer BAND_Y0 = TXT_Y - 8, BAND_Y1 = TXT_Y + 24 + 8;   // 暗灰底条，上下各留 8 行
    localparam integer BAND_X0 = TXT_X - 16, BAND_X1 = TXT_X + NCH * 16 + 16;

    localparam [NCH*8-1:0] S1 = "   READING TF CARD...   ";
    localparam [NCH*8-1:0] S2 = "  PLEASE CHECK TF CARD  ";
    localparam [NCH*8-1:0] S3 = " TF CARD MUST BE FAT32  ";
    localparam [NCH*8-1:0] S4 = " NO PIC1-4.BMP ON CARD  ";
    localparam [NCH*8-1:0] S5 = "    CARD READ ERROR     ";
    localparam [NCH*8-1:0] S6 = "    LOADING PHOTO 0/4   ";   // 第 18 格换成图号
    localparam [NCH*8-1:0] S7 = "  CARD ERROR - REPOWER  ";
    localparam [NCH*8-1:0] S8 = "   NO VALID BMP PHOTO   ";
    localparam integer N_COL = 18;

    // ---------------- 同步 ----------------
    (* ASYNC_REG = "TRUE" *) reg [5:0] s_s1, s_s2;
    reg  [5:0] s_s3;
    reg  [5:0] st_n, st_f;
    reg        vs_q;
    wire       frame_start = vs_q && !vsync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_s1 <= 6'd0; s_s2 <= 6'd0; s_s3 <= 6'd0;
            st_n <= 6'd0; st_f <= 6'd0; vs_q <= 1'b0;
        end else begin
            s_s1 <= status;
            s_s2 <= s_s1;
            s_s3 <= s_s2;
            vs_q <= vsync;
            if (s_s2 == s_s3) st_n <= s_s3;
            if (frame_start)  st_f <= st_n;
        end
    end
    wire [3:0] msg = st_f[5:2];
    wire [1:0] pic = st_f[1:0];

    // ---------------- 字库（同 playlist_panel）----------------
    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "J": case(row) 0:glyph_row=5'b00111;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b10010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "Q": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10101;5:glyph_row=5'b10010;6:glyph_row=5'b01101;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b10101;6:glyph_row=5'b01010;default:glyph_row=0;endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "Z": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                ":": case(row) 1:glyph_row=5'b00100;2:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                ".": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                ",": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "!": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "[": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b01000;2:glyph_row=5'b01000;3:glyph_row=5'b01000;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01110; default:glyph_row=0; endcase
                "]": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b00010;5:glyph_row=5'b00010;6:glyph_row=5'b01110; default:glyph_row=0; endcase
                "=": case(row) 2:glyph_row=5'b11111;4:glyph_row=5'b11111; default:glyph_row=0; endcase
                ">": case(row) 0:glyph_row=5'b01000;1:glyph_row=5'b00100;2:glyph_row=5'b00010;3:glyph_row=5'b00001;4:glyph_row=5'b00010;5:glyph_row=5'b00100;6:glyph_row=5'b01000; default:glyph_row=0; endcase
                "-": case(row) 3:glyph_row=5'b11111;default:glyph_row=0;endcase
                "_": case(row) 6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "/": case(row) 0:glyph_row=5'b00001;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "~": case(row) 2:glyph_row=5'b01000;3:glyph_row=5'b10101;4:glyph_row=5'b00010;default:glyph_row=0;endcase   // 歌单新增：短文件名里的 ~（如 LONGFI~1）
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    function [7:0] msg_char;
        input [3:0] m;
        input [4:0] c;                       // 0 = 最左一格
        reg [NCH*8-1:0] s;
        begin
            case (m)
                4'd1: s = S1;  4'd2: s = S2;  4'd3: s = S3;  4'd4: s = S4;
                4'd5: s = S5;  4'd6: s = S6;  4'd7: s = S7;  4'd8: s = S8;
                default: s = {NCH{8'h20}};
            endcase
            msg_char = s[(NCH - 1 - c) * 8 +: 8];
        end
    endfunction

    // ---------------- 像素（提前一拍）----------------
    wire [11:0] nx      = pixel_x + 12'd1;
    wire        show    = enable && (msg != 4'd0) && (msg <= 4'd8);
    wire        in_band = show && (nx >= BAND_X0) && (nx < BAND_X1) && (pixel_y >= BAND_Y0) && (pixel_y < BAND_Y1);
    wire [11:0] tx      = nx - TXT_X;
    wire [11:0] ty      = pixel_y - TXT_Y;
    wire        in_txt  = in_band && (nx >= TXT_X) && (nx < TXT_X + NCH * 16) && (pixel_y >= TXT_Y) && (ty < 12'd21);
    wire [4:0]  col     = tx[8:4];
    wire [3:0]  cx      = tx[3:0];
    wire [2:0]  gb      = cx / 4'd3;         // 0~4 是字形列，5 是字间距
    wire [2:0]  gr      = ty[4:0] / 5'd3;    // 0~6
    wire [7:0]  ch      = (msg == 4'd6 && col == N_COL) ? ("1" + {6'd0, pic}) : msg_char(msg, col);
    wire [4:0]  grow    = glyph_row(ch, gr);
    wire        g_on    = in_txt && (gb < 3'd5) && grow[3'd4 - gb];
    wire [23:0] g_col   = (msg == 4'd1 || msg == 4'd6) ? 24'hffffff : 24'hffd040;

    reg        band_r, on_r;
    reg [23:0] col_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            band_r <= 1'b0; on_r <= 1'b0; col_r <= 24'd0;
        end else begin
            band_r <= in_band;
            on_r   <= g_on;
            col_r  <= g_col;
        end
    end

    assign rgb_out = !(de && band_r) ? rgb_in : on_r ? col_r : 24'h202830;
endmodule
