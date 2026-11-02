`timescale 1ns/1ps
// 看门狗测试：SD 模型前 FAIL_N 次复位释放后都不完成初始化，之后正常。
// 检查：上电等待时长、每次超时都重新复位驱动、重试计数、初始化完成后不再复位、成功后能发起扫描读扇区。
module sd_card_top #(parameter SPI_LOW_SPEED_DIV = 248, parameter SPI_HIGH_SPEED_DIV = 0) (
    input clk, input rst,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done,
    input sd_sec_read, input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data, output reg sd_sec_read_data_valid, output reg sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req, output sd_sec_write_end
);
    assign SD_nCS = 1'b1; assign SD_DCLK = 1'b0; assign SD_MOSI = 1'b1;
    assign sd_sec_write_data_req = 1'b0; assign sd_sec_write_end = 1'b0;
    integer releases = 0, cnt = 0, reads = 0;
    reg rst_q = 1;
    always @(posedge clk) begin
        rst_q <= rst;
        sd_sec_read_data_valid <= 0; sd_sec_read_end <= 0; sd_sec_read_data <= 0;
        if (rst) begin sd_init_done <= 0; cnt <= 0; end
        else begin
            if (rst_q) begin releases <= releases + 1; tb.log_release($time); end
            cnt <= cnt + 1;
            if (releases > tb.FAIL_N && cnt == 30) sd_init_done <= 1;
            if (sd_init_done && sd_sec_read && cnt[3:0] == 0) begin
                reads <= reads + 1; sd_sec_read_end <= 1;   // 只确认有读请求，内容不重要
            end
        end
    end
endmodule

module tb;
    parameter integer FAIL_N = 3;
    localparam integer PWR = 200, TO = 1000;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    integer errs = 0, nrel = 0;
    time trel[0:15];
    task log_release(input time t); begin if (nrel < 16) trel[nrel] = t; nrel = nrel + 1; end endtask
    wire [7:0] sc;
    sd_card_bmp #(.SD_PWRUP_CYC(PWR), .SD_INIT_TO_CYC(TO), .SCALE_ENABLE(1)) u (
        .clk(clk), .rst(rst), .state_code(sc), .Sdr_init_done(1'b1),
        .load_busy(1'b0), .load_done(1'b0), .image_complete(4'd0),
        .SD_MISO(1'b1), .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .pcm_rd_idx(4'd0));
    time t0;
    initial begin
        repeat (5) @(posedge clk); rst = 0; t0 = $time;
        wait (u.sd_init_done); repeat (200) @(posedge clk);
        // 第一次释放 ≈ t0 + PWR 拍；之后相邻释放间隔 ≈ TO + PWR 拍
        if (nrel != FAIL_N + 1) begin errs++; $display("FAIL releases=%0d exp %0d", nrel, FAIL_N+1); end
        if ((trel[0] - t0)/10 < PWR || (trel[0] - t0)/10 > PWR + 3) begin errs++; $display("FAIL first release at %0d cyc", (trel[0]-t0)/10); end
        for (int i = 1; i < nrel && i < 16; i++)
            if ((trel[i]-trel[i-1])/10 < TO + PWR || (trel[i]-trel[i-1])/10 > TO + PWR + 3) begin
                errs++; $display("FAIL gap %0d = %0d cyc", i, (trel[i]-trel[i-1])/10); end
        if (u.sd_retry != (FAIL_N > 7 ? 7 : FAIL_N)) begin errs++; $display("FAIL retry=%0d", u.sd_retry); end
        if (sc[2:0] != u.sd_retry || sc[7] != 1'b1) begin errs++; $display("FAIL state_code=%h", sc); end
        // 初始化完成后长时间不再复位驱动
        repeat (5*TO) @(posedge clk);
        if (nrel != FAIL_N + 1 || u.sd_drv_rst) begin errs++; $display("FAIL extra reset after init"); end
        if (sd_card_top_reads() == 0) begin errs++; $display("FAIL no sector read after init"); end
        $display("DONE FAIL_N=%0d releases=%0d retry=%0d state_code=%h reads=%0d errs=%0d",
                 FAIL_N, nrel, u.sd_retry, sc, sd_card_top_reads(), errs);
        $finish;
    end
    function integer sd_card_top_reads(); return u.sd_card_top_m0.reads; endfunction
    initial begin #20ms; $display("TIMEOUT errs=%0d", errs); $finish; end
endmodule
