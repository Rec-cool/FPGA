#!/bin/sh
# 11-01 SV 回归：本步新测试（tb_sv / tb_cmd / tb_chord / tb_cdc_sv）+ 之前的 opt_cf、opt_cs、opt_res、opt_l2（全部用当前源码，加了 cfg_saver.v）
export PATH=$PATH:/d/altera/14.1/modelsim_ase/win32aloem
S=$(cd "$(dirname "$0")/.." && pwd); H=$S/../user_source/hdl_source; SD=$H/SD; C=$H/control
COMMON="$SD/cfg_saver.v $SD/bmp_scaler.v $SD/fat32_volume_scanner.v $SD/fat32_file_streamer.v $SD/sd_sector_adapter.v $SD/config_parser.v"
cd $S/opt_cf && sh gen.sh
cd $S/opt_sv && cp ../opt_cf/sd_card_bmp_new_sim.v . && sh gen_cdc.sh
sed 's/^module sd_card_cmd(/module sd_card_cmd_old(/' $SD/sd_card_cmd.v.bak_20261101_sv > sd_card_cmd_old.v
tr -d '\r' < $C/dual_key_chord_router.v.bak_20261101_sv | sed 's/^module dual_key_chord_router /module dual_key_chord_router_old /' > chord_old.v
echo "== opt_sv tb_sv"; rm -rf work; vlib work >/dev/null
vlog -work work -sv sd_card_bmp_new_sim.v $COMMON tb_sv.sv | grep Errors:
vsim -c -lib work tb -do "run -all; quit" > sv.log 2>&1; grep -E "ERR|DONE|TIMEOUT|Fatal" sv.log
echo "== opt_sv tb_cmd"; rm -rf work_c; vlib work_c >/dev/null
vlog -work work_c -sv $SD/sd_card_cmd.v sd_card_cmd_old.v tb_cmd.sv | grep Errors:
vsim -c -lib work_c tb -do "run -all; quit" > cmd.log 2>&1; grep -E "ERR|DONE|Fatal" cmd.log
echo "== opt_sv tb_chord"; rm -rf work_k; vlib work_k >/dev/null
vlog -work work_k -sv $C/dual_key_chord_router.v $C/dual_key_long_hold_guard.v chord_old.v tb_chord.sv | grep Errors:
vsim -c -lib work_k tb -do "run -all; quit" > chord.log 2>&1; grep -E "ERR|DONE|Fatal" chord.log
echo "== opt_sv tb_cdc_sv"; rm -rf work_x; vlib work_x >/dev/null
vlog -work work_x -sv cdc_blk.v tb_cdc_sv.sv | grep Errors:
vsim -c -lib work_x tb -do "run -all; quit" > cdc.log 2>&1; grep -E "ERR|DONE|save_val|Fatal" cdc.log
echo "== opt_cf tb_cf"; cd $S/opt_cf; rm -rf work_sv; vlib work_sv >/dev/null
vlog -work work_sv -sv sd_card_bmp_new_sim.v $COMMON tb_cf.sv | grep Errors:
vsim -c -lib work_sv tb -do "run -all; quit" > cf_sv.log 2>&1; grep -E "ERR|DONE|TIMEOUT|Fatal" cf_sv.log
echo "== opt_cf tb_parser"; rm -rf work_psv; vlib work_psv >/dev/null
vlog -work work_psv -sv $SD/config_parser.v tb_parser.sv | grep Errors:
vsim -c -lib work_psv tb -do "run -all; quit" > parser_sv.log 2>&1; grep -E "ERR|DONE|TIMEOUT|Fatal" parser_sv.log | tail -2
echo "== opt_cs"; cd $S/opt_cs; rm -rf work_sv; vlib work_sv >/dev/null
vlog -work work_sv -sv ../opt_cf/sd_card_bmp_new_sim.v $COMMON tb_cs.sv | grep Errors:
vsim -c -lib work_sv tb -do "run -all; quit" > cs_sv.log 2>&1; grep -E "ERR|DONE|TIMEOUT|Fatal" cs_sv.log
echo "== opt_res tb_s2_reg"; cd $S/opt_res; sh gen.sh; rm -rf work_rsv; vlib work_rsv >/dev/null
vlog -work work_rsv -sv sd_card_bmp_new_sim.v sd_card_bmp_old_sim.v bmp_scaler_old_sim.v $COMMON sd_model.sv tb_s2_reg.sv | grep Errors:
for c in 0 1 2 3; do vsim -c -lib work_rsv -gCASE=$c -gSD_PWRUP_CYC=100 -gSD_INIT_TO_CYC=5000 tb -do "run -all; quit" 2>&1 | grep -E "ERR|DONE|TIMEOUT|Fatal"; done
echo "== opt_l2 tb_l2"; cd $S/opt_l2; rm -rf work_lsv; vlib work_lsv >/dev/null
vlog -work work_lsv -sv $H/control/track_playlist.v track_playlist_old.v key_blk.v $SD/ax_debounce.v tb_l2.sv | grep Errors:
vsim -c -lib work_lsv tb -do "run -all; quit" > l2_sv.log 2>&1; grep -E "ERR|DONE|TIMEOUT|A:" l2_sv.log
echo "== opt_l2 tb_panel2"; rm -rf work_psv; vlib work_psv >/dev/null
vlog -work work_psv -sv $H/display/playlist_panel.v tb_panel2.sv | grep Errors:
vsim -c -lib work_psv tb -do "run -all; quit" 2>&1 | grep -E "ERR|DONE|TIMEOUT"
