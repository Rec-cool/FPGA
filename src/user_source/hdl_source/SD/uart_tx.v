module uart_tx #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tx_start,    // 拉高一个周期，开始发送
    input  wire [7:0] tx_data,     // 要发送的字节
    output reg        tx,          // 串口输出线
    output reg        tx_busy      // 忙标志
);

localparam BAUD_CNT = CLK_FREQ / BAUD_RATE;   // 100M/115200 ≈ 868

reg [15:0] baud_cnt;
reg [3:0]  bit_cnt;
reg [9:0]  shift_reg;    // 停止位 + 8数据 + 起始位

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx        <= 1'b1;      // 空闲高电平
        tx_busy   <= 1'b0;
        baud_cnt  <= 16'd0;
        bit_cnt   <= 4'd0;
        shift_reg <= 10'h3FF;   // 空闲全1
    end else begin
        if (tx_start && !tx_busy) begin
            // 装载：停止位(1) + 数据 + 起始位(0)
            shift_reg <= {1'b1, tx_data, 1'b0};
            tx_busy   <= 1'b1;
            baud_cnt  <= 16'd0;
            bit_cnt   <= 4'd0;
            tx        <= 1'b0;  // 立即发出起始位
        end else if (tx_busy) begin
            if (baud_cnt == BAUD_CNT - 1) begin
                baud_cnt <= 16'd0;

                if (bit_cnt == 4'd9) begin
                    // 停止位发完，结束
                    tx      <= 1'b1;
                    tx_busy <= 1'b0;
                    bit_cnt <= 4'd0;
                end else begin
                    tx        <= shift_reg[1];
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    bit_cnt   <= bit_cnt + 4'd1;
                end
            end else begin
                baud_cnt <= baud_cnt + 16'd1;
            end
        end
    end
end

endmodule