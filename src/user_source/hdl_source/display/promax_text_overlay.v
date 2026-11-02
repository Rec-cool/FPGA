`timescale 1ns/1ps

// 参数条 + 单轨 4 槽滚动弹幕。
// 渲染全部用随像素递增的字符/列计数器实现，像素路径上没有除法和乘法；
// 4 个槽共用一份 ASCII 字库和一份中文字库。
module promax_text_overlay #(
    parameter integer PARAM_X = 8,
    parameter integer PARAM_Y = 40,
    parameter integer BAR_Y = 60,
    parameter integer SUBTITLE_Y = 72,
    parameter integer H_ACTIVE = 640
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        subtitle_enable,
    input  wire [95:0] subtitle_text,
    input  wire [5:0]  subtitle_length,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire        bar_show, // 1=显示进度条行
    input  wire        bar_sel,  // 0=当前调亮度 1=当前调对比度
    input  wire [7:0]  volume,
    input  wire [31:0] period_ms,
    input  wire        auto_enabled,
    input  wire        source_scale_2x,  // 已不用：分辨率改为显示 res_* 的实际值
    // 当前图片分辨率（慢变量，已同步到 clk 域，帧起点采样）
    input  wire        res_valid,        // 0 = 这张图没读成功，显示 ----
    input  wire [15:0] res_src_w,        // 原图宽高
    input  wire [15:0] res_src_h,
    input  wire [9:0]  res_out_w,        // 缩放后图片区宽高（不含黑边）
    input  wire [8:0]  res_out_h,
    input  wire        subtitle_push,
    output wire [23:0] rgb_out,
    output wire        overlay_active
);
    localparam integer CELL_W = 12;
    localparam integer CELL_H = 16;
    localparam integer SUBTITLE_CELL_W = 18;   // 改这里要同步改发射处的 len*18 移位加
    localparam integer SUBTITLE_CELL_H = 18;
    localparam integer PARAM_CHARS = 47;
    localparam integer SUBTITLE_SPEED = 2;     // 必须 <= SUBTITLE_CELL_W
    localparam integer SUBTITLE_GAP = 24;
    localparam integer SUBTITLE_BAND_Y = SUBTITLE_Y;
    localparam integer SUBTITLE_BAND_BOTTOM = SUBTITLE_Y + SUBTITLE_CELL_H + 2;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    reg auto_frame;
    // 参数条数字在帧起点预先算好，除法不进像素路径。
    reg [7:0] bright_h, bright_t, bright_o;
    reg [7:0] vol_h, vol_t, vol_o;
    reg [7:0] period_t, period_o;
    reg [7:0] bright_percent_in;
    reg [7:0] period_seconds_in;
    wire frame_start = vs_q && !vsync;
    // 0~255 转 3 位 BCD（移位加 3），替代 /100、%100/10、%10 三个常数除法器。
    // 只在帧起点寄存一次，组合深度 8 级 4 位加法。
    function [11:0] bcd8;
        input [7:0] bin;
        integer k;
        reg [19:0] s;
        begin
            s = {12'd0, bin};
            for (k = 0; k < 8; k = k + 1) begin
                if (s[11:8]  >= 4'd5) s[11:8]  = s[11:8]  + 4'd3;
                if (s[15:12] >= 4'd5) s[15:12] = s[15:12] + 4'd3;
                if (s[19:16] >= 4'd5) s[19:16] = s[19:16] + 4'd3;
                s = s << 1;
            end
            bcd8 = s[19:8];
        end
    endfunction
    wire [11:0] bright_bcd = bcd8(bright_percent_in);
    wire [11:0] vol_bcd    = bcd8(volume);
    wire [11:0] period_bcd = bcd8(period_seconds_in);
    wire [11:0] bval_bcd   = bcd8(brightness);
    wire [11:0] cval_bcd   = bcd8(contrast);
    // 分辨率：0~9999 转 4 位 BCD（超过 9999 按 9999 显示），帧起点寄存
    function [15:0] bcd14;
        input [15:0] bin;
        integer k;
        reg [29:0] s;
        begin
            s = {16'd0, (bin > 16'd9999) ? 14'd9999 : bin[13:0]};
            for (k = 0; k < 14; k = k + 1) begin
                if (s[17:14] >= 4'd5) s[17:14] = s[17:14] + 4'd3;
                if (s[21:18] >= 4'd5) s[21:18] = s[21:18] + 4'd3;
                if (s[25:22] >= 4'd5) s[25:22] = s[25:22] + 4'd3;
                if (s[29:26] >= 4'd5) s[29:26] = s[29:26] + 4'd3;
                s = s << 1;
            end
            bcd14 = s[29:14];
        end
    endfunction
    // 4 位 BCD → 4 个字符。右对齐（宽）：高位的 0 换成空格；左对齐（高）：数字靠左、右边补空格。
    // 无效时全显示 "-"。
    function [31:0] num_rjust;
        input [15:0] d;
        input        ok;
        begin
            if (!ok)
                num_rjust = "----";
            else
                num_rjust = {(d[15:12] != 0) ? "0" + d[15:12] : " ",
                             (d[15:8]  != 0) ? "0" + d[11:8]  : " ",
                             (d[15:4]  != 0) ? "0" + d[7:4]   : " ",
                             "0" + d[3:0]};
        end
    endfunction
    function [31:0] num_ljust;
        input [15:0] d;
        input        ok;
        begin
            if (!ok)
                num_ljust = "----";
            else if (d[15:12] != 0)
                num_ljust = {"0" + d[15:12], "0" + d[11:8], "0" + d[7:4], "0" + d[3:0]};
            else if (d[11:8] != 0)
                num_ljust = {"0" + d[11:8], "0" + d[7:4], "0" + d[3:0], " "};
            else if (d[7:4] != 0)
                num_ljust = {"0" + d[7:4], "0" + d[3:0], "  "};
            else
                num_ljust = {"0" + d[3:0], "   "};
        end
    endfunction
    wire [15:0] src_w_bcd = bcd14(res_src_w);
    wire [15:0] src_h_bcd = bcd14(res_src_h);
    wire [15:0] out_w_bcd = bcd14({6'd0, res_out_w});
    wire [15:0] out_h_bcd = bcd14({7'd0, res_out_h});
    // 每个字段 4 个字符，[31:24] 是最左边那个；输出宽高最多 3 位，只用低 3 个字符 / 高 3 个字符
    reg [31:0] src_w_txt, src_h_txt, out_w_txt, out_h_txt;
    // 进度条：格数 = 值*10/256 四舍五入，帧起点算好
    reg bar_show_frame, bar_sel_frame;
    reg [3:0] bri_bars, con_bars;
    reg [7:0] bval_h, bval_t, bval_o;
    reg [7:0] cval_h, cval_t, cval_o;
    wire [11:0] bri_bar_mul = brightness * 4'd10 + 8'd128;
    wire [11:0] con_bar_mul = contrast * 4'd10 + 8'd128;
    wire bar_row_hit = line_y >= BAR_Y && line_y < BAR_Y + CELL_H;
    always @* begin
        case (brightness)
            8'd255: bright_percent_in = 8'd100;
            8'd192: bright_percent_in = 8'd75;
            8'd128: bright_percent_in = 8'd50;
            default: bright_percent_in = 8'd25;
        endcase
        if (period_ms >= 30000)
            period_seconds_in = 8'd30;
        else if (period_ms >= 10000)
            period_seconds_in = 8'd10;
        else if (period_ms >= 5000)
            period_seconds_in = 8'd5;
        else
            period_seconds_in = 8'd2;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            auto_frame <= 1'b0;
            src_w_txt <= "----"; src_h_txt <= "----";
            out_w_txt <= "----"; out_h_txt <= "----";
            bright_h <= "1"; bright_t <= "0"; bright_o <= "0";
            vol_h <= "2"; vol_t <= "5"; vol_o <= "5";
            period_t <= "0"; period_o <= "5";
            bar_show_frame <= 1'b0; bar_sel_frame <= 1'b0;
            bri_bars <= 4'd10; con_bars <= 4'd5;
            bval_h <= "2"; bval_t <= "5"; bval_o <= "5";
            cval_h <= "1"; cval_t <= "2"; cval_o <= "8";
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                auto_frame <= auto_enabled;
                src_w_txt <= num_rjust(src_w_bcd, res_valid);
                src_h_txt <= num_ljust(src_h_bcd, res_valid);
                out_w_txt <= num_rjust(out_w_bcd, res_valid);
                out_h_txt <= num_ljust(out_h_bcd, res_valid);
                bright_h <= "0" + bright_bcd[11:8];
                bright_t <= "0" + bright_bcd[7:4];
                bright_o <= "0" + bright_bcd[3:0];
                vol_h <= "0" + vol_bcd[11:8];
                vol_t <= "0" + vol_bcd[7:4];
                vol_o <= "0" + vol_bcd[3:0];
                period_t <= "0" + period_bcd[7:4];
                period_o <= "0" + period_bcd[3:0];
                bar_show_frame <= bar_show;
                bar_sel_frame  <= bar_sel;
                bri_bars <= bri_bar_mul[11:8];
                con_bars <= con_bar_mul[11:8];
                bval_h <= "0" + bval_bcd[11:8];
                bval_t <= "0" + bval_bcd[7:4];
                bval_o <= "0" + bval_bcd[3:0];
                cval_h <= "0" + cval_bcd[11:8];
                cval_t <= "0" + cval_bcd[7:4];
                cval_o <= "0" + cval_bcd[3:0];
            end
        end
    end

    // ===================== 弹幕槽管理（帧级） =====================
    reg [3:0]  slot_active;
    reg [10:0] slot_travel   [0:3];  // 已从右边缘进入的像素数
    reg [95:0] slot_text     [0:3];
    reg [5:0]  slot_length   [0:3];
    reg [10:0] slot_width    [0:3];  // slot_length * SUBTITLE_CELL_W，发射时算一次
    reg [10:0] slot_start_x  [0:3];  // 文字左边缘屏幕坐标，已移出左边时为 0
    reg [3:0]  slot_off_cell [0:3];  // 移出左边的部分折算成 字符号/列号，
    reg [4:0]  slot_off_col  [0:3];  // 作为每行 pixel_x=0 处的计数器初值

    // 待发队列：4 深 FIFO，入队时连同文字和长度一起存下，发射时从队头取。
    localparam integer QUEUE_DEPTH = 4;
    reg [95:0] queue_text   [0:QUEUE_DEPTH-1];
    reg [5:0]  queue_length [0:QUEUE_DEPTH-1];
    reg [1:0]  queue_wr_ptr;
    reg [1:0]  queue_rd_ptr;
    reg [2:0]  pending_count;

    integer lookup_i;
    integer free_slot;
    integer slot_i;
    reg lane_ready;
    reg [11:0] travel_next;
    reg [4:0]  off_step;
    reg [5:0]  col_sum;

    // 96 位最多保存 12 个字符。
    wire valid_push = subtitle_push &&
                      subtitle_length > 0 && subtitle_length <= 12;

    wire launch = frame_start && enable && subtitle_enable &&
                  pending_count != 0 && free_slot >= 0 && lane_ready;

    // 队满时丢弃新到的消息；同拍有发射腾出位置则照常入队。
    wire queue_write = valid_push &&
                       (pending_count != QUEUE_DEPTH || launch);

    wire [95:0] head_text   = queue_text[queue_rd_ptr];
    wire [5:0]  head_length = queue_length[queue_rd_ptr];

    // 查找空闲槽，同时检查右侧入口是否已经腾出足够间距。
    always @* begin
        free_slot = -1;
        lane_ready = 1'b1;

        for (lookup_i = 0; lookup_i < 4; lookup_i = lookup_i + 1) begin
            if (!slot_active[lookup_i] && free_slot < 0)
                free_slot = lookup_i;

            if (slot_active[lookup_i] &&
                slot_travel[lookup_i] < slot_width[lookup_i] + SUBTITLE_GAP)
                lane_ready = 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_active <= 4'b0;
            pending_count <= 3'd0;
            queue_wr_ptr <= 2'd0;
            queue_rd_ptr <= 2'd0;

            for (slot_i = 0; slot_i < 4; slot_i = slot_i + 1) begin
                queue_text[slot_i]    <= 96'd0;
                queue_length[slot_i]  <= 6'd0;
                slot_travel[slot_i]   <= 11'd0;
                slot_text[slot_i]     <= 96'd0;
                slot_length[slot_i]   <= 6'd0;
                slot_width[slot_i]    <= 11'd0;
                slot_start_x[slot_i]  <= H_ACTIVE;
                slot_off_cell[slot_i] <= 4'd0;
                slot_off_col[slot_i]  <= 5'd0;
            end
        end else if (!enable || !subtitle_enable) begin
            slot_active <= 4'b0;
            pending_count <= 3'd0;
            queue_wr_ptr <= 2'd0;
            queue_rd_ptr <= 2'd0;
        end else begin
            if (queue_write) begin
                queue_text[queue_wr_ptr]   <= subtitle_text;
                queue_length[queue_wr_ptr] <= subtitle_length;
                queue_wr_ptr <= queue_wr_ptr + 1'b1;
            end
            if (launch)
                queue_rd_ptr <= queue_rd_ptr + 1'b1;

            // 同拍入队一条、发射一条时，待发数量保持不变。
            case ({queue_write, launch})
                2'b10: pending_count <= pending_count + 1'b1;
                2'b01: pending_count <= pending_count - 1'b1;
                default: pending_count <= pending_count;
            endcase

            if (frame_start) begin
                // 更新已有弹幕的位置。
                for (slot_i = 0; slot_i < 4; slot_i = slot_i + 1) begin
                    if (slot_active[slot_i]) begin
                        travel_next = slot_travel[slot_i] + SUBTITLE_SPEED;
                        if (travel_next >= H_ACTIVE + slot_width[slot_i]) begin
                            slot_active[slot_i] <= 1'b0;
                        end else begin
                            slot_travel[slot_i] <= travel_next;
                            if (travel_next > H_ACTIVE) begin
                                // 左边缘已移出屏幕：起点钉在 0，偏移量累加本帧移出的像素。
                                slot_start_x[slot_i] <= 11'd0;
                                off_step = (slot_travel[slot_i] >= H_ACTIVE) ?
                                           SUBTITLE_SPEED : travel_next - H_ACTIVE;
                                col_sum = slot_off_col[slot_i] + off_step;
                                if (col_sum >= SUBTITLE_CELL_W) begin
                                    slot_off_col[slot_i]  <= col_sum - SUBTITLE_CELL_W;
                                    slot_off_cell[slot_i] <= slot_off_cell[slot_i] + 1'b1;
                                end else begin
                                    slot_off_col[slot_i]  <= col_sum;
                                end
                            end else begin
                                slot_start_x[slot_i] <= H_ACTIVE - travel_next;
                            end
                        end
                    end
                end

                // 从右侧发射一条新消息。
                if (launch) begin
                    slot_active[free_slot]   <= 1'b1;
                    slot_travel[free_slot]   <= 11'd0;
                    slot_text[free_slot]     <= head_text;
                    slot_length[free_slot]   <= head_length;
                    slot_width[free_slot]    <= {head_length, 4'b0} +
                                                {head_length, 1'b0};  // *18
                    slot_start_x[free_slot]  <= H_ACTIVE;
                    slot_off_cell[free_slot] <= 4'd0;
                    slot_off_col[free_slot]  <= 5'd0;
                end
            end
        end
    end

    localparam [255:0] CN_GLYPH_0 = 256'b0000000110000000000100011000110000011001100110000000110110010000000010011001000000000001100000000111111111111110000000111100000000000111111000000000010110110000000011011001100000111001100011100110000110000010000000011000000000000001100000000000000000000000;
    localparam [255:0] CN_GLYPH_1 = 256'b0000000000101000011111110010100000010100111111100001010000101000011111100010100001010110111111100101011000000000010101100000000001100110011111000100001001000100011111100111110001000010010001000100001001000100011111100111110001000010010000000000000000000000;
    localparam [255:0] CN_GLYPH_2 = 256'b0000000100000000000000010000000000000001000000000011111111111000001000010000100000100001000010000011111111111000001000010000100000100001000010000011111111111000001111111111100000100001000000000000000100000010000000011111111000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_3 = 256'b0000000000000000001111111111110000000000001110000000000001100000000000011000000000000001100000000111111111111110011111111111100000000001100000000000000110000000000000011000000000000001100000000000000110000000000001110000000000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_4 = 256'b0000000000000000001111111111110000000001100000000000000110000000000000011000000000000001100000000000000110000000000000011000000000000001100000000000000110000000000000011000000000000001100000000111111111111110000000000000000000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_5 = 256'b0000110011000000000010001000000000011001100000000001000111111110001100110100000000110110010000000101000001111100010100000100000000010000010000000001000001000000000100000111111000010000010000000001000001000000000100000100000000010000010000000000000000000000;
    localparam [255:0] CN_GLYPH_6 = 256'b0000000100000000000000011000000001111111111111000110000000000100011000000000010000011111111110000000011000110000000011000001100000011111111011000000000110000000000111111111100000000001100000000000000110000000011111111111111000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_7 = 256'b0001000001000000000100000100100000010000010011000001010001001000011101011111111001010010011100000101000001110000000100000111000000010000111100000001000010110000000100001011000000010001101100000001001100110010000101100001111000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_8 = 256'b0000110000000000000010000011111001111111101001000001100000100100000100000010010000111111001001000111000100101100010111110010010000010001001000100001000100100010000111110010001000010001001011100001000100100000000100110010000000000000001000000000000000000000;

    function [15:0] chinese_glyph_row;
        input [3:0] glyph_id;
        input [3:0] row;
        reg [255:0] glyph_bits;
        begin
            case (glyph_id)
                4'd0: glyph_bits = CN_GLYPH_0;
                4'd1: glyph_bits = CN_GLYPH_1;
                4'd2: glyph_bits = CN_GLYPH_2;
                4'd3: glyph_bits = CN_GLYPH_3;
                4'd4: glyph_bits = CN_GLYPH_4;
                4'd5: glyph_bits = CN_GLYPH_5;
                4'd6: glyph_bits = CN_GLYPH_6;
                4'd7: glyph_bits = CN_GLYPH_7;
                4'd8: glyph_bits = CN_GLYPH_8;
                default: glyph_bits = 256'b0;
            endcase
            chinese_glyph_row = glyph_bits[255-row*16 -: 16];
        end
    endfunction

    function [7:0] param_char;
        input [5:0] index;
        begin
            case (index)
                0: param_char = "B";  1: param_char = "R";
                2: param_char = "T";
                3: param_char = bright_h;
                4: param_char = bright_t;
                5: param_char = bright_o;
                6: param_char = " ";  7: param_char = "V";
                8: param_char = "O";  9: param_char = "L";
                10: param_char = vol_h;
                11: param_char = vol_t;
                12: param_char = vol_o;
                13: param_char = " ";  14: param_char = "P";
                15: param_char = period_t;
                16: param_char = period_o;
                17: param_char = "S"; 18: param_char = " ";
                19: param_char = "M"; 20: param_char = ":";
                21: param_char = auto_frame ? "A" : "M";
                // " IN:wwwwXhhhh OUT:wwwXhhh"：原图分辨率 → 缩放后图片区（不含黑边）
                23: param_char = "I";  24: param_char = "N";
                25: param_char = ":";
                26: param_char = src_w_txt[31:24];
                27: param_char = src_w_txt[23:16];
                28: param_char = src_w_txt[15:8];
                29: param_char = src_w_txt[7:0];
                30: param_char = "X";
                31: param_char = src_h_txt[31:24];
                32: param_char = src_h_txt[23:16];
                33: param_char = src_h_txt[15:8];
                34: param_char = src_h_txt[7:0];
                36: param_char = "O";  37: param_char = "U";
                38: param_char = "T";  39: param_char = ":";
                40: param_char = out_w_txt[23:16];
                41: param_char = out_w_txt[15:8];
                42: param_char = out_w_txt[7:0];
                43: param_char = "X";
                44: param_char = out_h_txt[31:24];
                45: param_char = out_h_txt[23:16];
                46: param_char = out_h_txt[15:8];
                default: param_char = " ";
            endcase
        end
    endfunction
    function [7:0] bar_char;
        input [5:0] index;
        begin
            if(index >= 4 && index <= 13)
                bar_char = (index - 4 < bri_bars)? "=" : "-";
            else if(index >= 23 && index <= 32)
                bar_char = (index - 23 < con_bars) ? "=" : "-";
            else 
                case(index)
                0:bar_char = bar_sel_frame ? " " : ">";
                1:bar_char = "B";
                2:bar_char = ":";
                3:bar_char = "[";
                14:bar_char = "]";
                15:bar_char = bval_h;
                16:bar_char = bval_t;
                17:bar_char = bval_o;
                19:bar_char = bar_sel_frame ? ">" : " ";
                20:bar_char = "C";
                21:bar_char = ":";
                22:bar_char = "[";
                33:bar_char = "]";
                34:bar_char = cval_h;
                35:bar_char = cval_t;
                36:bar_char = cval_o;
                default: bar_char = " ";
                endcase
        end
    endfunction
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
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    // ===================== 像素级计数器 =====================
    // 行消隐期（de=0）装入初值，de 期间在文字区内每像素 +1，
    // 依赖 pixel_x 在 de 期间从 0 起逐拍递增（video_timing_ctrl 保证）。

    // 参数条：字符号 / 字符内列号。
    reg [5:0] param_cell_cnt;
    reg [3:0] param_col_cnt;
    wire param_adv = de && pixel_x >= PARAM_X && param_cell_cnt < PARAM_CHARS;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            param_cell_cnt <= 6'd0;
            param_col_cnt  <= 4'd0;
        end else if (!de) begin
            param_cell_cnt <= 6'd0;
            param_col_cnt  <= 4'd0;
        end else if (param_adv) begin
            if (param_col_cnt == CELL_W-1) begin
                param_col_cnt  <= 4'd0;
                param_cell_cnt <= param_cell_cnt + 1'b1;
            end else begin
                param_col_cnt  <= param_col_cnt + 1'b1;
            end
        end
    end

    // 弹幕：每个槽一组 字符号 / 字符内列号。
    reg [3:0] sub_cell_cnt [0:3];
    reg [4:0] sub_col_cnt  [0:3];
    reg [3:0] slot_hit;
    integer hit_i;
    integer cnt_i;

    always @* begin
        for (hit_i = 0; hit_i < 4; hit_i = hit_i + 1)
            slot_hit[hit_i] = slot_active[hit_i] &&
                              {1'b0, pixel_x} >= slot_start_x[hit_i] &&
                              sub_cell_cnt[hit_i] < slot_length[hit_i];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (cnt_i = 0; cnt_i < 4; cnt_i = cnt_i + 1) begin
                sub_cell_cnt[cnt_i] <= 4'd0;
                sub_col_cnt[cnt_i]  <= 5'd0;
            end
        end else begin
            for (cnt_i = 0; cnt_i < 4; cnt_i = cnt_i + 1) begin
                if (!de) begin
                    sub_cell_cnt[cnt_i] <= slot_off_cell[cnt_i];
                    sub_col_cnt[cnt_i]  <= slot_off_col[cnt_i];
                end else if (slot_hit[cnt_i]) begin
                    if (sub_col_cnt[cnt_i] == SUBTITLE_CELL_W-1) begin
                        sub_col_cnt[cnt_i]  <= 5'd0;
                        sub_cell_cnt[cnt_i] <= sub_cell_cnt[cnt_i] + 1'b1;
                    end else begin
                        sub_col_cnt[cnt_i]  <= sub_col_cnt[cnt_i] + 1'b1;
                    end
                end
            end
        end
    end

    // ===================== 像素合成 =====================
    integer render_i;
    reg       sub_hit;
    reg [7:0] sub_char;
    reg [4:0] sub_col;
    reg [7:0] ascii_char;
    reg [2:0] ascii_row;
    reg [2:0] ascii_bit;
    reg       ascii_valid;
    reg       ascii_is_param;
    reg [4:0] selected_row;
    reg [15:0] selected_chinese_row;
    reg cn_pixel;
    reg ascii_pixel;
    reg param_pixel;
    reg subtitle_pixel;
    reg subtitle_band_pixel;

    wire param_row_hit = line_y >= PARAM_Y && line_y < PARAM_Y + CELL_H;
    wire sub_row_hit   = line_y >= SUBTITLE_Y && line_y < SUBTITLE_Y + SUBTITLE_CELL_H;
    wire sub_x_ok      = pixel_x >= 8 && pixel_x < H_ACTIVE-8;

    always @* begin
        // 同一轨道上发射间距保证槽之间不重叠，任一像素最多命中一个槽。
        sub_hit = 1'b0;
        sub_char = " ";
        sub_col = 5'd0;
        for (render_i = 0; render_i < 4; render_i = render_i + 1) begin
            if (!sub_hit && slot_hit[render_i]) begin
                sub_hit = 1'b1;
                sub_char = slot_text[render_i][sub_cell_cnt[render_i]*8 +: 8];
                sub_col = sub_col_cnt[render_i];
            end
        end

        ascii_char = " ";
        ascii_row = 3'd0;
        ascii_bit = 3'd0;
        ascii_valid = 1'b0;
        ascii_is_param = 1'b0;
        selected_chinese_row = 16'b0;
        cn_pixel = 1'b0;

        if (enable && de && param_row_hit && param_adv &&
            (param_col_cnt >> 1) < 5 && ((line_y-PARAM_Y) >> 1) < 7) begin
            ascii_char = param_char(param_cell_cnt);
            ascii_row = (line_y-PARAM_Y) >> 1;
            ascii_bit = param_col_cnt >> 1;
            ascii_valid = 1'b1;
            ascii_is_param = 1'b1;
            end 
            else if(enable && bar_show_frame && de && bar_row_hit && param_adv &&
             (param_col_cnt >> 1) < 5 && ((line_y-BAR_Y) >> 1) < 7) begin
                ascii_char  = bar_char(param_cell_cnt);
                ascii_row   = (line_y-BAR_Y) >> 1;
                ascii_bit   = param_col_cnt >> 1;
                ascii_valid = 1'b1;
                ascii_is_param = 1'b1;
            end
            else if (enable && subtitle_enable && de && sub_hit &&
                     sub_row_hit && sub_x_ok) begin
            if (sub_char[7]) begin
                // 中文字体 16x16。
                if (sub_col >= 1 && sub_col < 17 &&
                    line_y >= SUBTITLE_Y+2 && line_y < SUBTITLE_Y+18) begin
                    selected_chinese_row = chinese_glyph_row(
                        sub_char[3:0], line_y-SUBTITLE_Y-2);
                    cn_pixel = selected_chinese_row[16-sub_col];
                end
            end else if (sub_col >= 4 && sub_col < 14 &&
                         line_y >= SUBTITLE_Y+2 && line_y < SUBTITLE_Y+16) begin
                // ASCII 5x7 放大 2 倍。
                ascii_char = sub_char;
                ascii_row = (line_y-SUBTITLE_Y-2) >> 1;
                ascii_bit = (sub_col-4) >> 1;
                ascii_valid = 1'b1;
            end
        end

        // 参数条和弹幕不在同一行，共用一份 ASCII 字库。
        selected_row = glyph_row(ascii_char, ascii_row);
        ascii_pixel = ascii_valid && selected_row[4-ascii_bit];
        param_pixel = ascii_pixel && ascii_is_param;
        subtitle_pixel = (ascii_pixel && !ascii_is_param) || cn_pixel;

        subtitle_band_pixel = enable && subtitle_enable && de && sub_x_ok &&
                              line_y >= SUBTITLE_BAND_Y &&
                              line_y < SUBTITLE_BAND_BOTTOM;
    end

    assign overlay_active = param_pixel || subtitle_pixel || subtitle_band_pixel;
    assign rgb_out = overlay_active ?
                     (subtitle_pixel ? 24'h000000 :
                      subtitle_band_pixel ? 24'he8eef2 : 24'hfff080) : rgb_in;
endmodule
