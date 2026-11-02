`timescale 1ns/1ps
// P1 进度条验证：
//   第 1 部分：快速翻 vsync，大量 (样本数, 扇区数) 组合，fill 与黄金模型 min(floor(n*BW/(sec*256)), BW) 比较（sec=0 → 0）
//   第 2 部分：真实 800×525 时序下画几帧，逐像素与期望图案比较（进度条、游标、区外透传、enable=0 全透传）
//   第 3 部分：扇区数在另一时钟域变化，只在稳定后采用
module tb;
    parameter integer BW = 448, MUL = 7, DSH = 2;   // 旧版 512：-gBW=512 -gMUL=2 -gDSH=0
    reg clk = 0; always #20 clk = ~clk;          // video_clk 25MHz
    reg sclk = 0; always #5 sclk = ~sclk;        // sd_card_clk 100MHz
    reg rst_n = 0;
    reg vsync = 0, de = 0, en = 0;
    reg [11:0] px = 0, py = 0;
    reg [23:0] rgb_in = 0;
    reg [31:0] cnt = 0;
    reg [23:0] sec = 0;                           // sclk 域
    wire [23:0] rgb_out;
    progress_bar_overlay #(.BAR_X(64), .BAR_Y(468), .BAR_W(BW), .BAR_H(4), .BAR_MUL(MUL), .DIV_SHIFT(DSH), .W_SHIFT(9)) u (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .pixel_x(px), .pixel_y(py), .rgb_in(rgb_in),
        .enable(en), .sample_count(cnt), .total_sectors(sec), .rgb_out(rgb_out));

    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 30) $display("ERR %s", m); endtask
    function automatic int gold(longint unsigned n, longint unsigned s);
        longint unsigned q;
        if (s == 0) return 0;
        q = (n * BW) / (s * 256);
        return (q > BW) ? BW : int'(q);
    endfunction
    task automatic set_sec(int s);                // 在 sclk 域改，等同步完成
        @(posedge sclk) sec <= s;
        repeat (8) @(posedge clk);
    endtask
    task automatic pulse_frame();                 // vsync 一个短脉冲，等除法做完
        @(posedge clk) vsync <= 1;
        @(posedge clk) vsync <= 0;
        repeat (16) @(posedge clk);
    endtask
    task automatic chk(longint unsigned n, int s);
        int e;
        @(posedge clk) cnt <= n[31:0];
        pulse_frame();
        e = gold(n[31:0], s);
        if (u.fill !== e) fail($sformatf("n=%0d sec=%0d fill=%0d exp %0d", n, s, u.fill, e));
    endtask

    // 期望像素
    function automatic [23:0] exp_pix(int x, int y, bit d, bit e, int f, reg [23:0] bg);
        int dx, k0; bit inx, inbar, inkb;
        dx = x - 64; inx = (x >= 64 && x < 64 + BW);
        inbar = e && d && inx && y >= 468 && y < 472;
        inkb  = e && d && inx && y >= 466 && y < 474;
        k0 = (f >= 2) ? f - 2 : 0;
        if (inkb && dx >= k0 && dx < k0 + 2) return 24'hffffff;
        if (inbar && dx < f) return 24'hffd040;
        if (inbar) return 24'h404040;
        return bg;
    endfunction
    task automatic frame(longint unsigned n, int s, bit e);   // 800×525，vsync 在第 490~491 行
        en <= e;
        $display("  frame n=%0d en=%0d fill=%0d", n, e, u.fill);
        for (int y = 0; y < 525; y++) for (int x = 0; x < 800; x++) begin
            @(posedge clk);
            if (y == 0 && x == 0) cnt <= n[31:0];
            px <= x; py <= y; de <= (x < 640 && y < 480); vsync <= (y >= 490 && y < 492);
            rgb_in <= {x[7:0], y[7:0], 8'h5a};
        end
    endtask
    // 逐像素检查：在每个时钟下降沿看组合输出
    bit pix_chk = 0; int pix_n = 0; int f_cur;
    always @(negedge clk) if (pix_chk) begin
        automatic reg [23:0] e = exp_pix(px, py, de, en, u.fill, rgb_in);
        if (rgb_out !== e) fail($sformatf("pix (%0d,%0d) de=%0d en=%0d fill=%0d out=%h exp %h", px, py, de, en, u.fill, rgb_out, e));
        pix_n++;
    end

    initial begin
        repeat (5) @(posedge clk); rst_n <= 1; repeat (5) @(posedge clk);
        // ---------- 第 1 部分 ----------
        begin
            automatic int ss [] = '{1, 2, 3, 255, 256, 1000, 4096, 12345, 65535, 100000, 1048575, 16777215};
            foreach (ss[i]) begin
                automatic longint unsigned tot = longint'(ss[i]) * 256;
                set_sec(ss[i]);
                chk(0, ss[i]); chk(1, ss[i]); chk(tot/2, ss[i]); chk(tot - 1, ss[i]); chk(tot, ss[i]); chk(tot + 1, ss[i]);
                chk((tot > 32'hffffffff) ? 32'hffffffff : tot, ss[i]); chk(32'hffffffff, ss[i]);
                for (int k = 0; k <= BW; k += 37) chk((tot * k) / BW, ss[i]);
            end
            set_sec(0); chk(0, 0); chk(12345, 0); chk(32'hffffffff, 0);
            for (int i = 0; i < 3000; i++) begin
                automatic int s; automatic longint unsigned n;
                s = 1 + {$random} % 16777215; if (i % 3 == 0) s = 1 + {$random} % 20000;
                set_sec(s);
                n = (i % 4 == 0) ? {$random} : ({$random} % (longint'(s) * 256 + 1000));
                chk(n[31:0], s);
            end
            $display("part1 done errs=%0d", errs);
        end
        // ---------- 第 3 部分：扇区数在 sclk 域连续变化，只在稳定后采用 ----------
        begin
            automatic bit seen [int]; seen[5000] = 1; seen[int'(u.sec_v)] = 1;   // 进来前已采用的值
            fork
                begin for (int i = 0; i < 200; i++) begin automatic int v = {$random} & 24'hffffff; seen[v] = 1; @(posedge sclk) sec <= v; end end
                begin
                    for (int i = 0; i < 800; i++) begin
                        @(posedge clk);
                        // sec_v 必须是 sclk 域真实写过的某个值，不能是新旧混合
                        if (!seen.exists(int'(u.sec_v))) fail($sformatf("sec_v=%h never written", u.sec_v));
                    end
                end
            join
            set_sec(5000);
            if (u.sec_v !== 24'd5000) fail($sformatf("sec_v=%0d after settle", u.sec_v));
            chk(640000, 5000);
            $display("part3 done errs=%0d", errs);
        end
        // ---------- 第 2 部分：逐像素 ----------
        set_sec(10000);                             // 总 2560000 样本
        @(posedge clk) pix_chk <= 1;
        frame(0, 10000, 1);                         // 本帧 fill 仍为上一次的值（640000/5000→...），检查用当前 u.fill
        frame(1280000, 10000, 1);                   // 下一帧 fill = 256
        frame(2560000, 10000, 1);                   // 满格
        frame(5000, 10000, 1);                      // 1
        frame(30000, 10000, 1);                     // 6
        frame(1280000, 10000, 0);                   // 不显示，全透传
        frame(1280000, 10000, 1);
        pix_chk <= 0;
        $display("DONE tb_prog errs=%0d pixels_checked=%0d", errs, pix_n);
        $finish;
    end
endmodule
