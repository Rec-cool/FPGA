`timescale 1ns/1ps
// 真实尺寸（640×480）参数计算检查：只跑 bmp_scaler 的参数计算，cw/ch/s/cx0/cy0 和黄金模型比较。
// 4:3 大图应为 640×480；其余比例与改动前（bmp_scaler_old）一致。
module tb_par;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0, start = 0; reg [15:0] w, h;
    wire rdy, rdy_o; wire [15:0] fw, fh, fw_o, fh_o;
    bmp_scaler     #(.OUT_W(640), .OUT_H(480), .MAX_W(4096), .FIT(1), .RATE(32)) u  (.clk(clk), .rst_n(rst_n), .abort(1'b0),
        .cfg_start(start), .src_w(w), .src_h(h), .cfg_ready(rdy), .fit_w(fw), .fit_h(fh), .go(1'b0),
        .in_valid(1'b0), .in_rgb(24'd0), .out_valid(), .out_rgb(), .out_last(), .fifo_level(), .overrun());
    bmp_scaler_old #(.OUT_W(640), .OUT_H(480), .MAX_W(4096), .FIT(1), .RATE(32)) uo (.clk(clk), .rst_n(rst_n), .abort(1'b0),
        .cfg_start(start), .src_w(w), .src_h(h), .cfg_ready(rdy_o), .fit_w(fw_o), .fit_h(fh_o), .go(1'b0),
        .in_valid(1'b0), .in_rgb(24'd0), .out_valid(), .out_rgb(), .out_last(), .fifo_level(), .overrun());
    integer errs = 0, n43 = 0, nchg = 0;
    task automatic one(int W, int H, bit quiet);
        longint unsigned ax, ay, qx, qy, qmax, qmin, s, cx0, cy0; int cw, ch; real loss;
        ax = longint'(W-1) << 16; ay = longint'(H-1) << 16;
        qx = ax / 639; qy = ay / 479;
        qmax = (qx > qy) ? qx : qy; qmin = (qx < qy) ? qx : qy;
        if (qmin >= 65536 && (qmax - qmin + 1) * 640 < qmin) s = qmin; else begin s = qmax; if (s < 65536) s = 65536; end
        cw = ax / s + 1; if (cw > 640) cw = 640;
        ch = ay / s + 1; if (ch > 480) ch = 480;
        cx0 = (ax - s*(cw-1)) >> 1; cy0 = (ay - s*(ch-1)) >> 1;
        @(posedge clk) begin w <= W; h <= H; start <= 1; end
        @(posedge clk) start <= 0;
        @(posedge clk);   // 等 cst 离开 C_DONE，否则会读到上一次的结果
        wait (rdy && rdy_o); @(posedge clk);
        if (fw !== cw || fh !== ch || u.s !== s[31:0] || u.cx0 !== cx0[31:0] || u.cy0 !== cy0[31:0]) begin
            errs++; $display("ERR %0dx%0d rtl %0dx%0d s=%h cx0=%h cy0=%h exp %0dx%0d s=%h cx0=%h cy0=%h", W, H, fw, fh, u.s, u.cx0, u.cy0, cw, ch, s, cx0, cy0);
        end
        // 采样点不能越出源图；裁掉的部分 < 1 个输出像素
        if (cx0 + s*(cw-1) > ax || cy0 + s*(ch-1) > ay) begin errs++; $display("ERR %0dx%0d sample outside", W, H); end
        loss = (real'(ax - s*(cw-1)) + real'(ay - s*(ch-1))) / real'(s);   // 两向未覆盖的源跨度，换算成输出像素
        if (W*3 == H*4 && W > 640) begin
            n43++;
            if (fw !== 640 || fh !== 480) begin errs++; $display("ERR 4:3 %0dx%0d -> %0dx%0d", W, H, fw, fh); end
        end
        if (fw !== fw_o || fh !== fh_o) begin
            nchg++;
            if (!(fw == 640 && fh == 480)) begin errs++; $display("ERR changed but not full: %0dx%0d", W, H); end
            if (loss >= 1.0) begin errs++; $display("ERR %0dx%0d loss %f", W, H, loss); end
        end else if (u.s !== uo.s || u.cx0 !== uo.cx0 || u.cy0 !== uo.cy0) begin
            errs++; $display("ERR %0dx%0d same size but params differ from old", W, H);
        end
        if (!quiet) $display("  %0dx%0d -> new %0dx%0d (old %0dx%0d) s=%0.5f loss=%0.3f", W, H, fw, fh, fw_o, fh_o, real'(s)/65536.0, loss);
    endtask
    initial begin
        repeat (5) @(posedge clk); rst_n <= 1; repeat (5) @(posedge clk);
        one(800, 600, 0); one(1024, 768, 0); one(1280, 960, 0); one(1600, 1200, 0); one(2048, 1536, 0); one(4096, 3072, 0);
        one(640, 480, 0); one(641, 481, 0); one(644, 483, 0); one(1280, 720, 0); one(1920, 1080, 0); one(2556, 1276, 0);
        one(1080, 1920, 0); one(320, 240, 0); one(641, 480, 0); one(640, 481, 0); one(1279, 960, 0); one(1281, 960, 0);
        for (int k = 161; k <= 1024; k++) one(4*k, 3*k, 1);               // 所有 4:3（宽 644~4096）
        for (int i = 0; i < 3000; i++) one(1 + {$random} % 4096, 1 + {$random} % 6000, 1);
        for (int i = 0; i < 2000; i++) begin                               // 接近 4:3 的随机尺寸
            automatic int W = 641 + {$random} % 3455; one(W, W*3/4 + ({$random} % 7) - 3, 1);
        end
        $display("DONE tb_par errs=%0d 4:3=%0d changed_vs_old=%0d", errs, n43, nchg);
        $finish;
    end
endmodule
