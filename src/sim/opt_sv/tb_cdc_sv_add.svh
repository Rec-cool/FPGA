    // ---- 11-01 SV：save_val ----
    // 亮度/对比度档在 video 域稳定 30 个 sd 拍后，sv_bc_sd 要等于它；中途不会出现别的值（只会是新值或旧值）
    // 音量档 / 音量已设 / 间隔已设：apply 带对应 mask 位时更新，之后不变；save_val 的打包顺序
    int n_bc = 0, n_fl = 0, bc_stable = 0;
    reg [4:0] bc_prev, bc_old;
    int e_vl = 9; bit e_vs = 0, e_is = 0;
    always @(posedge sclk) sv_auto <= $urandom; 
    always @(posedge sclk) if (sv_mode != 2 && $urandom % 997 == 0) sv_mode <= $urandom % 3;
    always @(posedge sclk) if (srst_n) begin
        if ({u.bri_level, u.con_level} === bc_prev) bc_stable++; else begin bc_stable = 0; bc_old = bc_prev; end
        bc_prev = {u.bri_level, u.con_level};
        if (bc_stable == 30) begin n_bc++; if (u.sv_bc_sd !== bc_prev) fail($sformatf("sv_bc_sd %b exp %b", u.sv_bc_sd, bc_prev)); end
        if (u.sv_bc_sd !== bc_prev && u.sv_bc_sd !== bc_old && bc_stable > 0) fail($sformatf("sv_bc_sd glitch %b (cur %b old %b)", u.sv_bc_sd, bc_prev, bc_old));
        if (ap) begin
            if (m[5]) begin e_vl = v[3:0]; e_vs = 1; end
            if (m[0]) e_is = 1;
        end else begin
            n_fl++;
            if (u.vol_lvl_sd !== e_vl[3:0] || u.vol_set_sd !== e_vs || u.int_set_sd !== e_is)
                fail($sformatf("vol_lvl %0d/%0d vol_set %0d/%0d int_set %0d/%0d", u.vol_lvl_sd, e_vl, u.vol_set_sd, e_vs, u.int_set_sd, e_is));
            if (u.save_val !== {u.int_set_sd, u.period_sec_sd[4:0], sv_auto, u.sv_bc_sd, sv_mode, u.vol_set_sd, u.vol_lvl_sd})
                fail("save_val packing");
        end
    end
