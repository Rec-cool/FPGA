module dual_key_chord_router #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer KEY4_HOLD_MS = 1000,
    parameter integer KEY2_HOLD_MS = 1000
)
(
    input wire clk,
    input wire rst_n,
    input wire key2_in,
    input wire key4_in,
    input wire save_enabled,
    output reg key2_event,
    output reg key2_long_event,     // KEY2 按满 KEY2_HOLD_MS 立即给出，松开时不再出短按
    output reg key4_event,
    output reg key4_long_event,
    output wire save_event,
    output wire key2_stable,
    output wire key4_stable,
    output wire guard_trigger,
    output wire locked
);

localparam [1:0]ST_IDLE = 2'd0;     //空闲
localparam [1:0]ST_KEY2 = 2'd1;     //按键二单独按下
localparam [1:0]ST_KEY4 = 2'd2;     //按键四单独按下
localparam [1:0]ST_CHORD = 2'd3;    //两者同时按下
localparam integer KEY4_HOLD_CYCLES = (CLK_FREQ_HZ / 1000) * KEY4_HOLD_MS;
localparam integer KEY2_HOLD_CYCLES = (CLK_FREQ_HZ / 1000) * KEY2_HOLD_MS;
reg [1:0] state;
reg [31:0] key4_hold_cnt;

// output declaration of module dual_key_long_hold_guard
reg save_armed;
reg long_press_marked;

dual_key_long_hold_guard #(
    .DEBOUNCE_MS   	(20    ),
    .LONG_PRESS_MS      	(1000  ))
u_dual_key_long_hold_guard(
    .clk           	(clk            ),
    .rst_n         	(rst_n          ),
    .enabled       	(save_enabled && save_armed && state == ST_CHORD),
    .key2_in        	(key2_in         ),
    .key4_in        	(key4_in         ),
    .trigger       	(guard_trigger        ),
    .locked        	(locked         ),
    .key2_stable 	(key2_stable  ),
    .key4_stable 	(key4_stable  )
);
assign save_event = guard_trigger;  //将保存脉冲传到顶层
// KEY2 长按：只在 ST_KEY2 内计时，离开该状态即清零
reg [31:0] key2_hold_cnt;
reg        key2_long_marked;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        key2_hold_cnt    <= 32'd0;
        key2_long_marked <= 1'b0;
        key2_long_event  <= 1'b0;
    end
    else begin
        key2_long_event <= 1'b0;
        if(state != ST_KEY2) begin
            key2_hold_cnt    <= 32'd0;
            key2_long_marked <= 1'b0;
        end
        else if(!key2_long_marked) begin
            if(key2_hold_cnt == KEY2_HOLD_CYCLES - 1) begin
                key2_long_marked <= 1'b1;
                key2_long_event  <= 1'b1;
            end
            else begin
                key2_hold_cnt <= key2_hold_cnt + 32'd1;
            end
        end
    end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= ST_IDLE;
        long_press_marked <= 1'b0;
        key4_hold_cnt     <= 32'd0;
        key4_long_event     <= 1'b0;
        key4_event          <= 1'b0;
        save_armed          <= 1'b0;
        key2_event          <= 1'b0;
    end
    else begin
        key2_event      <= 1'b0;
        key4_event      <= 1'b0;
        key4_long_event <= 1'b0;

        if(!save_enabled || guard_trigger) begin   // 11-01 SV：触发一次后要两键都松开才能再触发（原来按住不放每秒触发一次）
            save_armed <= 1'b0;
        end
        else if(key2_stable && key4_stable) begin//保证松开按键后才能再次触发保存操作
            save_armed <= 1'b1;
        end

    case(state)
        ST_IDLE: begin
            if(!key2_stable && !key4_stable) begin
                state <= ST_CHORD;
            end
            else if(!key2_stable) begin
                state <= ST_KEY2;
            end
            else if(!key4_stable) begin
                state <= ST_KEY4;
                long_press_marked <= 0;
                key4_hold_cnt <= 0;
            end
        end
        ST_KEY2: begin
            if(!key2_stable && !key4_stable) begin
                state <= ST_CHORD;
                key4_hold_cnt <= 0;
            end
            else if(key2_stable) begin  //检测松开状态
                key2_event <= !key2_long_marked;   // 已触发长按则不再出短按
                state <= !key4_stable ? ST_KEY4 : ST_IDLE;
                long_press_marked <= 0;
                key4_hold_cnt <= 0;
            end
        end
        ST_KEY4: begin
            if(!key2_stable && !key4_stable) begin
                state <= ST_CHORD;
                key4_hold_cnt <= 0;
                long_press_marked <= 0;
            end
            else if(key4_stable) begin //根据标志位和上升沿判断短按长按
                if(long_press_marked) begin
                    key4_long_event <= 1;
                end
                else begin
                    key4_event <= 1;
                end
                state <= !key2_stable ? ST_KEY2 : ST_IDLE;
            end
            else if(key4_hold_cnt == KEY4_HOLD_CYCLES - 1)begin
                key4_hold_cnt <= KEY4_HOLD_CYCLES;
                long_press_marked <= 1;
            end
            else if(key4_hold_cnt < KEY4_HOLD_CYCLES) begin
                key4_hold_cnt <= key4_hold_cnt + 32'd1;
            end
        end
        
        ST_CHORD: begin
            if (key2_stable && key4_stable)//保证保存后状态回归
            state <= ST_IDLE;
        end
        default:state <= ST_IDLE;
    endcase
     
    end
end

endmodule