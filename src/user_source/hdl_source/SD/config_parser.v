`timescale 1ns/1ps

// 10-29 CF：TF 卡根目录 CONFIG.TXT 解析（sd_card_clk 域）。扫描器把文件第一个扇区（最多 512 字节）逐字节送进来。
// 格式：每行一个"键=值"，键名不区分大小写、只看前 3 个字母，空格忽略，# 或 ; 开头的行是注释，CR/LF 都算换行；
//   值后面的 # 或 ; 到行尾是行尾注释；>= 0x80 的字节（UTF-8 BOM、中文）在行首不算内容，不影响注释判断：
//   INTERVAL=5     轮播间隔，1~30 秒
//   AUTO=ON        自动轮播，ON/OFF 或 1/0
//   BRIGHT=3       亮度档 0~3（3 = 100%）
//   CONTRAST=2     对比度档 0~5（2 = 1.0 倍）
//   MODE=SEQ       播放模式 SEQ/ONE/RND 或 0/1/2
//   VOLUME=9       音量 0~10（10 = 最大）
// 超出范围、写错、没写的项不生效（用原来的默认值）。文件读完发一拍 apply，mask 标出哪些项有效。
module config_parser #(
    parameter [31:0] SEC_CYCLES = 32'd100_000_000    // 1 秒对应的拍数（轮播间隔换算用）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        begin_pulse,      // 开始读文件：清空本次结果
    input  wire        byte_valid,
    input  wire [7:0]  byte_in,
    input  wire        end_pulse,        // 文件读完（无错误）：提交最后一行，算完后发 apply
    output reg         apply,            // 单拍：下面的值已就绪
    output reg  [5:0]  mask,             // {VOL, MODE, CON, BRI, AUTO, INT} 哪些项有效
    output reg  [4:0]  interval_sec,
    output reg  [31:0] interval_cycles,
    output reg         auto_on,
    output reg  [1:0]  bri,
    output reg  [2:0]  con,
    output reg  [1:0]  mode,
    output reg  [3:0]  vol
);
    localparam [1:0] P_KEY = 2'd0, P_VAL = 2'd1, P_SKIP = 2'd2, P_VEND = 2'd3;   // P_VEND：值已结束（行尾注释），等换行再提交
    reg [1:0]  ps;
    reg [23:0] key;                      // 前 3 个字母（大写），左移拼入；不足 3 个时前面是空格，"AU" 不会被当成 "AUT"
    reg [1:0]  key_n;
    reg [7:0]  num;                      // 十进制值，超过 255 钳位
    reg        has_num;
    reg [7:0]  vc0, vc1;                 // 值的前 2 个字母（大写）
    reg [1:0]  vc_n;
    reg        line_any;                 // 本行出现过非空字符
    reg        fin;                      // end_pulse 后：提交最后一行，再算间隔
    reg [4:0]  mul_cnt;

    wire [7:0] up      = (byte_in >= "a" && byte_in <= "z") ? (byte_in - 8'd32) : byte_in;
    wire       is_let  = (up >= "A" && up <= "Z");
    wire       is_dig  = (byte_in >= "0" && byte_in <= "9");
    wire       is_eol  = (byte_in == 8'h0a) || (byte_in == 8'h0d);
    wire [11:0] num10  = {4'd0, num} * 12'd10 + {8'd0, byte_in[3:0]};

    // 提交一行（组合判定，commit 时写入）
    wire k_int = (key == "INT"), k_aut = (key == "AUT"), k_bri = (key == "BRI"),
         k_con = (key == "CON"), k_mod = (key == "MOD"), k_vol = (key == "VOL");
    wire [1:0] mode_l = (vc0 == "S") ? 2'd0 : (vc0 == "O") ? 2'd1 : (vc0 == "R") ? 2'd2 : 2'd3;
    wire       auto_l_ok = (vc0 == "O" && (vc1 == "N" || vc1 == "F")) || vc0 == "Y" || vc0 == "N";
    wire       auto_l    = (vc0 == "O" && vc1 == "N") || vc0 == "Y";

    task commit;
        begin
            if (ps == P_VAL || ps == P_VEND) begin
                if (k_int && has_num && num >= 8'd1 && num <= 8'd30) begin
                    interval_sec <= num[4:0]; mask[0] <= 1'b1;
                end
                if (k_aut && has_num && num <= 8'd1) begin
                    auto_on <= num[0]; mask[1] <= 1'b1;
                end else if (k_aut && !has_num && auto_l_ok) begin
                    auto_on <= auto_l; mask[1] <= 1'b1;
                end
                if (k_bri && has_num && num <= 8'd3) begin
                    bri <= num[1:0]; mask[2] <= 1'b1;
                end
                if (k_con && has_num && num <= 8'd5) begin
                    con <= num[2:0]; mask[3] <= 1'b1;
                end
                if (k_mod && has_num && num <= 8'd2) begin
                    mode <= num[1:0]; mask[4] <= 1'b1;
                end else if (k_mod && !has_num && mode_l != 2'd3) begin
                    mode <= mode_l; mask[4] <= 1'b1;
                end
                if (k_vol && has_num && num <= 8'd10) begin
                    vol <= num[3:0]; mask[5] <= 1'b1;
                end
            end
            ps <= P_KEY; key <= 24'h202020; key_n <= 2'd0; num <= 8'd0; has_num <= 1'b0;
            vc0 <= 8'h20; vc1 <= 8'h20; vc_n <= 2'd0; line_any <= 1'b0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            apply <= 1'b0; mask <= 6'd0;
            interval_sec <= 5'd0; interval_cycles <= 32'd0; auto_on <= 1'b0;
            bri <= 2'd0; con <= 3'd0; mode <= 2'd0; vol <= 4'd0;
            ps <= P_KEY; key <= 24'h202020; key_n <= 2'd0; num <= 8'd0; has_num <= 1'b0;
            vc0 <= 8'h20; vc1 <= 8'h20; vc_n <= 2'd0; line_any <= 1'b0;
            fin <= 1'b0; mul_cnt <= 5'd0;
        end else begin
            apply <= 1'b0;
            if (begin_pulse) begin
                mask <= 6'd0; fin <= 1'b0;
                ps <= P_KEY; key <= 24'h202020; key_n <= 2'd0; num <= 8'd0; has_num <= 1'b0;
                vc0 <= 8'h20; vc1 <= 8'h20; vc_n <= 2'd0; line_any <= 1'b0;
            end else if (end_pulse) begin
                commit;                                     // 文件最后一行可能没有换行
                fin <= 1'b1; mul_cnt <= 5'd0; interval_cycles <= 32'd0;
            end else if (fin) begin
                // 间隔换算：interval_sec 次累加 SEC_CYCLES（每张图只做一次，不占乘法器）
                if (mul_cnt != interval_sec) begin
                    interval_cycles <= interval_cycles + SEC_CYCLES;
                    mul_cnt <= mul_cnt + 5'd1;
                end else begin
                    fin   <= 1'b0;
                    apply <= 1'b1;
                end
            end else if (byte_valid) begin
                if (is_eol)
                    commit;
                else case (ps)
                    P_KEY: begin
                        if (!line_any && (byte_in == "#" || byte_in == ";"))
                            ps <= P_SKIP;
                        else if (byte_in == "=")
                            ps <= P_VAL;
                        else if (is_let && key_n != 2'd3) begin
                            key   <= {key[15:0], up};
                            key_n <= key_n + 2'd1;
                        end
                        if (byte_in != " " && byte_in != 8'h09 && !byte_in[7]) line_any <= 1'b1;
                    end
                    P_VAL: begin
                        if (byte_in == "#" || byte_in == ";")
                            ps <= P_VEND;
                        else if (is_dig) begin
                            num     <= (num10 > 12'd255) ? 8'd255 : num10[7:0];
                            has_num <= 1'b1;
                        end else if (is_let && vc_n != 2'd2) begin
                            if (vc_n == 2'd0) vc0 <= up; else vc1 <= up;
                            vc_n <= vc_n + 2'd1;
                        end
                    end
                    default: ;                              // 注释行 / 行尾注释：等换行
                endcase
            end
        end
    end

endmodule
