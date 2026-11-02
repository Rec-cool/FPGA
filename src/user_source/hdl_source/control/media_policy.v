`timescale 1ns/1ps

// module media_policy (
//     // input  wire       clk,
//     // input  wire       rst_n,
//     // input  wire       next_event,
//     // input  wire       menu_up,
//     // input  wire       menu_down,
//     // input  wire       menu_select,
//     // input  wire [3:0] image_complete,

//     input  wire key_next_event,
//     input  wire key_auto_event,
//     input  wire key_prev_event,
//     input  wire key_save_event,

//     output wire next_event,
//     output wire auto_toggle_event,
//     output wire prev_event,
//     output wire save_event
//     // output reg  [1:0] media_id,
//     // output reg  [1:0] audio_id,
//     // output reg  [7:0] menu_state,
//     // output reg        linked_event
// );

// assign next_event = key_next_event;
// assign auto_toggle_event = key_auto_event;
// assign prev_event = key_prev_event;
// assign save_event = key_save_event;
//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             media_id <= 2'd0;
//             audio_id <= 2'd0;
//             menu_state <= 8'd0;
//             linked_event <= 1'b0;
//         end else begin
//             linked_event <= 1'b0;
//             if (next_event && image_complete != 0) begin
//                 media_id <= media_id + 1'b1;
//                 audio_id <= audio_id + 1'b1;
//                 linked_event <= 1'b1;
//             end
//             if (menu_up)
//                 menu_state <= menu_state + 1'b1;
//             else if (menu_down)
//                 menu_state <= menu_state - 1'b1;
//             if (menu_select)
//                 menu_state[7] <= ~menu_state[7];
//         end
//     end
// endmodule

 module media_policy (
      // 来自 dual_key_chord_router 的按键事件
      input  wire key_next_event,
      input  wire key_auto_event,
      input  wire key_prev_event,
      input  wire key_save_event,
      input  wire key_left_event,// key3消抖后单拍
      input  wire view_mode,      // 0=全屏 1=缩略图
      // 全屏模式命令
      output wire next_event,
      output wire auto_toggle_event,
      output wire prev_event,
      output wire save_event,
      // 缩放图模式命令
      output wire focus_left,
      output wire focus_right
  );

  assign next_event        = key_next_event & ~view_mode;
  assign auto_toggle_event = key_auto_event & ~view_mode;
  assign prev_event        = key_prev_event & ~view_mode;
  assign save_event        = key_save_event;
  assign focus_left        = key_left_event & view_mode;
  assign focus_right       = key_next_event & view_mode;
  endmodule