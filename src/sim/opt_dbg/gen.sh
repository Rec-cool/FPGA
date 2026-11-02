#!/bin/sh
# 从当前源码重新生成仿真用副本（只调整 load_cmd_idx 的声明顺序）
H=../../user_source/hdl_source/SD
fix(){ perl -pe 's/^wire \[1:0\]\s+load_cmd_idx = load_ctrl_idx;/wire [1:0] load_cmd_idx;/; s/^(reg \[1:0\] load_ctrl_idx;.*)$/$1\nassign load_cmd_idx = load_ctrl_idx;/' ; }
tr -d '\r' < $H/sd_card_bmp.v | fix > sd_card_bmp_new_sim.v
