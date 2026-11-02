#!/bin/sh
# 10-30 CF 回归：opt_cs、opt_res tb_s2_reg CASE 0~3、opt_l2 两个测试台（全部用当前源码）
S=$(cd "$(dirname "$0")/.." && pwd); H=$S/../user_source/hdl_source; SD=$H/SD
q(){ grep -E "Error|ERR|DONE|TIMEOUT|A:|ok  未|功能"; }
echo "== opt_cs"; cd $S/opt_cs; rm -rf work_r; vlib work_r >/dev/null
vlog -work work_r -sv ../opt_cf/sd_card_bmp_new_sim.v $SD/bmp_scaler.v $SD/fat32_volume_scanner.v $SD/fat32_file_streamer.v $SD/sd_sector_adapter.v $SD/config_parser.v tb_cs.sv | grep Errors
vsim -c -lib work_r tb -do "run -all; quit" > cs_cf.log 2>&1; grep -E "ERR|DONE|TIMEOUT" cs_cf.log
echo "== opt_res tb_s2_reg"; cd $S/opt_res; sh gen.sh; rm -rf work_rcf; vlib work_rcf >/dev/null
vlog -work work_rcf -sv sd_card_bmp_new_sim.v sd_card_bmp_old_sim.v bmp_scaler_old_sim.v $SD/bmp_scaler.v $SD/fat32_volume_scanner.v $SD/fat32_file_streamer.v $SD/sd_sector_adapter.v $SD/config_parser.v sd_model.sv tb_s2_reg.sv | grep Errors
for c in 0 1 2 3; do vsim -c -lib work_rcf -gCASE=$c -gSD_PWRUP_CYC=100 -gSD_INIT_TO_CYC=5000 tb -do "run -all; quit" 2>&1 | grep -E "ERR|DONE|TIMEOUT|Fatal"; done
echo "== opt_l2 tb_l2"; cd $S/opt_l2; rm -rf work_lcf; vlib work_lcf >/dev/null
vlog -work work_lcf -sv $H/control/track_playlist.v track_playlist_old.v key_blk.v $SD/ax_debounce.v tb_l2.sv | grep Errors
vsim -c -lib work_lcf tb -do "run -all; quit" > l2_cf.log 2>&1; grep -E "ERR|DONE|TIMEOUT|A:" l2_cf.log
echo "== opt_l2 tb_panel2"; rm -rf work_pcf; vlib work_pcf >/dev/null
vlog -work work_pcf -sv $H/display/playlist_panel.v tb_panel2.sv | grep Errors
vsim -c -lib work_pcf tb -do "run -all; quit" 2>&1 | grep -E "ERR|DONE|TIMEOUT"
