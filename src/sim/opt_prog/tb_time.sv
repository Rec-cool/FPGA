`timescale 1ns/1ps
// P2 播放时间验证：
//   第 1 部分：大量样本数，数字寄存器 {mm_t, mm_o, ss_t, ss_o} 与黄金模型比较（≥ 100 分钟显示 99:59）
//   第 2 部分：按真实 800×525 时序画几帧，逐像素与期望字形比较（区外透传、enable=0 全透传）
module tb;
    reg clk = 0; always #20 clk = ~clk;
    reg rst_n = 0;
    reg vsync = 0, de = 0, en = 0;
    reg [11:0] px = 0, py = 0;
    reg [23:0] rgb_in = 0;
    reg [31:0] cnt = 0;
    wire [23:0] rgb_out;
    song_time_osd #(.TXT_X(520), .TXT_Y(464), .CHAR_W(8), .SAMPLE_RATE(48000)) u (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .pixel_x(px), .pixel_y(py), .rgb_in(rgb_in),
        .enable(en), .sample_count(cnt), .rgb_out(rgb_out));

    integer errs = 0, nchk = 0;
    task automatic fail(string m); errs++; if (errs < 30) $display("ERR %s", m); endtask
    function automatic [15:0] gold(longint unsigned n);
        longint unsigned s; int mm, ss;
        s = n / 48000; mm = s / 60; ss = s % 60;
        if (mm > 99) begin mm = 99; ss = 59; end
        return {4'(mm / 10), 4'(mm % 10), 4'(ss / 10), 4'(ss % 10)};
    endfunction
    task automatic chk(longint unsigned n);
        reg [15:0] e;
        @(posedge clk) cnt <= n[31:0];
        @(posedge clk) vsync <= 1;
        @(posedge clk) vsync <= 0;
        repeat (40) @(posedge clk);
        e = gold(n[31:0]); nchk++;
        if ({u.mm_t, u.mm_o, u.ss_t, u.ss_o} !== e)
            fail($sformatf("n=%0d digits=%h exp %h", n, {u.mm_t, u.mm_o, u.ss_t, u.ss_o}, e));
    endtask

    // 期望像素：照搬字形定义（独立写一份 4×6 位图，不调用 DUT 的函数）
    function automatic bit glyph(int d, int c, int r);
        bit [3:0] g [10][6] = '{
            '{4'b0110, 4'b1001, 4'b1001, 4'b1001, 4'b1001, 4'b0110},   // 0
            '{4'b0110, 4'b0010, 4'b0111, 4'b0010, 4'b0010, 4'b0111},   // 1
            '{4'b0110, 4'b0001, 4'b0110, 4'b0100, 4'b1000, 4'b0111},   // 2
            '{4'b0110, 4'b0001, 4'b0110, 4'b0001, 4'b0001, 4'b0110},   // 3
            '{4'b1001, 4'b1001, 4'b1111, 4'b0001, 4'b0001, 4'b0001},   // 4
            '{4'b1111, 4'b1000, 4'b1110, 4'b0001, 4'b0001, 4'b0110},   // 5
            '{4'b0110, 4'b1000, 4'b1110, 4'b1001, 4'b1001, 4'b0110},   // 6
            '{4'b1111, 4'b0001, 4'b0010, 4'b0010, 4'b0010, 4'b0010},   // 7
            '{4'b0110, 4'b1001, 4'b0110, 4'b1001, 4'b1001, 4'b0110},   // 8
            '{4'b0110, 4'b1001, 4'b0111, 4'b0001, 4'b0001, 4'b0110}};  // 9
        return g[d][r][3 - c];          // 位 3 = 第 0 列（最左）
    endfunction
    reg [15:0] shown;                   // 当前帧应显示的数字
    function automatic [23:0] exp_pix(int x, int y, bit d, bit e, reg [15:0] dg, reg [23:0] bg);
        int dx, dy, ci, c, r; bit on;
        if (!(e && d && x >= 520 && x < 560 && y >= 464 && y < 476)) return bg;
        dx = x - 520; dy = y - 464; ci = dx / 8; c = dx % 8; r = dy / 2;
        on = 0;
        if (c < 4) case (ci)
            0: on = glyph(dg[15:12], c, r);
            1: on = glyph(dg[11:8], c, r);
            2: on = (c == 1 || c == 2) && (r == 1 || r == 4);
            3: on = glyph(dg[7:4], c, r);
            4: on = glyph(dg[3:0], c, r);
        endcase
        return on ? 24'hffffff : bg;
    endfunction
    bit pix_chk = 0; int pix_n = 0;
    always @(negedge clk) if (pix_chk) begin
        automatic reg [23:0] e = exp_pix(px, py, de, en, {u.mm_t, u.mm_o, u.ss_t, u.ss_o}, rgb_in);
        if (rgb_out !== e) fail($sformatf("pix (%0d,%0d) en=%0d out=%h exp %h", px, py, en, rgb_out, e));
        pix_n++;
    end
    task automatic frame(longint unsigned n, bit e);
        en <= e;
        for (int y = 0; y < 525; y++) for (int x = 0; x < 800; x++) begin
            @(posedge clk);
            if (y == 0 && x == 0) cnt <= n[31:0];
            px <= x; py <= y; de <= (x < 640 && y < 480); vsync <= (y >= 490 && y < 492);
            rgb_in <= {x[7:0], y[7:0], 8'h33};
        end
        $display("  frame n=%0d en=%0d shows %h", n, e, {u.mm_t, u.mm_o, u.ss_t, u.ss_o});
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n <= 1; repeat (5) @(posedge clk);
        // ---------- 第 1 部分 ----------
        chk(0); chk(1); chk(47999); chk(48000); chk(48001);
        for (int s = 0; s <= 6000; s++) begin          // 0 ~ 100 分钟逐秒：每秒的首、尾样本
            chk(longint'(s) * 48000);
            chk(longint'(s) * 48000 + 47999);
        end
        chk(99*60*48000 + 59*48000 + 47999);           // 99:59 最后一个样本
        chk(100*60*48000);                             // 100:00 → 钳到 99:59
        chk(32'hffffffff);
        for (int i = 0; i < 5000; i++) chk({$random});
        $display("part1 done checks=%0d errs=%0d", nchk, errs);
        // ---------- 第 2 部分 ----------
        @(posedge clk) pix_chk <= 1;
        frame(0, 1);
        frame(48000*83, 1);               // 下一帧显示 01:23
        frame(48000*(45*60+6), 1);        // 45:06
        frame(48000*(98*60+57), 1);       // 98:57
        frame(48000*(12*60+34), 1);       // 12:34
        frame(48000*(57*60+8), 1);        // 57:08（其余数字）
        frame(48000*(69*60+0), 0);        // 不显示，全透传
        frame(48000*(69*60+0), 1);        // 69:00
        pix_chk <= 0;
        $display("DONE tb_time errs=%0d checks=%0d pixels_checked=%0d", errs, nchk, pix_n);
        $finish;
    end
endmodule
