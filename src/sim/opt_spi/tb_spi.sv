`timescale 1ns/1ps
// SPI 分频检查：DCLK 周期、每字节拍数，以及 MISO 采样时刻距上一个 DCLK 下降沿（卡在下降沿后出数据）的时间
module tb;
    parameter integer DIV = 0;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1, req = 0; reg miso = 0;
    wire ncs, dclk, mosi, ack; wire [7:0] dout;
    spi_master u (.sys_clk(clk), .rst(rst), .nCS(ncs), .DCLK(dclk), .MOSI(mosi), .MISO(miso), .CPOL(1'b0), .CPHA(1'b0),
                  .nCS_ctrl(1'b0), .clk_div(DIV[15:0]), .wr_req(req), .wr_ack(ack), .data_in(8'h5a), .data_out(dout));
    realtime t_fall = 0, t_rise = 0, per = 0, smin = 1e9; integer bytes = 0; realtime t0, t1;
    always @(negedge dclk) t_fall = $realtime;
    always @(posedge dclk) begin if (t_rise > 0) per = $realtime - t_rise; t_rise = $realtime; end
    // 采样：MISO_shift 在 DCLK_EDGE 且 clk_edge_cnt 为偶数（即这拍把 DCLK 拉高）时移入
    always @(posedge clk) if (u.state == 1 && u.clk_edge_cnt[0] == 1'b0 && t_fall > 0)
        if ($realtime - t_fall < smin) smin = $realtime - t_fall;
    initial begin
        repeat (4) @(posedge clk); rst <= 0;
        @(posedge clk) req <= 1;
        repeat (3) begin @(posedge ack); bytes++; if (bytes == 1) t0 = $realtime; end
        t1 = $realtime; req <= 0;
        $display("DIV=%0d DCLK period=%0.0fns (%0.1fMHz) byte=%0.0f clk, sample after fall=%0.0fns", DIV, per, 1000.0/per, (t1-t0)/20.0, smin);
        $finish;
    end
endmodule
