`timescale 1ns/1ps
// 10-29 SD 诊断口检查：真实驱动 + SPI 模式 3 简易卡模型
//   MODE 0：正常卡（ACMD41 前 3 次回 01，之后 00）→ 应初始化完成
//   MODE 1：卡不响应（MISO 恒 1）→ 应停在 CMD0，dbg_r1 = FF
//   MODE 2：卡一直空闲（ACMD41 永远回 01）→ 在 CMD55/CMD41 间循环，dbg_r1 = 01
// 同时例化改动前的驱动（*_old），比较引脚输出逐拍一致
module card #(parameter integer MODE = 0) (input ncs, input dclk, input mosi, output reg miso);
    reg [47:0] sh; integer nbits = 0; reg [7:0] q [0:15]; integer qn = 0, qi = 0; integer acmd41 = 0;
    reg [7:0] obyte = 8'hff; integer obit = 0;
    initial miso = 1'b1;
    task push(input [7:0] b); begin q[qn] = b; qn = qn + 1; end endtask
    always @(posedge dclk) if (!ncs) begin           // 模式 3：上升沿采样
        sh = {sh[46:0], mosi};
        if (nbits == 0) begin if (mosi == 1'b0) nbits = 1; end else nbits = nbits + 1;   // 起始位是 0（前面是空闲的 1）
        if (nbits == 48) begin
            nbits = 0; qn = 0; qi = 0;
            push(8'hff);                                 // 隔 1 字节回响应
            if (MODE != 1) case (sh[45:40])
                6'd0:  push(8'h01);
                6'd8:  begin push(8'h01); push(8'h00); push(8'h00); push(8'h01); push(8'haa); end
                6'd55: push(8'h01);
                6'd41: begin acmd41 = acmd41 + 1; push((MODE == 2 || acmd41 <= 3) ? 8'h01 : 8'h00); end
                6'd16: push(8'h00);
                default: push(8'h04);
            endcase
        end
    end
    always @(negedge dclk) begin                     // 下降沿出数据
        if (obit == 0) begin
            if (!ncs && qi < qn) begin obyte = q[qi]; qi = qi + 1; end else obyte = 8'hff;
        end
        miso = (MODE == 1) ? 1'b1 : obyte[7 - obit];
        obit = (obit + 1) % 8;
    end
    // 字节边界按 nCS 下降沿后重新对齐
    always @(negedge ncs) obit = 0;
endmodule

module tb;
    parameter integer MODE = 0;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    wire ncs, dclk, mosi, miso, done; wire [4:0] st; wire [7:0] r1;
    wire ncs_o, dclk_o, mosi_o, done_o;
    card #(.MODE(MODE)) c (.ncs(ncs), .dclk(dclk), .mosi(mosi), .miso(miso));
    sd_card_top #(.SPI_LOW_SPEED_DIV(8), .SPI_HIGH_SPEED_DIV(1)) u (
        .clk(clk), .rst(rst), .SD_nCS(ncs), .SD_DCLK(dclk), .SD_MOSI(mosi), .SD_MISO(miso), .sd_init_done(done),
        .sd_sec_read(1'b0), .sd_sec_read_addr(32'd0), .sd_sec_read_data(), .sd_sec_read_data_valid(), .sd_sec_read_end(),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0), .sd_sec_write_data_req(), .sd_sec_write_end(),
        .dbg_state(st), .dbg_r1(r1));
    sd_card_top_old #(.SPI_LOW_SPEED_DIV(8), .SPI_HIGH_SPEED_DIV(1)) o (
        .clk(clk), .rst(rst), .SD_nCS(ncs_o), .SD_DCLK(dclk_o), .SD_MOSI(mosi_o), .SD_MISO(miso), .sd_init_done(done_o),
        .sd_sec_read(1'b0), .sd_sec_read_addr(32'd0), .sd_sec_read_data(), .sd_sec_read_data_valid(), .sd_sec_read_end(),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0), .sd_sec_write_data_req(), .sd_sec_write_end());
    integer diffs = 0, errs = 0; reg [255:0] seen; integer k;
    always @(posedge clk) if (!rst && {ncs, dclk, mosi, done} !== {ncs_o, dclk_o, mosi_o, done_o}) diffs = diffs + 1;
    reg [7:0] code; reg [15:0] hist [0:7]; initial for (k = 0; k < 8; k = k + 1) hist[k] = 0;
    always @(posedge clk) if (!rst && !done) begin code = {1'b0, st[2:0], r1[3:0]}; if (hist[st[2:0]] == 0) $display("t=%0t enter drv state %0d, sd_dbg=%02h", $time, st, code); if (hist[st[2:0]] != 16'hffff) hist[st[2:0]] = hist[st[2:0]] + 1; end
    initial begin
        repeat (5) @(posedge clk); rst <= 0;
        fork : w
            begin wait (done); disable w; end
            begin #3_000_000; disable w; end
        join
        code = {1'b0, st[2:0], r1[3:0]};
        $display("MODE=%0d done=%0d final dbg_state=%0d dbg_r1=%02h sd_dbg=%02h pin diffs new-vs-old=%0d", MODE, done, st, r1, code, diffs);
        case (MODE)
            0: if (!done) errs = errs + 1;
            1: if (done || st != 5'd1 || r1 != 8'hff) errs = errs + 1;
            2: if (done || !(st == 5'd3 || st == 5'd4) || r1 != 8'h01) errs = errs + 1;
        endcase
        if (diffs != 0) errs = errs + 1;
        $display("errs=%0d", errs);
        $finish;
    end
endmodule
