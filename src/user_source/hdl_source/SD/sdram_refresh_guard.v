`timescale 1ns/1ps

// SDRAM 刷新守护（ext_mem_clk 域）
//
// 加密控制器 sdr_init_ref 的自刷新逻辑：
//     if (Sdr_ref_ack && (~Sdr_rw_vld)) ref_vld <= 1'b1;
// 刷新请求到来时若正有读写，这次刷新会被直接丢弃且不补发。
// 4bank 架构下图片只在上电写一次，reader 又持续突发读，
// 未在显示的 bank 长时间得不到刷新 → 数据衰减 → 花屏。
//
// 本模块周期性地：拉高 hold 阻止新的读/写 burst → 等总线连续空闲
// IDLE_CYCLES 拍 → 发一拍 App_ref_req → 等 Sdr_init_ref_vld 拉高再拉低
// （刷新确实执行完）→ 释放 hold。
module sdram_refresh_guard #(
    parameter integer REFRESH_PERIOD = 1500,  // 12us@125MHz，约 5333 次/64ms（2048 行需求的 2.6 倍）
    parameter integer IDLE_CYCLES    = 16,    // 最后一次读写/读返回之后需要的空闲拍数
    parameter integer ACK_TIMEOUT    = 255    // 发请求后等不到 ref_vld 的超时
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init_done,      // Sdr_init_done
    input  wire        app_wr_en,      // 控制器端口上的实际写命令
    input  wire        app_rd_en,      // 控制器端口上的实际读命令
    input  wire        sdr_rd_valid,   // 读数据返回
    input  wire        refresh_vld,    // Sdr_init_ref_vld
    output wire        hold,           // 1 = 禁止发起新的 burst
    output reg         ref_req,        // -> App_ref_req
    output reg  [15:0] timeout_count   // 调试：刷新请求未被执行的次数，正常应恒为 0
);
    localparam [2:0] S_RUN      = 3'd0;
    localparam [2:0] S_DRAIN    = 3'd1;
    localparam [2:0] S_WAIT_ON  = 3'd2;
    localparam [2:0] S_WAIT_OFF = 3'd3;

    reg [2:0]  state;
    reg [15:0] period_cnt;
    reg [7:0]  idle_cnt;
    reg [7:0]  wait_cnt;
    reg        hold_r;

    wire bus_active = app_wr_en || app_rd_en || sdr_rd_valid;

    // 控制器自己的刷新窗口里同样不允许发起新 burst
    assign hold = hold_r || refresh_vld;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_RUN;
            period_cnt    <= 16'd0;
            idle_cnt      <= 8'd0;
            wait_cnt      <= 8'd0;
            hold_r        <= 1'b0;
            ref_req       <= 1'b0;
            timeout_count <= 16'd0;
        end else if (!init_done) begin
            state      <= S_RUN;
            period_cnt <= 16'd0;
            idle_cnt   <= 8'd0;
            wait_cnt   <= 8'd0;
            hold_r     <= 1'b0;
            ref_req    <= 1'b0;
        end else begin
            ref_req <= 1'b0;
            case (state)
                S_RUN: begin
                    if (period_cnt == REFRESH_PERIOD - 1) begin
                        period_cnt <= 16'd0;
                        hold_r     <= 1'b1;
                        idle_cnt   <= 8'd0;
                        state      <= S_DRAIN;
                    end else begin
                        period_cnt <= period_cnt + 1'b1;
                    end
                end

                // 等进行中的 burst 发完、读数据全部返回
                S_DRAIN: begin
                    if (bus_active) begin
                        idle_cnt <= 8'd0;
                    end else if (idle_cnt == IDLE_CYCLES - 1) begin
                        ref_req  <= 1'b1;
                        wait_cnt <= 8'd0;
                        state    <= S_WAIT_ON;
                    end else begin
                        idle_cnt <= idle_cnt + 1'b1;
                    end
                end

                S_WAIT_ON: begin
                    if (refresh_vld) begin
                        state <= S_WAIT_OFF;
                    end else if (wait_cnt == ACK_TIMEOUT) begin
                        if (timeout_count != 16'hffff)
                            timeout_count <= timeout_count + 1'b1;
                        hold_r <= 1'b0;
                        state  <= S_RUN;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end

                S_WAIT_OFF: begin
                    if (!refresh_vld) begin
                        hold_r <= 1'b0;
                        state  <= S_RUN;
                    end
                end

                default: begin
                    hold_r <= 1'b0;
                    state  <= S_RUN;
                end
            endcase
        end
    end
endmodule
