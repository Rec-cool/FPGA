#!/bin/sh
# 从当前顶层生成 ModelSim 能编的副本 top_fix.v（把 4 个先用后声明的信号提前声明）
H=../../user_source/hdl_source
perl -pe '
  if ($. == 31) { $_ .= "  reg player_enable_sd; wire [23:0] disp_rgb; reg adj_toggle; wire key_adj_gated;\n"; }
  s/^wire \[23:0\] disp_rgb = /assign disp_rgb = /;
  s/^(\s*reg first_kick_done, first_kick_pulse), player_enable_sd;/$1;/;
  s/^wire key_adj_gated = /assign key_adj_gated = /;
  s/^reg adj_toggle;\s*$//;
' $H/top_tf_hdmi_audio.v > top_fix.v
