`timescale 1ns/1ps
// 按键路由新旧比对：时钟按 100kHz 参数化（1 ms = 100 拍，消抖 20 ms，长按 1 s = 100000 拍）。
// 新版 KEY2 按住 >= 1 s：立即出 key2_long_event，松开不出 key2_event；其他所有输出与旧版逐拍一致。
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg k2 = 1, k4 = 1;
    localparam integer F = 100_000;
    localparam integer HOLD = F;          // 1 s
    wire o2, o4, o4l, osave, o2s, o4s, og, ol;
    wire n2, n2l, n4, n4l, nsave, n2s, n4s, ng, nl;
    dual_key_chord_router_old #(.CLK_FREQ_HZ(F), .KEY4_HOLD_MS(1000)) uo (
        .clk(clk), .rst_n(rst_n), .key2_in(k2), .key4_in(k4), .save_enabled(1'b1),
        .key2_event(o2), .key4_event(o4), .key4_long_event(o4l), .save_event(osave),
        .key2_stable(o2s), .key4_stable(o4s), .guard_trigger(og), .locked(ol));
    dual_key_chord_router #(.CLK_FREQ_HZ(F), .KEY4_HOLD_MS(1000), .KEY2_HOLD_MS(1000)) un (
        .clk(clk), .rst_n(rst_n), .key2_in(k2), .key4_in(k4), .save_enabled(1'b1),
        .key2_event(n2), .key2_long_event(n2l), .key4_event(n4), .key4_long_event(n4l), .save_event(nsave),
        .key2_stable(n2s), .key4_stable(n4s), .guard_trigger(ng), .locked(nl));
    defparam uo.u_dual_key_long_hold_guard.CLK_FREQ_HZ = F;
    defparam un.u_dual_key_long_hold_guard.CLK_FREQ_HZ = F;

    integer errs = 0, longs = 0, shorts_n = 0, shorts_o = 0, suppressed = 0, saves = 0, k4l = 0;
    // 新版 KEY2 进入 ST_KEY2 后的连续拍数（用于判断旧版短按是否应被吞掉）
    always @(posedge clk) begin
        if (n2l) longs++;
        if (n2) shorts_n++;
        if (o2) shorts_o++;
        if (o2 && !n2) suppressed++;
        if (nsave) saves++;
        if (n4l) k4l++;
        if (rst_n) begin
            if ({o4, o4l, osave, o2s, o4s, og, ol} !== {n4, n4l, nsave, n2s, n4s, ng, nl}) begin
                errs++; if (errs < 10) $display("MISMATCH t=%0t other outputs", $time); end
            if (n2 && !o2) begin errs++; $display("MISMATCH t=%0t new short without old", $time); end
            if (o2 && !n2 && !un.key2_long_marked) begin errs++; $display("MISMATCH t=%0t short lost without long", $time); end
            if (n2l && (un.state != 2'd1)) begin errs++; $display("MISMATCH long outside ST_KEY2"); end
        end
    end
    // 按键抖动后保持
    task automatic set_key(ref reg k, input bit v);
        repeat ($urandom_range(0, 6)) begin k = ~v; #($urandom_range(10, 3000)); k = v; #($urandom_range(10, 3000)); end
        k = v;
    endtask
    initial begin
        #100; rst_n = 1; #1000;
        for (int n = 0; n < 120; n++) begin
            automatic int kind = $urandom_range(0, 5);
            case (kind)
                0: begin set_key(k2, 0); #($urandom_range(50, 900) * 1000 * 1ns); set_key(k2, 1); end   // KEY2 短按
                1: begin set_key(k2, 0); #($urandom_range(1001, 2500) * 1000 * 1ns); set_key(k2, 1); end // KEY2 长按
                2: begin set_key(k2, 0); #($urandom_range(960, 1040) * 1000 * 1ns); set_key(k2, 1); end  // 临界
                3: begin set_key(k4, 0); #($urandom_range(50, 2000) * 1000 * 1ns); set_key(k4, 1); end   // KEY4
                4: begin set_key(k2, 0); #($urandom_range(30, 500) * 1000 * 1ns); set_key(k4, 0);         // 组合键
                         #($urandom_range(100, 1500) * 1000 * 1ns); set_key(k2, 1); set_key(k4, 1); end
                5: begin set_key(k2, 0); #($urandom_range(1100, 1500) * 1000 * 1ns); set_key(k4, 0);      // 长按后再加 KEY4
                         #($urandom_range(100, 1500) * 1000 * 1ns); set_key(k4, 1); set_key(k2, 1); end
            endcase
            #($urandom_range(60, 300) * 1000 * 1ns);
        end
        $display("DONE longs=%0d shorts new/old=%0d/%0d suppressed=%0d saves=%0d key4_long=%0d errs=%0d",
                 longs, shorts_n, shorts_o, suppressed, saves, k4l, errs);
        $finish;
    end
endmodule
