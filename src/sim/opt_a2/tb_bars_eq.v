`timescale 1ns/1ps
// A2 等价比对：旧(32 路并行) 与新(RAM + 顺序平滑) 音频柱，逐拍比对像素输出。
module tb;
    reg clk = 0, rst_n = 0; always #20 clk = ~clk;      // 25 MHz
    wire hs, vs, de; wire [11:0] x, y;
    video_timing_ctrl #(.H_ACT(640),.H_FP(16),.H_SYNC(96),.H_BP(48),
                        .V_ACT(480),.V_FP(10),.V_SYNC(2),.V_BP(33),.ACTIVE_LAST(0))
        u_vtc(.pclk(clk),.rst_n(rst_n),.hsync(hs),.vsync(vs),.de(de),.x(x),.y(y));
    reg enable = 1;
    reg pv = 0; reg signed [15:0] pcm = 0;
    wire [23:0] rgb_in = {x[7:0], y[7:0], 8'h55};
    wire [23:0] ro, rn; wire ao, an;
    promax_audio_bars_old #(.DECIMATE(40),.UPDATE_DIV(2),.ATTACK_SHIFT(1),.RELEASE_SHIFT(3),.PEAK_HOLD(30))
        uo(clk,rst_n,vs,de,rgb_in,x[9:0],enable,pv,pcm,ro,ao);
    promax_audio_bars     #(.DECIMATE(40),.UPDATE_DIV(2),.ATTACK_SHIFT(1),.RELEASE_SHIFT(3),.PEAK_HOLD(30))
        un(clk,rst_n,vs,de,rgb_in,x[9:0],enable,pv,pcm,rn,an);

    integer errs = 0, bar_px = 0, frames = 0;
    always @(posedge clk) if (rst_n) begin
        if (ro !== rn || ao !== an) begin
            errs = errs + 1;
            if (errs < 8) $display("MISMATCH f=%0d x=%0d y=%0d old=%h new=%h", frames, x, y, ro, rn);
        end
        if (ao && de && y < 464 && x < 576) bar_px = bar_px + 1;
    end
    always @(negedge vs) frames = frames + 1;

    // PCM：每 520 拍一个样本，幅度包络随帧变化
    integer t = 0, amp = 0;
    always @(posedge clk) begin
        pv <= 0; t = t + 1;
        if (t % 520 == 0) begin
            pv  <= 1;
            pcm <= ($random % (amp + 1));
        end
    end
    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        amp = 30000; wait (frames == 6);
        amp = 4000;  wait (frames == 10);
        amp = 0;     wait (frames == 13);
        amp = 32767; enable = 0; wait (frames == 15);
        enable = 1;  wait (frames == 17);
        @(posedge clk); rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;   // 中途复位
        amp = 20000; wait (frames == 24);
        $display("DONE frames=%0d bar_pixels=%0d errs=%0d", frames, bar_px, errs);
        $finish;
    end
endmodule
