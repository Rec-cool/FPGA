`timescale 1ns/1ps
// A1 等价比对：旧 loader(寄存器FIFO) 与新 loader(BRAM FIFO) 同激励逐拍比对写口输出。
// 小图 64x8 加快仿真；像素间隔随机（含背靠背突发），共加载 3 张，覆盖 FIFO 积压与 commit 冲刷。
module tb;
    localparam W = 64, H = 8, WORDS = W*H;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg load_start = 0; reg [1:0] idx = 0;
    reg pv = 0; reg [23:0] rgb = 0; reg commit = 0;
    wire [3:0] c_o, c_n; wire d_o, d_n, b_o, b_n;
    wire [7:0] e_o, e_n;
    wire we_o, we_n; wire [20:0] a_o, a_n; wire [3:0] m_o, m_n; wire [31:0] q_o, q_n;
    media_frame_loader_old #(.IMAGE_WORDS(WORDS),.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) uo(
        clk,rst_n,load_start,idx,pv,rgb,commit,8'd0,b_o,d_o,c_o,e_o,1'b1,1'b0,1'b0,we_o,a_o,m_o,q_o);
    media_frame_loader     #(.IMAGE_WORDS(WORDS),.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) un(
        clk,rst_n,load_start,idx,pv,rgb,commit,8'd0,b_n,d_n,c_n,e_n,1'b1,1'b0,1'b0,we_n,a_n,m_n,q_n);
    integer errs = 0, writes = 0, i, img, gap;
    always @(posedge clk) if (rst_n) begin
        if (we_o !== we_n || b_o !== b_n || d_o !== d_n || c_o !== c_n || e_o !== e_n ||
            (we_o && (a_o !== a_n || m_o !== m_n || q_o !== q_n))) begin
            errs = errs + 1;
            if (errs < 10) $display("MISMATCH t=%0t we %b/%b a %h/%h q %h/%h", $time, we_o, we_n, a_o, a_n, q_o, q_n);
        end
        if (we_o) writes = writes + 1;
    end
    initial begin
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        for (img = 0; img < 3; img = img + 1) begin
            @(posedge clk); load_start <= 1; idx <= img; @(posedge clk); load_start <= 0;
            for (i = 0; i < WORDS; i = i + 1) begin
                pv <= 1; rgb <= $random; @(posedge clk); pv <= 0;
                gap = (i < 300) ? 0 : ($random & 7);   // 前段背靠背，制造 FIFO 积压
                repeat (gap) @(posedge clk);
            end
            commit <= 1; @(posedge clk); commit <= 0;
            wait (d_o); repeat (20) @(posedge clk);
        end
        $display("DONE writes=%0d expected=%0d errs=%0d complete=%b err=%h", writes, 3*WORDS, errs, c_n, e_n);
        $finish;
    end
endmodule
