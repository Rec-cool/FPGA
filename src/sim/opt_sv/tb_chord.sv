`timescale 1ns/1ps
// 11-01 SV：dual_key_chord_router 保存组合键。时间缩小 1000 倍（1 ms = 100 拍）。
// 新版：两键按住满 1 s 触发一次，不松手不再触发；旧版按住不放每秒触发一次（对照）。
// 其他输出（短按 / 长按事件）新旧完全一致。
module tb;
    localparam integer MS = 100;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg k2 = 1, k4 = 1;           // k2 = 端口 key1（丝印 KEY4），k4 = 端口 key2（丝印 KEY2），按下 = 0
    wire [4:0] ev [2];
    dual_key_chord_router #(.CLK_FREQ_HZ(100_000)) dn (.clk(clk), .rst_n(rst_n), .key2_in(k2), .key4_in(k4), .save_enabled(1'b1),
        .key2_event(ev[0][0]), .key2_long_event(ev[0][1]), .key4_event(ev[0][2]), .key4_long_event(ev[0][3]), .save_event(ev[0][4]),
        .key2_stable(), .key4_stable(), .guard_trigger(), .locked());
    dual_key_chord_router_old #(.CLK_FREQ_HZ(100_000)) dold (.clk(clk), .rst_n(rst_n), .key2_in(k2), .key4_in(k4), .save_enabled(1'b1),
        .key2_event(ev[1][0]), .key2_long_event(ev[1][1]), .key4_event(ev[1][2]), .key4_long_event(ev[1][3]), .save_event(ev[1][4]),
        .key2_stable(), .key4_stable(), .guard_trigger(), .locked());
    defparam dn.u_dual_key_long_hold_guard.CLK_FREQ_HZ = 100_000;
    defparam dold.u_dual_key_long_hold_guard.CLK_FREQ_HZ = 100_000;

    integer errs = 0;
    int cnt [2][5];
    always @(posedge clk) for (int d = 0; d < 2; d++) for (int e = 0; e < 5; e++) if (ev[d][e]) cnt[d][e]++;
    task automatic clr(); for (int d = 0; d < 2; d++) for (int e = 0; e < 5; e++) cnt[d][e] = 0; endtask
    task automatic wait_ms(int n); repeat (n * MS) @(posedge clk); endtask

    // 期望：{save, key4_long, key4, key2_long, key2} 的次数；新版对比 exp，旧版只比较 save 之外的 4 个 + 旧版 save 次数
    task automatic expect_(string tag, int s_new, int s_old, int k2e, int k2l, int k4e, int k4l);
        int e[5]; e = '{k2e, k2l, k4e, k4l, s_new};
        for (int i = 0; i < 4; i++) if (cnt[0][i] != e[i] || cnt[1][i] != e[i]) begin
            errs++; $display("ERR %s event %0d: new %0d old %0d exp %0d", tag, i, cnt[0][i], cnt[1][i], e[i]);
        end
        if (cnt[0][4] != s_new) begin errs++; $display("ERR %s save new %0d exp %0d", tag, cnt[0][4], s_new); end
        if (cnt[1][4] != s_old) begin errs++; $display("ERR %s save old %0d exp %0d", tag, cnt[1][4], s_old); end
        if (errs == 0) $display("  ok  %-46s save new=%0d old=%0d", tag, cnt[0][4], cnt[1][4]);
        clr();
    endtask

    initial begin
        clr();
        repeat (10) @(posedge clk); rst_n = 1; wait_ms(100);
        // 1. 两键同时按住 3.5 s
        k2 = 0; k4 = 0; wait_ms(3500); k2 = 1; k4 = 1; wait_ms(200);
        expect_("both held 3.5 s", 1, 3, 0, 0, 0, 0);
        // 2. 再按 1.5 s
        k2 = 0; k4 = 0; wait_ms(1500); k2 = 1; k4 = 1; wait_ms(200);
        expect_("both held 1.5 s (again)", 1, 1, 0, 0, 0, 0);
        // 3. 0.5 s
        k2 = 0; k4 = 0; wait_ms(500); k2 = 1; k4 = 1; wait_ms(200);
        expect_("both held 0.5 s", 0, 0, 0, 0, 0, 0);
        // 4. 先按 KEY4，200 ms 后再按 KEY2，一起按住 2.5 s，先松 KEY2
        k2 = 0; wait_ms(200); k4 = 0; wait_ms(2500); k4 = 1; wait_ms(100); k2 = 1; wait_ms(200);
        expect_("KEY4 then KEY2, held 2.5 s", 1, 2, 0, 0, 0, 0);
        // 5. 单键：KEY4 短按、KEY4 长按、KEY2 短按、KEY2 长按
        k2 = 0; wait_ms(200); k2 = 1; wait_ms(200);
        expect_("KEY4 short", 0, 0, 1, 0, 0, 0);
        k2 = 0; wait_ms(1500); k2 = 1; wait_ms(200);
        expect_("KEY4 long", 0, 0, 0, 1, 0, 0);
        k4 = 0; wait_ms(200); k4 = 1; wait_ms(200);
        expect_("KEY2 short", 0, 0, 0, 0, 1, 0);
        k4 = 0; wait_ms(1500); k4 = 1; wait_ms(200);
        expect_("KEY2 long", 0, 0, 0, 0, 0, 1);
        // 6. 保存后马上再按一次：要松开才能再触发
        k2 = 0; k4 = 0; wait_ms(1200); k2 = 1; k4 = 1; wait_ms(100); k2 = 0; k4 = 0; wait_ms(1200); k2 = 1; k4 = 1; wait_ms(200);
        expect_("two presses back to back", 2, 2, 0, 0, 0, 0);
        $display("DONE tb_chord errs=%0d", errs);
        $finish;
    end
endmodule
