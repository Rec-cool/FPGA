`timescale 1ns/1ps
// C0：(1) 新 reset_sync = 旧版晚 1 拍释放，断言（异步拉低）时刻完全相同；
//     (2) image_complete 同步锁存：输出只在 frame_start 变化，且等于 frame_start 前 2 拍以上已稳定的值。
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg vclk = 0; always #20 vclk = ~vclk;
    reg ext = 0;
    wire ro, rn;
    reset_sync_old uo(.clk(clk), .ext_rst_n(ext), .rst_n_sync(ro));
    reset_sync     un(.clk(clk), .ext_rst_n(ext), .rst_n_sync(rn));
    integer errs = 0, rel = 0;
    reg ro_d = 0;
    always @(posedge clk) begin
        ro_d <= ro;
        #1 if (rn !== ro_d && ext) begin errs++; $display("RST MISMATCH t=%0t", $time); end
        if (rn && !ro_d) ; 
    end
    always @(negedge ext) #1 if (rn !== 0 || ro !== 0) begin errs++; $display("RST not async asserted"); end
    // ---- image_complete CDC（与顶层相同写法）----
    reg [3:0] ic = 0;            // sd_card_clk 域
    reg frame_start = 0;
    reg [3:0] s1, s2, pix; reg vr = 0;   // vr 释放前 pix 为 X，检查器跳过
    always @(posedge vclk or negedge vr)
        if (!vr) begin s1 <= 0; s2 <= 0; pix <= 0; end
        else begin s1 <= ic; s2 <= s1; if (frame_start) pix <= s2; end
    reg [3:0] pix_d = 0; reg fs_d = 0;
    always @(posedge vclk) begin
        pix_d <= pix; fs_d <= frame_start;
        if (vr && pix_d !== 4'bx && pix !== pix_d && !fs_d) begin errs++; $display("PIX changed outside frame_start t=%0t pix=%b pix_d=%b vr=%b", $time, pix, pix_d, vr); end
    end
    integer frames = 0;
    always @(posedge vclk) if (vr) begin
        frames++; frame_start <= (frames % 50 == 0);
    end
    initial begin
        // 复位：多次断言/释放，释放沿相对时钟随机
        for (int k = 0; k < 40; k++) begin
            #($urandom_range(1, 97)); ext = 1; #($urandom_range(30, 400)); ext = 0; #($urandom_range(3, 200));
            rel++;
        end
        ext = 1; vr = 1;
        // image_complete 逐位随机置位/清零
        for (int k = 0; k < 200; k++) begin
            #($urandom_range(5, 3000)); @(posedge clk); ic[$urandom_range(0,3)] <= $urandom & 1;
        end
        #5000;
        $display("DONE resets=%0d final ic=%b pix=%b errs=%0d", rel, ic, pix, errs);
        $finish;
    end
endmodule
