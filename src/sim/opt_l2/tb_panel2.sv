`timescale 1ns/1ps
// L2 歌单面板验证（L1 测试台 + 选歌光标）：sd 域用和顶层相同的轮询写法产生 pl_bus（歌单表模型读出延迟 1 拍），
// video 域按真实 800×525 时序画帧，逐像素和黄金模型比较。
//   场景：歌曲数 0 / 1 / 5 / 16；当前曲目、播放模式逐帧变化；名字含 A~Z、0~9、~、_、-、空格、不支持的字符；
//         时长含 0 秒、59→60 秒、超过 99:59；enable=0 时全部透传。
//   黄金模型：帧 k 显示的是帧 k-1 开始时设置的歌曲数/当前曲目/模式（中间隔了足够多的轮询周期）。
module tb;
    reg sclk = 0; always #5  sclk = ~sclk;      // sd_card_clk 100MHz
    reg clk  = 0; always #20 clk  = ~clk;       // video_clk 25MHz
    reg rst_n = 0;

    // ---------------- sd 域：歌单表模型 + 与顶层相同的轮询 ----------------
    reg [63:0] t_name [0:15];
    reg [23:0] t_sec  [0:15];
    reg [4:0]  s_cnt = 0; reg [3:0] s_cur = 0; reg [1:0] s_mode = 0; reg [3:0] s_csr = 0;
    reg [11:0]  pl_seq;
    reg [106:0] pl_bus;
    reg [87:0]  pl_rd_data;
    wire [3:0]  pl_rd_idx = pl_seq[11:8];
    always @(posedge sclk) pl_rd_data <= {t_name[pl_rd_idx], t_sec[pl_rd_idx]};
    always @(posedge sclk or negedge rst_n) begin
        if (!rst_n) begin
            pl_seq <= 12'd0;
            pl_bus <= 107'd0;
        end else begin
            pl_seq <= pl_seq + 12'd1;
            if (pl_seq[7:0] == 8'hff)
                pl_bus <= {s_csr, s_cnt, s_cur, s_mode, pl_seq[11:8], pl_rd_data};
        end
    end

    // ---------------- DUT ----------------
    reg vsync = 0, de = 0, en = 1;
    reg [11:0] px = 0, py = 0;
    reg [23:0] rgb_in = 0;
    wire [23:0] rgb_out;
    playlist_panel #(.BOX_X(416), .BOX_Y(80), .NCH(18), .CW(12), .PAD(4)) u (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .pixel_x(px), .pixel_y(py), .rgb_in(rgb_in),
        .enable(en), .pl_bus(pl_bus), .rgb_out(rgb_out));

    // ---------------- 黄金模型 ----------------
`include "glyph.v"
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 30) $display("ERR %s", m); endtask
    // 本帧应显示的状态
    int g_cnt, g_cur, g_mode, g_csr;
    function automatic [7:0] d2c(int d); return 8'(48 + d); endfunction
    function automatic [7:0] exp_char(int row, int col);
        int e, num, s, mm, ss; reg [7:0] c; string ms;
        c = " ";
        if (row == 0) begin
            string t; ms = (g_mode == 0) ? "SEQ" : (g_mode == 1) ? "ONE" : "RND";
            t = $sformatf("PLAYLIST %02d/%02d %s", (g_cnt == 0) ? 0 : g_cur + 1, g_cnt, ms);
            return t[col];
        end
        e = row - 1; num = e + 1;
        s = (longint'(t_sec[e]) * 256) / 48000; mm = s / 60; ss = s % 60;
        if (mm > 99) begin mm = 99; ss = 59; end
        case (col)
            0: c = (e == g_cur) ? ">" : " ";
            1: c = d2c(num / 10);  2: c = d2c(num % 10);
            4,5,6,7,8,9,10,11: c = t_name[e][63 - 8*(col-4) -: 8];
            13: c = d2c(mm / 10);  14: c = d2c(mm % 10);  15: c = ":";
            16: c = d2c(ss / 10);  17: c = d2c(ss % 10);
            default: c = " ";
        endcase
        return c;
    endfunction
    function automatic [23:0] exp_pix(int x, int y, bit d, bit e_, reg [23:0] bg);
        int rows, row, col, cx, cy; reg [7:0] c; reg [4:0] gr; bit on; reg [23:0] dk, fg;
        rows = g_cnt + 1;
        if (!(d && e_ && x >= 416 && x < 640 && y >= 80 && y < 80 + rows*16 + 8)) return bg;
        dk = {1'b0, bg[23:17], 1'b0, bg[15:9], 1'b0, bg[7:1]};
        if (y >= 84 && (y - 84) / 16 >= 1 && (y - 84) / 16 < rows && (y - 84) / 16 - 1 == g_csr) dk = 24'h1c4c8c;   // 光标行整行蓝底
        if (!(x >= 420 && x < 636 && y >= 84 && (y - 84) / 16 < rows)) return dk;
        row = (y - 84) / 16; col = (x - 420) / 12; cx = (x - 420) % 12; cy = (y - 84) % 16;
        c = exp_char(row, col);
        gr = glyph_row(c, cy / 2);
        on = (cx / 2 < 5) && (cy / 2 < 7) && gr[4 - cx / 2];
        fg = (row == 0) ? 24'h80e0ff : (row - 1 == g_cur) ? 24'hffd040 : 24'hffffff;
        return on ? fg : dk;
    endfunction

    bit pix_chk = 0; int pix_n = 0, txt_n = 0;
    always @(negedge clk) if (pix_chk) begin
        automatic reg [23:0] e = exp_pix(px, py, de, en, rgb_in);
        if (rgb_out !== e) fail($sformatf("pix (%0d,%0d) cnt=%0d cur=%0d mode=%0d out=%h exp %h",
                                          px, py, g_cnt, g_cur, g_mode, rgb_out, e));
        pix_n++;
        if (e == 24'hffffff || e == 24'hffd040 || e == 24'h80e0ff) txt_n++;
    end

    // 画一帧；帧开头（第 0 行）在 sd 域设置下一帧要显示的状态
    int n_cnt, n_cur, n_mode, n_csr;
    task automatic frame(bit e_, bit chk);
        en <= e_;
        for (int y = 0; y < 525; y++) for (int x = 0; x < 800; x++) begin
            @(posedge clk);
            if (y == 0 && x == 0) begin
                pix_chk <= chk;
                fork begin @(posedge sclk); s_cnt <= n_cnt; s_cur <= n_cur; s_mode <= n_mode; s_csr <= n_csr; end join_none
            end
            px <= x; py <= y; de <= (x < 640 && y < 480); vsync <= (y >= 490 && y < 492);
            rgb_in <= {x[7:0] ^ 8'h5a, y[7:0], x[9:2]};
        end
    endtask
    // 两帧为一组：第一帧设置状态（不检查，期间状态可能在帧内变化），第二帧检查
    task automatic show(int cnt, int cur, int mode, bit e_, int csr = 0);
        n_cnt = cnt; n_cur = cur; n_mode = mode; n_csr = csr;
        frame(e_, 0);
        g_cnt = cnt; g_cur = cur; g_mode = mode; g_csr = csr;
        frame(e_, 1);
        $display("  shown cnt=%0d cur=%0d csr=%0d mode=%0d en=%0d  pixels=%0d text_pixels=%0d errs=%0d", cnt, cur, csr, mode, e_, pix_n, txt_n, errs);
    endtask

    initial begin
        string nm [16] = '{"SUNNYDAY", "RAINBOW_", "MOONLITE", "LONGFI~1", "A-B C D ", "0123456X",
                            "QWERTYUI", "OPASDFGH", "JKLZXCVB", "NM789$%&", "S01     ", "S02     ",
                            "Z       ", "ABCDEFGH", "IJKLMNOP", "QRSTUVWX"};
        int sec [16] = '{0, 187, 188, 22312, 22500, 1124812, 1125000, 16777215,
                         93, 5000, 70000, 45000, 2, 375, 11250, 999999};
        for (int i = 0; i < 16; i++) begin
            for (int k = 0; k < 8; k++) t_name[i][63 - 8*k -: 8] = nm[i][k];
            t_sec[i] = sec[i];
        end
        n_cnt = 0; n_cur = 0; n_mode = 0; n_csr = 0;
        repeat (5) @(posedge clk); rst_n <= 1;
        frame(1, 0);                                   // 预热：本地表填满
        show(0, 0, 0, 1, 0);                           // 没歌：光标不画
        show(1, 0, 1, 1, 0);                           // 光标和正在放的同一行
        show(5, 3, 2, 1, 1);
        show(5, 3, 2, 1, 4);                           // 光标在最后一行
        show(16, 15, 0, 1, 0);                         // 光标在第一行
        show(16, 0, 1, 1, 15);
        show(16, 9, 2, 1, 9);
        show(16, 9, 2, 0, 3);                          // enable=0（SW4=0）：全部透传
        show(12, 11, 0, 1, 13);                        // 光标越界（>= 歌曲数）：不画
        show(12, 11, 0, 1, 6);
        $display("DONE tb_panel2 errs=%0d pixels_checked=%0d text_pixels=%0d", errs, pix_n, txt_n);
        $finish;
    end
endmodule
