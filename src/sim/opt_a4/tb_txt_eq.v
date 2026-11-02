`timescale 1ns/1ps
// A4 等价比对：旧(常数除法) 与新(BCD 移位加3) 参数条数字。
// 段1：快速 vsync，0~255 全扫，比对 14 个数字寄存器；段2：真实时序 2 帧，逐像素比对。
module tb;
    reg clk = 0, rst_n = 0; always #20 clk = ~clk;
    reg real_timing = 0;
    reg vs_fast = 1;
    wire hs, vs_t, de_t; wire [11:0] x, y;
    video_timing_ctrl #(.H_ACT(640),.H_FP(16),.H_SYNC(96),.H_BP(48),
                        .V_ACT(480),.V_FP(10),.V_SYNC(2),.V_BP(33),.ACTIVE_LAST(0))
        u_vtc(.pclk(clk),.rst_n(rst_n),.hsync(hs),.vsync(vs_t),.de(de_t),.x(x),.y(y));
    wire vs = real_timing ? vs_t : vs_fast;
    wire de = real_timing ? de_t : 1'b0;
    reg [7:0] bri = 0, con = 0, vol = 0; reg [31:0] per = 0; reg bar_show = 1, bar_sel = 0;
    wire [23:0] rgb_in = {x[7:0], y[7:0], 8'h33};
    wire [23:0] ro, rn; wire ao, an;
    promax_text_overlay_old #(.PARAM_X(8),.PARAM_Y(40),.BAR_Y(60),.SUBTITLE_Y(400),.H_ACTIVE(640)) uo(
        clk,rst_n,vs,de,rgb_in,x[9:0],1'b1,1'b1,96'd0,6'd8,bri,con,bar_show,bar_sel,vol,per,1'b1,1'b0,1'b0,ro,ao);
    promax_text_overlay     #(.PARAM_X(8),.PARAM_Y(40),.BAR_Y(60),.SUBTITLE_Y(400),.H_ACTIVE(640)) un(
        clk,rst_n,vs,de,rgb_in,x[9:0],1'b1,1'b1,96'd0,6'd8,bri,con,bar_show,bar_sel,vol,per,1'b1,1'b0,1'b0,rn,an);
    wire [111:0] dig_o = {uo.bright_h,uo.bright_t,uo.bright_o,uo.vol_h,uo.vol_t,uo.vol_o,uo.period_t,uo.period_o,
                          uo.bval_h,uo.bval_t,uo.bval_o,uo.cval_h,uo.cval_t,uo.cval_o};
    wire [111:0] dig_n = {un.bright_h,un.bright_t,un.bright_o,un.vol_h,un.vol_t,un.vol_o,un.period_t,un.period_o,
                          un.bval_h,un.bval_t,un.bval_o,un.cval_h,un.cval_t,un.cval_o};
    integer errs = 0, checks = 0, px = 0, i;
    always @(posedge clk) if (rst_n) begin
        if (dig_o !== dig_n || ro !== rn || ao !== an) begin
            errs = errs + 1; if (errs < 6) $display("MISMATCH t=%0t bri=%0d con=%0d vol=%0d", $time, bri, con, vol);
        end
        if (real_timing && an) px = px + 1;
    end
    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        for (i = 0; i < 256; i = i + 1) begin
            bri = i; con = 255 - i; vol = (i * 37) & 8'hff;
            per = (i % 4 == 0) ? 1000 : (i % 4 == 1) ? 5000 : (i % 4 == 2) ? 12000 : 40000;
            @(posedge clk); vs_fast = 0; @(posedge clk); vs_fast = 1;   // 一个帧起点
            repeat (2) @(posedge clk); checks = checks + 1;
        end
        $display("SWEEP checks=%0d errs=%0d  (bri=255 -> %s%s%s)", checks, errs, un.bval_h, un.bval_t, un.bval_o);
        bri = 192; con = 96; vol = 220; per = 5000; real_timing = 1;
        @(negedge vs_t); @(negedge vs_t); bar_sel = 1; @(negedge vs_t);
        $display("DONE overlay_pixels=%0d errs=%0d", px, errs);
        $finish;
    end
endmodule
