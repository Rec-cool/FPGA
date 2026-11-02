`timescale 1ns/1ps
// 参数栏分辨率显示：新版 promax_text_overlay 对比分辨率显示之前的版本（txt_old.v）。
// 段 1（快速 vsync）：每组分辨率给一个帧起点，检查参数栏 47 个字符——
//   第 0~21 个字符（BRT/VOL/P/M:x）和旧版一致，第 22~46 个字符等于期望串 " IN:wwwwXhhhh OUT:wwwXhhh"。
// 段 2（真实时序 3 帧）：逐像素比对新旧输出，参数栏第 22 个字符起（x ≥ 8+22*12）以外必须完全相同；
//   并检查参数栏没有画出 x ≥ 8+47*12 的像素。
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
    reg [7:0] bri = 192, con = 96, vol = 200; reg [31:0] per = 5000; reg bar_show = 1, bar_sel = 0, auto_en = 1;
    reg rv = 0; reg [15:0] rsw = 0, rsh = 0; reg [9:0] row_ = 0; reg [8:0] roh = 0;
    wire [23:0] rgb_in = {x[7:0], y[7:0], 8'h33};
    wire [23:0] ro, rn; wire ao, an;
    promax_text_overlay_old #(.PARAM_X(8),.PARAM_Y(40),.BAR_Y(60),.SUBTITLE_Y(400),.H_ACTIVE(640)) uo(
        clk,rst_n,vs,de,rgb_in,x[9:0],1'b1,1'b1,96'd0,6'd8,bri,con,bar_show,bar_sel,vol,per,auto_en,1'b0,1'b0,ro,ao);
    promax_text_overlay #(.PARAM_X(8),.PARAM_Y(40),.BAR_Y(60),.SUBTITLE_Y(400),.H_ACTIVE(640)) un(
        .clk(clk), .rst_n(rst_n), .vsync(vs), .de(de), .rgb_in(rgb_in), .pixel_x(x[9:0]),
        .enable(1'b1), .subtitle_enable(1'b1), .subtitle_text(96'd0), .subtitle_length(6'd8),
        .brightness(bri), .contrast(con), .bar_show(bar_show), .bar_sel(bar_sel), .volume(vol), .period_ms(per),
        .auto_enabled(auto_en), .source_scale_2x(1'b0),
        .res_valid(rv), .res_src_w(rsw), .res_src_h(rsh), .res_out_w(row_), .res_out_h(roh),
        .subtitle_push(1'b0), .rgb_out(rn), .overlay_active(an));

    integer errs = 0, checks = 0;
    task automatic fail(string m); errs++; if (errs < 20) $display("ERR %s", m); endtask

    function automatic string rj(int v, int w, bit ok);     // 右对齐，左边补空格
        string s; s = ok ? $sformatf("%0d", v) : {w{"-"}};
        while (s.len() < w) s = {" ", s};
        return s;
    endfunction
    function automatic string lj(int v, int w, bit ok);     // 左对齐，右边补空格
        string s; s = ok ? $sformatf("%0d", v) : {w{"-"}};
        while (s.len() < w) s = {s, " "};
        return s;
    endfunction

    task automatic check_case(bit ok, int sw, int sh, int ow, int oh);
        string e, got; int dw, dh;
        rv = ok; rsw = sw; rsh = sh; row_ = ow; roh = oh;
        @(posedge clk); vs_fast = 0; @(posedge clk); vs_fast = 1;   // 一个帧起点
        repeat (2) @(posedge clk);
        dw = (sw > 9999) ? 9999 : sw; dh = (sh > 9999) ? 9999 : sh;
        e = {" IN:", rj(dw, 4, ok), "X", lj(dh, 4, ok), " OUT:", rj(ow, 3, ok), "X", lj(oh, 3, ok)};
        got = "";
        for (int i = 0; i < 47; i++) got = {got, string'(un.param_char(i))};
        for (int i = 0; i < 22; i++)
            if (un.param_char(i) !== uo.param_char(i)) fail($sformatf("char %0d new '%s' old '%s'", i, un.param_char(i), uo.param_char(i)));
        if (got.substr(22, 46) != e) fail($sformatf("ok=%0d %0dx%0d->%0dx%0d got \"%s\" exp \"%s\"", ok, sw, sh, ow, oh, got.substr(22, 46), e));
        checks++;
        if (checks <= 12) $display("  \"%s\"", got);
    endtask

    integer px_diff_out = 0, px_far = 0, px_res = 0;
    always @(posedge clk) if (rst_n && real_timing) begin
        automatic bit in_res = (y >= 38 && y < 58 && x >= 8 + 22*12 - 2);
        if (!in_res && (ro !== rn || ao !== an)) begin
            px_diff_out++; if (px_diff_out < 6) $display("MISMATCH x=%0d y=%0d", x, y);
        end
        if (y >= 40 && y < 56 && x >= 8 + 47*12 && de_t && an) px_far++;
        if (in_res && de_t && an) px_res++;
    end

    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        check_case(1, 1920, 1080, 640, 360);
        check_case(1, 640, 480, 640, 480);
        check_case(1, 1080, 1920, 270, 480);
        check_case(1, 800, 600, 640, 480);
        check_case(1, 320, 240, 320, 240);
        check_case(1, 1, 1, 1, 1);
        check_case(1, 20, 5, 20, 5);
        check_case(1, 4096, 482, 640, 75);
        check_case(1, 105, 10, 105, 10);
        check_case(1, 4096, 12000, 160, 480);    // 高 > 9999 按 9999 显示
        check_case(0, 0, 0, 0, 0);               // 没读成功
        check_case(0, 1920, 1080, 640, 360);     // 无效时不管数值都显示 ----
        auto_en = 0;
        check_case(1, 999, 1000, 99, 100);
        for (int i = 0; i < 300; i++)
            check_case($urandom_range(0, 9) != 0, $urandom_range(1, 4096), $urandom_range(1, 10000),
                       $urandom_range(1, 640), $urandom_range(1, 480));
        $display("STRINGS checks=%0d errs=%0d", checks, errs);
        rv = 1; rsw = 1920; rsh = 1080; row_ = 640; roh = 360; real_timing = 1;
        @(negedge vs_t); @(negedge vs_t); bar_sel = 1; @(negedge vs_t);
        if (px_diff_out != 0) fail($sformatf("%0d pixels differ outside resolution field", px_diff_out));
        if (px_far != 0) fail($sformatf("%0d param pixels beyond char 47", px_far));
        if (px_res == 0) fail("resolution field drew nothing");
        $display("DONE res_field_pixels=%0d diff_outside=%0d beyond=%0d errs=%0d", px_res, px_diff_out, px_far, errs);
        $finish;
    end
endmodule
