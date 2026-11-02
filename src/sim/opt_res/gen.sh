#!/bin/sh
# 从当前源码重新生成仿真用副本（只调整 load_cmd_idx 的声明顺序）；旧版 = 分辨率显示之前（.bak_20261027_preres）
H=../../user_source/hdl_source/SD
D=../../user_source/hdl_source/display
fix(){ perl -pe 's/^wire \[1:0\]\s+load_cmd_idx = load_ctrl_idx;/wire [1:0] load_cmd_idx;/; s/^(reg \[1:0\] load_ctrl_idx;.*)$/$1\nassign load_cmd_idx = load_ctrl_idx;/' ; }
tr -d '\r' < $H/sd_card_bmp.v | fix > sd_card_bmp_new_sim.v
tr -d '\r' < $H/sd_card_bmp.v.bak_20261027_preres | fix | perl -pe 's/^module sd_card_bmp\b/module sd_card_bmp_old/' > sd_card_bmp_old_sim.v
tr -d '\r' < $H/bmp_scaler.v.bak_20261027_preres | perl -pe 's/^module bmp_scaler\b/module bmp_scaler_old/' > bmp_scaler_old_sim.v
perl -pi -e 's/^bmp_scaler #\(/bmp_scaler_old #(/' sd_card_bmp_old_sim.v
tr -d '\r' < $D/promax_text_overlay.v.bak_20261027_preres | perl -pe 's/^module promax_text_overlay\b/module promax_text_overlay_old/' > txt_old.v
