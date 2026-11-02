`timescale 1ns/1ps
// sd_card_top 行为模型：sd_sec_read 电平请求 → 延迟 → 512 字节（每字节 BYTE_GAP 拍）→ end 一拍。
// 数据来自 tb.rd(lba, i)。记录每次读的 LBA 供检查。
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
    integer reads = 0;
    initial begin
        sd_init_done = 0; sd_sec_read_data = 0; sd_sec_read_data_valid = 0; sd_sec_read_end = 0;
        wait (!rst); repeat (50) @(posedge clk); sd_init_done <= 1;
        forever begin
            @(posedge clk);
            if (sd_sec_read) begin : rd_sector
                reg [31:0] L; L = sd_sec_read_addr; reads++;
                repeat (20 + ($urandom & 31)) @(posedge clk);
                for (int i = 0; i < 512; i++) begin
                    sd_sec_read_data <= tb.rd(L, i); sd_sec_read_data_valid <= 1; @(posedge clk);
                    sd_sec_read_data_valid <= 0; repeat (tb.BYTE_GAP - 1) @(posedge clk);
                end
                sd_sec_read_end <= 1; @(posedge clk); sd_sec_read_end <= 0;
            end
        end
    end
endmodule
