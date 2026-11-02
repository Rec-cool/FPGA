`timescale 1ns/1ps

// L1：歌单面板（video_clk 域，画面右侧半透明暗底）
//   第 0 行：PLAYLIST NN/MM MOD（当前第几首 / 总数 / 播放模式 SEQ ONE RND）
//   第 1~count 行：[>]NN NAMEXXXX MM:SS（正在播放的一行前面加 ">"，黄色）
//   名字是 FAT 8.3 短文件名的前 8 个字符（扩展名不显示）；时长 = 扇区数 × 256 / 48000，超过 99:59 显示 99:59。
//   L2：选歌光标所在行画蓝底（光标由 sd 域的 KEY1 短按移动，随 pl_bus 送过来）。
// 数据来源：sd_card_clk 域的 pl_bus，每个下标保持 256 拍（这里约 64 拍），按 0~15 循环。
//   这里 3 级同步，连续两拍相同才采用（同 R1 分辨率）；每来一个新下标就把名字写进本地表，
//   再做两次串行除法（17 步 + 11 步）算出时长写进本地表。count/当前曲目/模式在帧起点锁存，整帧不变。
// 像素：用 pixel_x+1 提前一拍算好"是否在面板内 / 是否字形点 / 颜色"并寄存，输出只剩一级选择，
//   所以对外仍和 pixel_x / pixel_y / de 同拍（同 promax_audio_bars 的做法）。
module playlist_panel #(
    parameter integer BOX_X = 416,          // 面板左上角
    parameter integer BOX_Y = 80,
    parameter integer NCH   = 18,           // 每行字符数
    parameter integer CW    = 12,           // 字符格宽（5×7 字形横竖各放大 2 倍，同参数栏）
    parameter integer PAD   = 4             // 文字离面板边的距离；行高固定 16
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         vsync,
    input  wire         de,
    input  wire [11:0]  pixel_x,
    input  wire [11:0]  pixel_y,
    input  wire [23:0]  rgb_in,
    input  wire         enable,
    // 异步（sd_card_clk 域）：{cursor[3:0], count[4:0], cur[3:0], mode[1:0], idx[3:0], name[63:0], sectors[23:0]}
    input  wire [106:0] pl_bus,
    output wire [23:0]  rgb_out
);
    localparam integer TX    = BOX_X + PAD;
    localparam integer TY    = BOX_Y + PAD;
    localparam integer BOX_W = NCH * CW + 2 * PAD;

    // ---------------- 同步 ----------------
    (* ASYNC_REG = "TRUE" *) reg [106:0] b_s1, b_s2;
    reg  [106:0] b_s3;
    wire         stable = (b_s2 == b_s3);
    wire [3:0]   b_csr  = b_s3[106:103];
    wire [4:0]   b_cnt  = b_s3[102:98];
    wire [3:0]   b_cur  = b_s3[97:94];
    wire [1:0]   b_mode = b_s3[93:92];
    wire [3:0]   b_idx  = b_s3[91:88];
    wire [63:0]  b_name = b_s3[87:24];
    wire [23:0]  b_sec  = b_s3[23:0];

    reg        vs_q;
    wire       frame_start = vs_q && !vsync;
    reg [4:0]  cnt_n, cnt_f;            // _n：最新稳定值；_f：本帧使用
    reg [3:0]  cur_n, cur_f;
    reg [1:0]  mode_n, mode_f;
    reg [3:0]  csr_n, csr_f;

    // ---------------- 本地表 ----------------
    (* ram_style = "dram" *) reg [63:0] name_tab [0:15];
    (* ram_style = "dram" *) reg [15:0] dur_tab  [0:15];   // {分十位, 分个位, 秒十位, 秒个位}

    // ---------------- 时长：两次串行除法 ----------------
    // A：秒 = (扇区数 × 2) / 375，商 17 位；B：分 = 秒 / 60，商 11 位，余数为秒
    localparam [5:0] ST_IDLE = 6'd0, ST_A = 6'd1, ST_B = 6'd18, ST_FIN = 6'd29;
    reg [5:0]  step;
    reg [3:0]  w_idx;
    reg        have_idx;
    reg [3:0]  last_idx;
    reg [25:0] rem;
    reg [25:0] dsh;
    reg [16:0] q;
    wire        ge   = (rem >= dsh);
    wire [16:0] q_n  = {q[15:0], ge};
    wire        over = (q[10:0] > 11'd99);
    wire [6:0]  mm_c = over ? 7'd99 : q[6:0];
    wire [5:0]  ss_c = over ? 6'd59 : rem[5:0];
    wire [3:0]  mm_t = mm_c / 7'd10, mm_o = mm_c % 7'd10;
    wire [3:0]  ss_t = ss_c / 6'd10, ss_o = ss_c % 6'd10;
    // 每个新下标处理一次（下标每约 64 拍换一个，除法约 30 拍做完）
    wire       take = stable && step == ST_IDLE && (!have_idx || b_idx != last_idx);

    always @(posedge clk) begin
        if (take)
            name_tab[b_idx] <= b_name;
        if (step == ST_FIN)
            dur_tab[w_idx] <= {mm_t, mm_o, ss_t, ss_o};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_s1 <= 107'd0; b_s2 <= 107'd0; b_s3 <= 107'd0; vs_q <= 1'b0;
            csr_n <= 4'd0; csr_f <= 4'd0;
            cnt_n <= 5'd0; cnt_f <= 5'd0; cur_n <= 4'd0; cur_f <= 4'd0; mode_n <= 2'd0; mode_f <= 2'd0;
            step <= ST_IDLE; w_idx <= 4'd0; have_idx <= 1'b0; last_idx <= 4'd0;
            rem <= 26'd0; dsh <= 26'd0; q <= 17'd0;
        end else begin
            b_s1 <= pl_bus;
            b_s2 <= b_s1;
            b_s3 <= b_s2;
            vs_q <= vsync;
            if (stable) begin
                cnt_n <= b_cnt; cur_n <= b_cur; mode_n <= b_mode; csr_n <= b_csr;
            end
            if (frame_start) begin
                cnt_f <= cnt_n; cur_f <= cur_n; mode_f <= mode_n; csr_f <= csr_n;
            end
            if (take) begin
                have_idx <= 1'b1;
                last_idx <= b_idx;
                w_idx    <= b_idx;
                rem      <= {1'b0, b_sec, 1'b0};             // 扇区数 × 2
                dsh      <= 26'd375 << 16;
                q        <= 17'd0;
                step     <= ST_A;
            end else if (step == ST_FIN) begin
                step <= ST_IDLE;
            end else if (step == ST_B - 6'd1) begin            // A 的最后一步：商就是秒，作为 B 的被除数
                rem  <= {9'd0, q_n};
                dsh  <= 26'd60 << 10;
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

    // ---------------- 字库（同 promax_text_overlay，另加 "~"）----------------
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

    // ---------------- 像素（提前一拍）----------------
    wire [11:0] nx     = pixel_x + 12'd1;
    wire [4:0]  rows   = cnt_f + 5'd1;                             // 标题 + 歌曲行（最多 17）
    wire [11:0] box_h  = {3'd0, rows, 4'd0} + 2 * PAD;              // rows × 16 + 上下边
    wire        in_box = enable && (nx >= BOX_X) && (nx < BOX_X + BOX_W) &&
                         (pixel_y >= BOX_Y) && (pixel_y < BOX_Y + box_h);
    wire [11:0] tx     = nx - TX;
    wire [11:0] ty     = pixel_y - TY;
    wire        in_txt = in_box && (nx >= TX) && (nx < TX + NCH * CW) &&
                         (pixel_y >= TY) && (ty[11:4] < {3'd0, rows});
    wire [4:0]  col    = tx / CW;
    wire [3:0]  cx     = tx % CW;
    wire [4:0]  row    = ty[8:4];
    wire [3:0]  cy     = ty[3:0];
    wire [3:0]  ent    = row[3:0] - 4'd1;                          // 歌曲行对应的表项
    wire [63:0] nm     = name_tab[ent];
    wire [15:0] du     = dur_tab[ent];
    wire [4:0]  num    = {1'b0, ent} + 5'd1;                        // 序号 1~16
    wire [4:0]  curn   = {1'b0, cur_f} + 5'd1;
    wire [3:0]  num_t  = num / 5'd10,   num_o  = num % 5'd10;
    wire [3:0]  curn_t = curn / 5'd10,  curn_o = curn % 5'd10;
    wire [3:0]  cnt_t  = cnt_f / 5'd10, cnt_o  = cnt_f % 5'd10;
    reg  [7:0]  ch;
    always @* begin
        ch = " ";
        if (row == 5'd0) begin
            case (col)
                5'd0: ch = "P"; 5'd1: ch = "L"; 5'd2: ch = "A"; 5'd3: ch = "Y";
                5'd4: ch = "L"; 5'd5: ch = "I"; 5'd6: ch = "S"; 5'd7: ch = "T";
                5'd9:  ch = (cnt_f == 5'd0) ? "0" : "0" + curn_t;
                5'd10: ch = (cnt_f == 5'd0) ? "0" : "0" + curn_o;
                5'd11: ch = "/";
                5'd12: ch = "0" + cnt_t;
                5'd13: ch = "0" + cnt_o;
                5'd15: ch = (mode_f == 2'd0) ? "S" : (mode_f == 2'd1) ? "O" : "R";
                5'd16: ch = (mode_f == 2'd0) ? "E" : "N";
                5'd17: ch = (mode_f == 2'd0) ? "Q" : (mode_f == 2'd1) ? "E" : "D";
                default: ch = " ";
            endcase
        end else begin
            case (col)
                5'd0:  ch = (ent == cur_f) ? ">" : " ";
                5'd1:  ch = "0" + num_t;
                5'd2:  ch = "0" + num_o;
                5'd4:  ch = nm[63:56];
                5'd5:  ch = nm[55:48];
                5'd6:  ch = nm[47:40];
                5'd7:  ch = nm[39:32];
                5'd8:  ch = nm[31:24];
                5'd9:  ch = nm[23:16];
                5'd10: ch = nm[15:8];
                5'd11: ch = nm[7:0];
                5'd13: ch = "0" + du[15:12];
                5'd14: ch = "0" + du[11:8];
                5'd15: ch = ":";
                5'd16: ch = "0" + du[7:4];
                5'd17: ch = "0" + du[3:0];
                default: ch = " ";
            endcase
        end
    end
    wire [4:0]  grow  = glyph_row(ch, cy[3:1]);
    wire [2:0]  gb    = cx[3:1];
    wire        g_on  = in_txt && (gb < 3'd5) && (cy[3:1] < 3'd7) && grow[3'd4 - gb];
    wire        in_csr = in_box && (pixel_y >= TY) && (row != 5'd0) && (ty[11:4] < {3'd0, rows}) && (ent == csr_f);   // 光标行（整行宽度都画底色）
    wire [23:0] g_col = (row == 5'd0)    ? 24'h80e0ff :
                        (ent == cur_f)   ? 24'hffd040 : 24'hffffff;

    reg        box_r, on_r, csr_r;
    reg [23:0] col_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            box_r <= 1'b0; on_r <= 1'b0; csr_r <= 1'b0; col_r <= 24'd0;
        end else begin
            box_r <= in_box;
            on_r  <= g_on;
            csr_r <= in_csr;
            col_r <= g_col;
        end
    end

    wire [23:0] dark = {1'b0, rgb_in[23:17], 1'b0, rgb_in[15:9], 1'b0, rgb_in[7:1]};   // 背景亮度减半
    assign rgb_out = !(de && box_r) ? rgb_in : on_r ? col_r : csr_r ? 24'h1c4c8c : dark;   // 光标行蓝底
endmodule
