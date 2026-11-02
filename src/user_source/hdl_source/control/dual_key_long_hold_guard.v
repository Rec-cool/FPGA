module dual_key_long_hold_guard #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer LONG_PRESS_MS = 1000
)
(
    input  wire clk,
    input  wire rst_n,
    input  wire enabled,
    input  wire key2_in,
    input  wire key4_in,
    output reg key2_stable,
    output reg key4_stable,
    output reg trigger,
    output reg locked
);

localparam integer DEBOUNCE_CYCLES   = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
localparam integer LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
localparam integer DEBOUNCE_BIT      = (DEBOUNCE_CYCLES <= 2) ? 1 : $clog2(DEBOUNCE_CYCLES);
localparam integer LONG_PRESS_BIT    = (LONG_PRESS_CYCLES <= 2) ? 1 : $clog2(LONG_PRESS_CYCLES);
reg key2_sync0;
reg key2_sync1;
reg key4_sync0;
reg key4_sync1;
reg [DEBOUNCE_BIT-1 : 0] key2_cnt;
reg [DEBOUNCE_BIT-1 : 0] key4_cnt;
reg [LONG_PRESS_BIT-1: 0] long_press_cnt;


always @(posedge clk or negedge rst_n) begin
   
    if(!rst_n) begin
        key2_sync0  <= 1'b1;
        key2_sync1  <= 1'b1;
        key4_sync0  <= 1'b1;
        key4_sync1  <= 1'b1;
        key2_stable <= 1'b1;
        key4_stable <= 1'b1;
        key2_cnt           <= 0;
        key4_cnt           <= 0;
        long_press_cnt     <= 0;
        locked             <= 0;
        trigger            <= 0;
    end
    else begin  //三级同步
         trigger <= 0;
        key2_sync0  <= key2_in;
        key2_sync1  <= key2_sync0;
        key4_sync0  <= key4_in;
        key4_sync1  <= key4_sync0;
    

    //key2消抖
    if(key2_stable == key2_sync1) begin //必须要有稳定的不一致变化才算开始计数
        key2_cnt <= 0;
    end
    else if(key2_cnt >= DEBOUNCE_CYCLES - 1) begin
        key2_cnt <= 0;
        key2_stable <= key2_sync1;
    end
    else begin
        key2_cnt <= key2_cnt + 1;
    end

    //key4消抖
    if(key4_stable == key4_sync1) begin //必须要有稳定的不一致变化才算开始计数
        key4_cnt <= 0;
    end
    else if(key4_cnt >= DEBOUNCE_CYCLES - 1) begin
        key4_cnt <= 0;
        key4_stable <= key4_sync1;
    end
    else begin
        key4_cnt <= key4_cnt + 1;
    end

    if(!enabled || key2_stable || key4_stable || locked) begin
        long_press_cnt <= 0;
        locked <= 0;    //两个按键松开时解锁
    end
    else if(long_press_cnt >= LONG_PRESS_CYCLES - 1) begin
        long_press_cnt <= 0;
        locked  <= 1;
        trigger <= 1;
    end
    else begin
        long_press_cnt <= long_press_cnt + 1;
    end
    end
end
endmodule