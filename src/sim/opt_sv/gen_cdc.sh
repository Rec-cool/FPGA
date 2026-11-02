#!/bin/sh
# 11-01 SV：同 opt_cf/gen_cdc.sh，从顶层原样抽出 CONFIG 打包块和 video 域档位块（现在含保存参数用的 sv_bc 同步、save_val），
# 多加 ctrl_auto_enabled / track_mode 两个输入口
T=../../user_source/hdl_source/top_tf_hdmi_audio.v
{
echo 'module cdc_blk #(parameter integer AUTO_PLAY_MS = 1500) (
  input sd_card_clk, input sdcard_rst_n, input cfg_apply, input [5:0] cfg_mask, input [48:0] cfg_val,
  input video_clk, input video_rst_n, input adj_toggle, input sw1, input sw2, input frame_start,
  input ctrl_auto_enabled, input [1:0] track_mode);
localparam [7:0] AUTO_PLAY_SEC = AUTO_PLAY_MS / 1000;
reg  [7:0] volume_sd, volume_pix;
reg  [7:0] period_sec_sd;
reg [15:0] period_ms_pix;
wire [18:0] save_val;'
awk '/^wire \[7:0\] cfg_vol_x25/{p=1} p{print} p&&/^end$/{exit}' $T
awk '/^function \[7:0\] bri_lut;/{p=1} /^\/\/ =+ 亮度对比度调节/{exit} p{print}' $T
echo 'endmodule'
} > cdc_blk.v
# 测试台：opt_cf/tb_cdc.sv + 保存参数的检查
perl -pe '
  s/\.frame_start\(fs\)\);/.frame_start(fs), .ctrl_auto_enabled(sv_auto), .ctrl_auto_enabled_unused_(), .track_mode(sv_mode));/ if 0;
  s/(\.frame_start\(fs\))\);/$1, .ctrl_auto_enabled(sv_auto), .track_mode(sv_mode));/;
  if (/^\s*integer errs = 0, n_hit = 0, n_chg = 0;/) { $_ .= `cat tb_cdc_sv_add.svh`; }
  s/(\$display\("DONE tb_cdc hits=%0d errs=%0d", n_hit, errs\);)/\$display("  save_val checks: bri\/con %0d, flags %0d", n_bc, n_fl);\n        $1/;
  s/^(\s*reg adj = 0, sw1 = 0, sw2 = 0, fs = 0;)/$1\n    reg sv_auto = 0; reg [1:0] sv_mode = 0;/;
' ../opt_cf/tb_cdc.sv > tb_cdc_sv.sv
