`timescale 1ns/1ps
// 11-01 SV：sd_card_cmd 写扇区的数据应答。新版收下所有 xxx0sss1 令牌（00101 接受 / 01011 CRC 错 / 01101 写错），
// 旧版只认 00101，卡回错误令牌时会永远停在 S_WRITE_SUC。
// 假 SPI 主机：spi_wr_req 拉高后 4 拍回 ack，并按 DUT 当前状态给应答：S_WRITE_SUC 先回 n_ff 个 0xFF 再回令牌，
// S_WRITE_BUSY 先回 n_busy 个 0x00 再回 0xFF，其余回 0xFF。
// 每次写检查：令牌后进入 BUSY、忙完给 block_write_req_ack；发出的字节 = FE + 512 个数据 + 2 个 CRC(FF)。
module spi_fake #(parameter integer ID = 0) (
    input clk, input rst, input req, input [7:0] din, input [4:0] st,
    output reg ack, output reg [7:0] dout
);
    int cnt = 0; bit busy = 0; int k_suc = 0, k_busy = 0;
    always @(posedge clk) begin
        ack <= 0;
        if (rst) begin busy = 0; cnt = 0; k_suc = 0; k_busy = 0; end
        else if (!busy && req && !ack) begin busy = 1; cnt = 0; end
        else if (busy) begin
            cnt++;
            if (cnt == 4) begin
                busy = 0; ack <= 1;
                tb.sent(ID, din, st);
                if (st == 13) begin dout <= (k_suc < tb.n_ff) ? 8'hff : tb.token; k_suc++; end
                else begin k_suc = 0; end
                if (st == 14) begin dout <= (k_busy < tb.n_busy) ? 8'h00 : 8'hff; k_busy++; end
                else k_busy = 0;
                if (st != 13 && st != 14) dout <= 8'hff;
            end
        end
    end
endmodule

module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    reg [7:0] token = 8'h05; int n_ff = 2, n_busy = 5;
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 30) $display("ERR t=%0t %s", $time, m); endtask

    // 两个 DUT：0 = 新版，1 = 旧版
    reg  wreq [2];
    wire wrd [2], wack [2], sreq [2], sack [2];
    wire [7:0] sdin [2], sdout [2];
    reg  [7:0] wdata [2];
    int  widx [2];
    byte unsigned tx [2][$];
    task automatic sent(int id, byte unsigned b, int st); if (st >= 9 && st <= 12) tx[id].push_back(b); endtask
    function automatic byte unsigned pat(int round, int i); return (round*31 + i*7 + 3) & 8'hff; endfunction
    int round = 0;

    sd_card_cmd d0 (.sys_clk(clk), .rst(rst), .spi_clk_div(16'd0), .cmd_req(1'b0), .cmd_req_ack(), .cmd_req_error(),
        .cmd(48'd0), .cmd_r1(8'd0), .cmd_data_len(16'd0), .block_read_req(1'b0), .block_read_valid(), .block_read_data(),
        .block_read_req_ack(), .block_write_req(wreq[0]), .block_write_data(wdata[0]), .block_write_data_rd(wrd[0]),
        .block_write_req_ack(wack[0]), .nCS_ctrl(), .clk_div(), .spi_wr_req(sreq[0]), .spi_wr_ack(sack[0]),
        .spi_data_in(sdin[0]), .spi_data_out(sdout[0]));
    sd_card_cmd_old d1 (.sys_clk(clk), .rst(rst), .spi_clk_div(16'd0), .cmd_req(1'b0), .cmd_req_ack(), .cmd_req_error(),
        .cmd(48'd0), .cmd_r1(8'd0), .cmd_data_len(16'd0), .block_read_req(1'b0), .block_read_valid(), .block_read_data(),
        .block_read_req_ack(), .block_write_req(wreq[1]), .block_write_data(wdata[1]), .block_write_data_rd(wrd[1]),
        .block_write_req_ack(wack[1]), .nCS_ctrl(), .clk_div(), .spi_wr_req(sreq[1]), .spi_wr_ack(sack[1]),
        .spi_data_in(sdin[1]), .spi_data_out(sdout[1]));
    spi_fake #(0) f0 (.clk(clk), .rst(rst), .req(sreq[0]), .din(sdin[0]), .st(d0.state), .ack(sack[0]), .dout(sdout[0]));
    spi_fake #(1) f1 (.clk(clk), .rst(rst), .req(sreq[1]), .din(sdin[1]), .st(d1.state), .ack(sack[1]), .dout(sdout[1]));

    // 数据源：block_write_data_rd 的下一拍给数据（同 sd_card_sec_read_write）
    always @(posedge clk) for (int d = 0; d < 2; d++) if (wrd[d]) begin wdata[d] <= pat(round, widx[d]); widx[d]++; end

    // 发起一次写，返回是否在 max 拍内完成
    task automatic do_write(int d, output bit ok, output int cyc);
        int n = 0;
        tx[d].delete(); widx[d] = 0;
        wreq[d] <= 1;
        while (!wack[d] && n < 100000) begin @(posedge clk); n++; end
        wreq[d] <= 0; @(posedge clk);
        ok = wack[d] || n < 100000; cyc = n;
    endtask
    task automatic chk_tx(int d, string tag);
        bit good = (tx[d].size() == 515) && tx[d][0] == 8'hfe && tx[d][513] == 8'hff && tx[d][514] == 8'hff;
        for (int i = 0; i < 512 && good; i++) if (tx[d][i+1] != pat(round, i)) good = 0;
        if (!good) fail($sformatf("%s bytes sent wrong (n=%0d)", tag, tx[d].size()));
    endtask

    initial begin
        bit ok; int cyc;
        byte unsigned toks [] = '{8'h05, 8'h0b, 8'h0d, 8'he5, 8'h25, 8'heb};
        bit old_ok [] = '{1, 0, 0, 1, 1, 0};
        wreq[0] = 0; wreq[1] = 0; widx[0] = 0; widx[1] = 0;
        repeat (5) @(posedge clk); rst <= 0;
        repeat (2000) @(posedge clk);                     // S_INIT 发完 11 个字节回到 S_WAIT
        if (d0.state != 1 || d1.state != 1) fail("not in S_WAIT after init");
        foreach (toks[t]) begin
            for (int ff = 0; ff < 3; ff++) begin
                token = toks[t]; n_ff = ff * 3; n_busy = (t * 7 + ff * 11) % 40; round++;
                // 新版：每种令牌都要完成
                do_write(0, ok, cyc);
                if (!wack[0] && cyc >= 100000) fail($sformatf("new: token %h n_ff %0d hung", token, n_ff));
                else chk_tx(0, $sformatf("new token %h", token));
                if (d0.state != 1) fail($sformatf("new: token %h not back in S_WAIT (state %0d)", token, d0.state));
                // 旧版：只有 xxx00101 能完成（对照，说明测试能抓到原问题）；卡住的话复位它
                do_write(1, ok, cyc);
                if ((cyc < 100000) != old_ok[t]) fail($sformatf("old: token %h finished=%0d exp %0d", token, cyc < 100000, old_ok[t]));
                if (cyc >= 100000) begin
                    rst <= 1; @(posedge clk); rst <= 0; repeat (2000) @(posedge clk);
                end
            end
            $display("  ok  token %h: new finishes%s", toks[t], old_ok[t] ? ", old finishes" : ", old hangs (as expected)");
        end
        // 0xFF 不是令牌：新版要一直等（不能把 0xFF 当应答）
        token = 8'hff; n_ff = 0; round++;
        fork
            begin do_write(0, ok, cyc); end
            begin repeat (20000) @(posedge clk); end
        join_any
        if (d0.state != 13) fail($sformatf("new: 0xFF accepted as token (state %0d)", d0.state));
        else $display("  ok  0xFF is not a token: new keeps polling in S_WRITE_SUC");
        disable fork;
        $display("DONE tb_cmd errs=%0d", errs);
        $finish;
    end
endmodule
