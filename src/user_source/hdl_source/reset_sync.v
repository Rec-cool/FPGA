`timescale 1ns/1ps

module reset_sync(
    input wire clk,//本时钟域时钟
    input wire ext_rst_n,//外部异步低有效复位
    output wire rst_n_sync//本域同步释放的低有效复位
);
    (* async_reg = "true" *) reg s1,s2;
    // 第 3 级只做扇出复制：s2 已稳定，综合按 max_fanout 复制出的各份 s3 在同一拍释放。
    // sd_card_clk 域复位扇出约 1400，单个寄存器布线延迟约 10.8ns，导致恢复时间违例。
    (* max_fanout = 64 *) reg s3;

    always @(posedge clk or negedge ext_rst_n) begin
            if(!ext_rst_n) begin
                s1 <= 1'b0;
                s2 <= 1'b0;
                s3 <= 1'b0;
            end else begin
                s1 <= 1'b1;
                s2 <= s1;
                s3 <= s2;
            end
    end
    assign rst_n_sync = s3;
endmodule