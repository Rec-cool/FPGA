`timescale 1ns/1ps
// 11-01 SV 整链路：真实 sd_card_bmp（扫描器 + config_parser + 仲裁器 + cfg_saver + streamer + 缩放器 + 适配层）
// + 支持写扇区的卡模型 + 音频播放器桩（一直按顺序读歌曲扇区，逐字节核对）。
// 每次保存都检查：
//   - result；写了几个扇区、写到哪里
//   - 文件第 1 扇区 = 按格式独立拼出来的期望文本（补空格到 512）
//   - 目录项大小 = 512，卡上其他字节一个都没变
//   - 把写进去的扇区喂给另一个 config_parser，解析出来的 mask/值 = 保存时的值（往返一致）
//   - 音频：每个扇区 512 字节、内容正确、LBA 连续不跳，保存期间没收到别人的数据；保存后继续播放
// 用例：
//   A0 图片没加载完就按保存 → 失败、不写卡
//   A1 第一次保存（文件 100 字节，目录项在 PCM 后面）→ 写 2 个扇区（文件 + 目录）
//   A2 第二次保存 → 只写 1 个扇区；A3 200 组随机值
//   A4 写进去的数据被卡改坏 → 读回核对失败
//   A5 开机后换了卡（目录项名字 / 簇号不对）→ 失败、不写卡
//   A6 写卡卡死 → 超时失败、复位 SD 驱动、不重新扫描、音频恢复、之后还能保存
//   B  重新开机：扫描器 + 解析器读到的就是刚保存的值
//   C  卡上没有 CONFIG.TXT → result 1、不写卡
//   D  CONFIG.TXT 700 字节、目录项在根目录第二个簇 → 写 2 个扇区，大小改成 512
module tb;
    parameter integer W = 64, H = 16;
    localparam integer BYTE_GAP = 4;
    localparam integer STRIDE = W*3 + (W % 4);
    localparam integer IMG_BYTES = 54 + STRIDE*H;
    localparam integer CLUS = (IMG_BYTES + 511) / 512;
    localparam integer PWR = 100, INIT_TO = 5000, STALL = 20000, RETRY = 30000;
    localparam integer CFG_CLUS = 4660;                 // 0x1234：簇号高字节也核对得到
    localparam integer SV_TMO = 60000;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    bit present = 1;
    bit wr_hang = 0, wr_corrupt = 0;
    int wr_busy = 30;

    // ---------------- 卡内容 ----------------
    byte unsigned mem [longint];
    function automatic byte unsigned rd(longint lba, int i);
        if (mem.exists(lba*512 + i)) return mem[lba*512 + i];
        if (lba >= 430 && lba < 700) return (lba*7 + i*3) & 8'hff;    // 歌曲数据
        return 8'h00;
    endfunction
    task automatic wr8(longint lba, int i, byte unsigned v); mem[lba*512+i] = v; endtask
    task automatic wr16(longint lba, int i, int v); wr8(lba,i,v[7:0]); wr8(lba,i+1,v[15:8]); endtask
    task automatic wr32(longint lba, int i, int v); wr16(lba,i,v[15:0]); wr16(lba,i+2,v[31:16]); endtask
    function automatic int rd32(longint lba, int i); return {rd(lba,i+3), rd(lba,i+2), rd(lba,i+1), rd(lba,i)}; endfunction
    task automatic dirent(longint lba, int slot, string name11, int clus, int size);
        for (int k = 0; k < 11; k++) wr8(lba, slot*32+k, name11[k]);
        wr8(lba, slot*32+11, 8'h20);
        wr16(lba, slot*32+20, clus[31:16]); wr16(lba, slot*32+26, clus[15:0]);
        wr32(lba, slot*32+28, size);
    endtask
    task automatic fat_set(int c, int v); wr32(4 + (c >> 7), (c & 127) * 4, v); endtask
    function automatic longint clba(int c); return 130 + c; endfunction
    function automatic byte unsigned img_byte(int k, int off);
        case (off)
            0: return "B"; 1: return "M";
            10: return 54;
            18: return W[7:0]; 19: return W[15:8];
            22: return H[7:0]; 23: return H[15:8];
            28: return 8'd24;
            default: return (off < 54) ? 8'd0 : ((k*37 + off*13) & 8'hff);
        endcase
    endfunction
    function automatic int img_cluster(int k, int n); return 10 + k*(2*CLUS+4) + n*2; endfunction

    // has：有 CONFIG.TXT；pos：0 PIC 前面 / 1 PCM 后面 / 2 根目录第二簇
    longint cfg_dir_lba; int cfg_slot;
    task automatic build(bit has, int pos, string s1, int size);
        int s;
        mem.delete();
        wr8(0,0,8'heb); wr16(0,11,512); wr8(0,13,1); wr16(0,14,4); wr8(0,16,2);
        wr32(0,32,1000000); wr32(0,36,64); wr32(0,44,2);
        wr8(0,510,8'h55); wr8(0,511,8'haa);
        fat_set(2, (pos == 2) ? 32'd3 : 32'h0fffffff);
        fat_set(3, 32'h0fffffff);
        for (int k = 0; k < 16; k++) begin wr8(132, k*32, 8'he5); wr8(133, k*32, 8'he5); end
        s = 0;
        if (has && pos == 0) begin dirent(132, s, "CONFIG  TXT", CFG_CLUS, size); cfg_dir_lba = 132; cfg_slot = s; s++; end
        for (int k = 0; k < 4; k++) begin dirent(132, s, $sformatf("PIC%0d    BMP", k+1), img_cluster(k,0), IMG_BYTES); s++; end
        dirent(132, s, "SONGA   PCM", 300, 100000); s++;
        dirent(132, s, "SONGB   PCM", 400, 70000);  s++;
        if (has && pos == 1) begin dirent(132, s, "CONFIG  TXT", CFG_CLUS, size); cfg_dir_lba = 132; cfg_slot = s; s++; end
        if (pos == 2) begin
            if (has) begin dirent(133, 1, "CONFIG  TXT", CFG_CLUS, size); cfg_dir_lba = 133; cfg_slot = 1; end
            wr8(133, 2*32, 8'h00);
        end else
            wr8(132, s*32, 8'h00);
        fat_set(CFG_CLUS, CFG_CLUS + 1); fat_set(CFG_CLUS + 1, 32'h0fffffff);
        for (int k = 0; k < s1.len() && k < 512; k++) wr8(clba(CFG_CLUS), k, s1[k]);
        for (int k = 0; k < 4; k++) begin
            for (int n = 0; n < CLUS; n++) fat_set(img_cluster(k,n), n == CLUS-1 ? 32'h0fffffff : img_cluster(k,n+1));
            for (int off = 0; off < IMG_BYTES; off++) wr8(130 + img_cluster(k, off/512), off % 512, img_byte(k, off));
        end
    endtask

    // ---------------- DUT + loader 桩 ----------------
    wire ls, fc, pv, le, all_done; wire [1:0] li; wire [23:0] rgb; wire [5:0] cs;
    wire cfg_apply; wire [5:0] cfg_mask; wire [48:0] cfg_val;
    wire [4:0] pcm_count;
    reg lb = 0, ld = 0; reg [3:0] img_ok = 0;
    reg save_req = 0; reg [18:0] save_val = 0;
    wire save_busy, save_done; wire [1:0] save_result;
    wire aud_req; reg [31:0] aud_lba;
    wire aud_busy, aud_valid, aud_done; wire [7:0] aud_byte, aud_err; wire [8:0] aud_idx;
    always @(posedge clk) begin
        ld <= 0;
        if (rst) begin lb <= 0; img_ok <= 0; end
        else begin
            if (ls) lb <= 1;
            if (lb && (fc || le)) begin lb <= 0; ld <= 1; if (fc) img_ok[li] <= 1; end
        end
    end
    sd_card_bmp #(.BMP_WIDTH(W), .BMP_HEIGHT(H), .SCALE_ENABLE(1), .SCALE_MAX_W(4096), .SCALE_FIT(1), .SCALE_RATE(8),
                  .SD_PWRUP_CYC(PWR), .SD_INIT_TO_CYC(INIT_TO), .SD_STALL_CYC(STALL), .SD_SCAN_RETRY_CYC(RETRY)) u (
        .clk(clk), .rst(rst), .state_code(), .card_status(cs), .Sdr_init_done(1'b1),
        .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
        .image_complete(img_ok), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
        .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
        .load_all_done(all_done), .info_rd_idx(2'd0), .info_rd_data(),
        .aud_sector_req(aud_req), .aud_sector_lba(aud_lba), .aud_sector_busy(aud_busy), .aud_sector_valid(aud_valid),
        .aud_sector_done(aud_done), .aud_sector_byte(aud_byte), .aud_sector_error(aud_err), .aud_sector_byte_index(aud_idx),
        .pcm_count(pcm_count), .pcm_rd_idx(4'd0), .pcm_rd_lba(), .pcm_rd_sectors(),
        .pl_rd_idx(4'd0), .pl_rd_data(),
        .cfg_apply(cfg_apply), .cfg_mask(cfg_mask), .cfg_val(cfg_val),
        .save_req(save_req), .save_val(save_val), .save_busy(save_busy), .save_done(save_done), .save_result(save_result));
    defparam u.u_cfg_saver.TIMEOUT_CYC = SV_TMO;

    // ---------------- 记录 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 40) $display("ERR t=%0t %s", $time, m); endtask
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) fail($sformatf("%s: got %0d exp %0d", what, got, exp));
        else $display("  ok  %-60s = %0d", what, got);
    endtask
    wire [3:0] msg = cs[5:2];
    int n_apply = 0, n_scan = 0, n_wr = 0;
    longint wr_log [$];
    reg [5:0] last_mask; reg [48:0] last_val;
    always @(posedge clk) if (!rst) begin
        if (cfg_apply) begin n_apply++; last_mask = cfg_mask; last_val = cfg_val; end
        if (u.scan_start_pulse) n_scan++;
    end

    // ---------------- 音频播放器桩（同 wav_stream_player 的握手：WS_REQ 里 req && !busy 那拍被适配层接走）----------------
    bit aud_en = 0;
    int as = 0, a_cnt = 0, n_aud = 0, aud_gap = 0, aud_gap_max = 0;
    assign aud_req = (as == 1);
    always @(posedge clk) begin
        if (rst || !aud_en) begin as <= 0; aud_lba <= 430; n_aud <= 0; aud_gap <= 0; aud_gap_max <= 0; end
        else begin
            aud_gap <= aud_gap + 1;
            if (aud_valid && as != 2) fail("audio got sector data outside FILL");
            case (as)
                0: as <= 1;
                1: if (!aud_busy) begin as <= 2; a_cnt <= 0; end
                2: begin
                    if (aud_valid) begin
                        if (aud_byte !== rd(aud_lba, a_cnt)) fail($sformatf("audio lba %0d byte %0d: got %h exp %h", aud_lba, a_cnt, aud_byte, rd(aud_lba, a_cnt)));
                        a_cnt <= a_cnt + 1;
                    end
                    if (aud_done) begin
                        if (a_cnt + aud_valid != 512) fail($sformatf("audio lba %0d: %0d bytes", aud_lba, a_cnt + aud_valid));
                        aud_lba <= (aud_lba == 625) ? 430 : aud_lba + 1;
                        n_aud <= n_aud + 1;
                        if (aud_gap > aud_gap_max) aud_gap_max <= aud_gap;
                        aud_gap <= 0;
                        as <= 1;
                    end
                end
            endcase
        end
    end

    // ---------------- 往返解析：写进卡的扇区喂给另一个 config_parser ----------------
    reg pp_begin = 0, pp_valid = 0, pp_end = 0; reg [7:0] pp_byte = 0;
    wire pp_apply; wire [5:0] pp_mask; wire [4:0] pp_isec; wire pp_auto; wire [1:0] pp_bri, pp_mode; wire [2:0] pp_con; wire [3:0] pp_vol;
    config_parser #(.SEC_CYCLES(32'd100)) pp (
        .clk(clk), .rst_n(1'b1), .begin_pulse(pp_begin), .byte_valid(pp_valid), .byte_in(pp_byte), .end_pulse(pp_end),
        .apply(pp_apply), .mask(pp_mask), .interval_sec(pp_isec), .interval_cycles(), .auto_on(pp_auto),
        .bri(pp_bri), .con(pp_con), .mode(pp_mode), .vol(pp_vol));

    // ---------------- 期望文本（按格式说明独立拼）----------------
    function automatic string exp_text(bit [18:0] v);
        string s, crlf;
        crlf = "\015\012";
        s = {"#CONFIG.TXT  (KEY4+KEY2 hold 1s = save)", crlf,
             "#INTERVAL 1~30 s, AUTO ON/OFF, BRIGHT 0~3", crlf,
             "#CONTRAST 0~5 (2=1.0x), MODE SEQ/ONE/RND", crlf,
             "#VOLUME 0~10. Lines starting with # are off", crlf};
        s = {s, v[18] ? " " : "#", $sformatf("INTERVAL=%2d", v[17:13]), crlf};
        s = {s, v[12] ? "AUTO=ON " : "AUTO=OFF", crlf};
        s = {s, $sformatf("BRIGHT=%0d", v[11:10]), crlf, $sformatf("CONTRAST=%0d", v[9:7]), crlf};
        s = {s, "MODE=", (v[6:5] == 0) ? "SEQ" : (v[6:5] == 1) ? "ONE" : "RND", crlf};
        s = {s, v[4] ? " " : "#", $sformatf("VOLUME=%2d", v[3:0]), crlf};
        while (s.len() < 512) s = {s, " "};
        return s;
    endfunction
    function automatic bit [18:0] rand_val();
        bit [18:0] v;
        v[18] = $urandom_range(0, 1);
        v[17:13] = v[18] ? $urandom_range(1, 30) : $urandom_range(0, 31);
        v[12] = $urandom_range(0, 1);
        v[11:10] = $urandom_range(0, 3);
        v[9:7] = $urandom_range(0, 5);
        v[6:5] = $urandom_range(0, 2);
        v[4] = $urandom_range(0, 1);
        v[3:0] = $urandom_range(0, 10);
        return v;
    endfunction

    byte unsigned snap [longint];
    longint data_lba;
    function automatic byte unsigned snap_rd(longint k);
        longint lba = k / 512; int i = k % 512;
        if (snap.exists(k)) return snap[k];
        if (lba >= 430 && lba < 700) return (lba*7 + i*3) & 8'hff;
        return 8'h00;
    endfunction
    // 和保存前比，变了几个字节（按读出值比；skip_data：不看文件扇区；skip_size：不看目录项的大小字段）
    function automatic int card_diff(bit skip_data, bit skip_size);
        int d = 0;
        foreach (mem[k]) begin
            if (skip_data && k / 512 == data_lba) continue;
            if (skip_size && k / 512 == cfg_dir_lba && (k % 512) >= cfg_slot*32+28 && (k % 512) < cfg_slot*32+32) continue;
            if (rd(k / 512, k % 512) != snap_rd(k)) d++;
        end
        foreach (snap[k]) if (!mem.exists(k)) d++;
        return d;
    endfunction
    // 保存一次；exp_res = 期望结果，exp_wr = 期望写几个扇区；成功时核对内容
    task automatic do_save(string tag, bit [18:0] v, int exp_res, int exp_wr, bit quiet = 0);
        int w0, n0, n, diff; string got, ex;
        snap = mem; w0 = n_wr; n0 = n_aud;
        @(posedge clk); save_val <= v; save_req <= 1; @(posedge clk); save_req <= 0;
        n = 0;
        while (!save_done && n < SV_TMO + 50000) begin @(posedge clk); n++; end
        if (!save_done) begin fail({tag, " no save_done"}); return; end
        if (quiet) begin
            if (save_result != exp_res) fail($sformatf("%s result %0d exp %0d", tag, save_result, exp_res));
            if (n_wr - w0 != exp_wr) fail($sformatf("%s writes %0d exp %0d", tag, n_wr - w0, exp_wr));
        end else begin
            chk({tag, " result"}, save_result, exp_res);
            chk({tag, " sectors written"}, n_wr - w0, exp_wr);
            $display("      (save took %0d cycles)", n);
        end
        if (exp_wr >= 1) begin
            if (wr_log[w0] != data_lba) fail($sformatf("%s 1st write lba %0d exp %0d", tag, wr_log[w0], data_lba));
            if (exp_wr == 2 && wr_log[w0+1] != cfg_dir_lba) fail($sformatf("%s 2nd write lba %0d exp %0d", tag, wr_log[w0+1], cfg_dir_lba));
        end
        if (exp_res == 0) begin
            got = ""; for (int i = 0; i < 512; i++) got = {got, string'(byte'(rd(data_lba, i)))};
            ex = exp_text(v);
            if (got != ex) begin
                fail({tag, " file text mismatch"});
                for (int i = 0; i < 512; i++) if (got[i] != ex[i]) begin $display("      first diff @%0d got %h exp %h", i, got[i], ex[i]); break; end
            end else if (!quiet) $display("  ok  %-60s", {tag, " file text = expected (512 bytes)"});
            if (rd32(cfg_dir_lba, cfg_slot*32 + 28) != 512) fail({tag, " dir size != 512"});
            // 卡上其他字节都没变
            diff = card_diff(1, 1);
            if (diff != 0) fail($sformatf("%s %0d other bytes changed", tag, diff));
            // 往返解析
            @(posedge clk); pp_begin <= 1; @(posedge clk); pp_begin <= 0;
            for (int i = 0; i < 512; i++) begin pp_byte <= rd(data_lba, i); pp_valid <= 1; @(posedge clk); pp_valid <= 0; @(posedge clk); end
            pp_end <= 1; @(posedge clk); pp_end <= 0;
            while (!pp_apply) @(posedge clk);
            begin
                bit [5:0] em; em = {v[4], 4'b1111, v[18]};
                if (pp_mask != em) fail($sformatf("%s parse mask %b exp %b", tag, pp_mask, em));
                if (v[18] && pp_isec != v[17:13]) fail({tag, " parse INTERVAL"});
                if (pp_auto != v[12] || pp_bri != v[11:10] || pp_con != v[9:7] || pp_mode != v[6:5]) fail({tag, " parse AUTO/BRI/CON/MODE"});
                if (v[4] && pp_vol != v[3:0]) fail({tag, " parse VOLUME"});
                if (!quiet) $display("  ok  %-60s mask=%b", {tag, " round-trip parse"}, pp_mask);
            end
        end else begin
            diff = card_diff(exp_wr >= 1, 0);
            if (diff != 0) fail($sformatf("%s card changed on failed/refused save (%0d bytes)", tag, diff));
        end
        // 保存后音频继续
        if (!aud_en) return;
        n = 0; n0 = n_aud;
        while (n_aud < n0 + 3 && n < 200000) begin @(posedge clk); n++; end
        if (n_aud < n0 + 3) fail({tag, " audio did not resume"});
    endtask

    task automatic boot(bit has, int pos, string s1, int size, string tag);
        rst <= 1; aud_en = 0; wr_hang = 0; wr_corrupt = 0;
        build(has, pos, s1, size); data_lba = clba(CFG_CLUS);
        repeat (20) @(posedge clk);
        n_apply = 0; n_scan = 0; last_mask = 'x; last_val = 'x;
        rst <= 0;
    endtask
    task automatic wait_loaded(string tag);
        int n = 0;
        while (!(all_done && msg == 0) && n < 3_000_000) begin @(posedge clk); n++; end
        if (!all_done) fail({tag, " not loaded"}); else $display("  ok  %-60s (after %0d cycles)", {tag, " loaded"}, n);
        chk({tag, " pics"}, img_ok, 4'hf);
        chk({tag, " pcm_count"}, pcm_count, 2);
        aud_en = 1;
        repeat (20000) @(posedge clk);
    endtask

    initial begin
        bit [18:0] v; string t; longint saved_dir [int]; int n;
        // ---------- A ----------
        $display("A0 save before pictures loaded");
        boot(1, 1, "VOLUME=3\015\012BRIGHT=1\015\012", 20, "A");
        repeat (300) @(posedge clk);
        do_save("A0", 19'h12345, 2, 0);
        wait_loaded("A");
        chk("A boot cfg_apply", n_apply, 1);
        chk("A boot mask", last_mask, 6'b100100);
        $display("A1 first save (size 20 -> 512)");
        v = {1'b0, 5'd1, 1'b1, 2'd2, 3'd4, 2'd2, 1'b1, 4'd3};
        do_save("A1", v, 0, 2);
        chk("A1 audio max gap between sectors (cycles)", aud_gap_max < 20000, 1);
        $display("      audio max gap %0d cycles", aud_gap_max);
        $display("A2 second save (size already 512)");
        do_save("A2", {1'b1, 5'd30, 1'b0, 2'd0, 3'd5, 2'd1, 1'b1, 4'd10}, 0, 1);
        $display("A3 200 random saves");
        n = errs;
        for (int k = 0; k < 200; k++) do_save($sformatf("A3.%0d", k), rand_val(), 0, 1, 1);
        chk("A3 errors in 200 random saves", errs - n, 0);
        $display("A4 card corrupts written data");
        wr_corrupt = 1; snap = mem;
        do_save("A4", rand_val(), 2, 1);
        wr_corrupt = 0;
        $display("A5 card swapped after boot");
        t = ""; mem[cfg_dir_lba*512 + cfg_slot*32 + 3] = "X";
        do_save("A5a name changed", rand_val(), 2, 0);
        mem[cfg_dir_lba*512 + cfg_slot*32 + 3] = "F";
        mem[cfg_dir_lba*512 + cfg_slot*32 + 27] = 8'h13;
        do_save("A5b cluster changed", rand_val(), 2, 0);
        mem[cfg_dir_lba*512 + cfg_slot*32 + 27] = 8'h12;
        $display("A6 write hangs -> timeout");
        wr_hang = 1; n = n_scan;
        do_save("A6", rand_val(), 2, 1);
        wr_hang = 0;
        chk("A6 no rescan after driver reset", n_scan, n);
        chk("A6 pcm_count kept", pcm_count, 2);
        chk("A6 card msg still 0", msg, 0);
        v = {1'b1, 5'd7, 1'b1, 2'd1, 3'd0, 2'd0, 1'b0, 4'd9};
        do_save("A6 save after recovery", v, 0, 1);

        // ---------- B：重新开机，读到刚保存的值 ----------
        $display("B reboot with saved file");
        begin
            byte unsigned keep [longint]; keep = mem;
            rst <= 1; aud_en = 0; repeat (20) @(posedge clk);
            mem = keep; n_apply = 0; n_scan = 0; rst <= 0;
        end
        wait_loaded("B");
        chk("B cfg_apply", n_apply, 1);
        chk("B mask (INT/AUTO/BRI/CON/MODE, no VOL)", last_mask, 6'b011111);
        chk("B INTERVAL", last_val[16:12], 7);
        chk("B AUTO", last_val[11], 1);
        chk("B BRIGHT", last_val[10:9], 1);
        chk("B CONTRAST", last_val[8:6], 0);
        chk("B MODE", last_val[5:4], 0);

        // ---------- C：没有 CONFIG.TXT ----------
        $display("C no CONFIG.TXT");
        boot(0, 0, "", 0, "C");
        wait_loaded("C");
        do_save("C", rand_val(), 1, 0);

        // ---------- D：700 字节、根目录第二簇 ----------
        $display("D 700-byte CONFIG.TXT in 2nd root cluster");
        boot(1, 2, "MODE=ONE\012", 700, "D");
        wait_loaded("D");
        chk("D boot mask", last_mask, 6'b010000);
        do_save("D", {1'b1, 5'd12, 1'b0, 2'd3, 3'd3, 2'd2, 1'b1, 4'd0}, 0, 2);
        do_save("D again", rand_val(), 0, 1);

        $display("DONE tb_sv errs=%0d", errs);
        $finish;
    end
    initial begin #900ms; $display("TIMEOUT errs=%0d", errs + 1); $finish; end
endmodule

// sd_card_top 行为模型：读同 opt_cf；写 = sd_card_sec_read_write 的握手（data_req 下一拍取数，写优先）
module sd_card_top #(parameter SPI_LOW_SPEED_DIV = 248, parameter SPI_HIGH_SPEED_DIV = 0) (
    input clk, input rst,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done,
    input sd_sec_read, input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data, output reg sd_sec_read_data_valid, output reg sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output reg sd_sec_write_data_req, output reg sd_sec_write_end
);
    assign SD_nCS = 1'b1; assign SD_DCLK = 1'b0; assign SD_MOSI = 1'b1;
    initial begin
        sd_init_done = 0; sd_sec_read_data = 0; sd_sec_read_data_valid = 0; sd_sec_read_end = 0;
        sd_sec_write_data_req = 0; sd_sec_write_end = 0;
        forever begin
            sd_init_done <= 0; sd_sec_read_data_valid <= 0; sd_sec_read_end <= 0;
            sd_sec_write_data_req <= 0; sd_sec_write_end <= 0;
            wait (!rst);
            repeat (50) @(posedge clk);
            if (!rst && tb.present) sd_init_done <= 1;
            while (!rst) begin
                @(posedge clk);
                if (sd_init_done && sd_sec_write && !rst) begin : wr_sector
                    reg [31:0] L; byte unsigned b, buff [512];
                    L = sd_sec_write_addr; tb.n_wr++; tb.wr_log.push_back(L);
                    repeat (20) @(posedge clk);
                    for (int i = 0; i < 512 && !rst; i++) begin
                        sd_sec_write_data_req <= 1; @(posedge clk); sd_sec_write_data_req <= 0;
                        @(posedge clk); b = sd_sec_write_data;
                        repeat (tb.BYTE_GAP) @(posedge clk);
                        if (sd_sec_write_data !== b) tb.fail("write data not held until next req");
                        buff[i] = b;
                    end
                    while (tb.wr_hang && !rst) @(posedge clk);
                    if (!rst) begin
                        repeat (tb.wr_busy) @(posedge clk);
                        for (int i = 0; i < 512; i++) tb.wr8(L, i, (tb.wr_corrupt && i == 200) ? ~buff[i] : buff[i]);
                        sd_sec_write_end <= 1; @(posedge clk); sd_sec_write_end <= 0;
                    end
                end
                else if (sd_init_done && sd_sec_read && !rst) begin : rd_sector
                    reg [31:0] L; L = sd_sec_read_addr;
                    repeat (20) @(posedge clk);
                    for (int i = 0; i < 512 && !rst; i++) begin
                        sd_sec_read_data <= tb.rd(L, i); sd_sec_read_data_valid <= 1; @(posedge clk);
                        sd_sec_read_data_valid <= 0; repeat (tb.BYTE_GAP - 1) @(posedge clk);
                    end
                    if (!rst) begin sd_sec_read_end <= 1; @(posedge clk); sd_sec_read_end <= 0; end
                end
            end
        end
    end
endmodule
