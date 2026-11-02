#!/bin/sh
# 从顶层原样抽出 CONFIG.TXT 的 sd 域打包块和 video 域档位块（亮度/对比度/音量/间隔），生成 cdc_blk.v
T=../../user_source/hdl_source/top_tf_hdmi_audio.v
{
echo 'module cdc_blk #(parameter integer AUTO_PLAY_MS = 1500) (
  input sd_card_clk, input sdcard_rst_n, input cfg_apply, input [5:0] cfg_mask, input [48:0] cfg_val,
  input video_clk, input video_rst_n, input adj_toggle, input sw1, input sw2, input frame_start);
localparam [7:0] AUTO_PLAY_SEC = AUTO_PLAY_MS / 1000;
reg  [7:0] volume_sd, volume_pix;
reg  [7:0] period_sec_sd;
reg [15:0] period_ms_pix;'
awk '/^wire \[7:0\] cfg_vol_x25/{p=1} p{print} p&&/^end$/{exit}' $T
awk '/^function \[7:0\] bri_lut;/{p=1} /^\/\/ =+ 亮度对比度调节/{exit} p{print}' $T
echo 'endmodule'
} > cdc_blk.v
