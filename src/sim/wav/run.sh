#!/bin/sh
# 端到端仿真：SD 引擎模型 → sd_sector_adapter → wav_stream_player → media_hdmi_audio_bridge
# 用法（Git Bash，在本目录执行）：sh run.sh
M=/d/altera/14.1/modelsim_ase/win32aloem
SRC=../../user_source/hdl_source
$M/vlib work >/dev/null 2>&1
$M/vlog -sv -quiet tb_wav_e2e.v $SRC/SD/sd_sector_adapter.v $SRC/AUDIO/wav_stream_player.v \
    $SRC/AUDIO/media_hdmi_audio_bridge.v $SRC/AUDIO/audio_source_mux.v $SRC/AUDIO/pcm_media_tone.v \
    $SRC/AUDIO/m06_pcm_contract_adapter.v $SRC/AUDIO/hdmi_*.v || exit 1
$M/vsim -c tb_wav_e2e -do "run -all; quit" | grep "steady\|sd_reads\|sample#"
