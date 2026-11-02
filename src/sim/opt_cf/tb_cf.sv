`timescale 1ns/1ps
// 10-30 CF 整链路：真实 sd_card_bmp（扫描器 + config_parser + streamer + 缩放器 + 适配层）+ opt_cs 的卡模型，
// 根目录里放 CONFIG.TXT（位置/属性/大小/内容可配）+ 4 张图 + 2 首 PCM（+ 用来混淆的近似名字）。
// 每个用例检查：
//   - cfg_begin / cfg_apply 次数（有效配置文件 1 次，否则 0 次）
//   - 送进解析器的字节 = 文件前 min(大小, 512) 字节（大于 512 只读第一个扇区，小于 512 时扇区后面的垃圾不送）
//   - cfg_mask / cfg_val 和期望一致（cfg_val 含间隔拍数 = 秒 × 1e8）
//   - 4 张图照常加载（msg 0、img_ok = F）、歌曲表（数量、LBA、扇区数、文件名）不受影响
// 用例：
//   C0 没有 CONFIG.TXT（只有近似名字 CONFIG  TXX / CONFIG1 TXT / CONFIG  TX_）  C1 完整配置（CRLF，放在 PIC 前面）
//   C2 部分无效 + BOM + 中文 + 行尾注释（放在 PCM 后面）                       C3 文件 700 字节：只解析第一扇区
//   C4 文件 21 字节，扇区后面有垃圾                                            C5 文件长度截在键名中间
//   C6 CONFIG.TXT 在根目录第二个簇                                             C7 删除项 / 目录 / 0 字节 / 目录结束标志之后：都不算
//   C8 没有图（扫描失败）但有配置：重试期间不发 apply；修好后发 1 次
module tb;
    parameter integer W = 64, H = 16;
    localparam integer BYTE_GAP = 4;
    localparam integer STRIDE = W*3 + (W % 4);
    localparam integer IMG_BYTES = 54 + STRIDE*H;
    localparam integer CLUS = (IMG_BYTES + 511) / 512;
    localparam integer PWR = 100, INIT_TO = 5000, STALL = 20000, RETRY = 30000;
    localparam integer CFG_CLUS = 200;                  // 配置文件第一簇（第二簇 201）

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    bit present = 1, dead = 0;
    int content = 0;

    // ---------------- 卡内容 ----------------
    byte unsigned mem [longint];
    function automatic byte unsigned rd(longint lba, int i);
        return mem.exists(lba*512 + i) ? mem[lba*512 + i] : 8'h00;
    endfunction
    task automatic wr8(longint lba, int i, byte unsigned v); mem[lba*512+i] = v; endtask
    task automatic wr16(longint lba, int i, int v); wr8(lba,i,v[7:0]); wr8(lba,i+1,v[15:8]); endtask
    task automatic wr32(longint lba, int i, int v); wr16(lba,i,v[15:0]); wr16(lba,i+2,v[31:16]); endtask
    task automatic dirent_a(longint lba, int slot, string name11, int clus, int size, byte unsigned attr);
        for (int k = 0; k < 11; k++) wr8(lba, slot*32+k, name11[k]);
        wr8(lba, slot*32+11, attr);
        wr16(lba, slot*32+20, clus[31:16]); wr16(lba, slot*32+26, clus[15:0]);
        wr32(lba, slot*32+28, size);
    endtask
    task automatic dirent(longint lba, int slot, string name11, int clus, int size); dirent_a(lba, slot, name11, clus, size, 8'h20); endtask
    task automatic fat_set(int c, int v); wr32(4 + (c >> 7), (c & 127) * 4, v); endtask
    function automatic longint clba(int c); return 130 + c; endfunction      // 每簇 1 扇区，数据区 132 = 簇 2
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

    // 配置文件描述
    typedef struct {
        bit    has;          // 有 CONFIG.TXT 目录项
        int    pos;          // 0：PIC 前面；1：PCM 后面；2：根目录第二簇
        string sec1, sec2;   // 文件第一、第二扇区内容（不足 512 字节补 0）
        int    size;
        bit    pics;         // 0：图片改名成 IMG*（扫描失败）
        bit    decoys;       // C0：近似名字
        bit    c7;           // C7：各种不该匹配的项
    } card_t;

    task automatic put_str(longint lba, string s); for (int k = 0; k < s.len() && k < 512; k++) wr8(lba, k, s[k]); endtask
    task automatic build(card_t cd);
        int s;
        mem.delete();
        wr8(0,0,8'heb); wr16(0,11,512); wr8(0,13,1); wr16(0,14,4); wr8(0,16,2);
        wr32(0,32,1000000); wr32(0,36,64); wr32(0,44,2);
        wr8(0,510,8'h55); wr8(0,511,8'haa);
        fat_set(2, (cd.pos == 2) ? 32'd3 : 32'h0fffffff);
        fat_set(3, 32'h0fffffff);
        for (int k = 0; k < 16; k++) begin wr8(132, k*32, 8'he5); wr8(133, k*32, 8'he5); end
        s = 0;
        if (cd.has && cd.pos == 0) begin dirent(132, s, "CONFIG  TXT", CFG_CLUS, cd.size); s++; end
        for (int k = 0; k < 4; k++) begin
            dirent(132, s, $sformatf(cd.pics ? "PIC%0d    BMP" : "IMG%0d    BMP", k+1), img_cluster(k,0), IMG_BYTES); s++;
        end
        dirent(132, s, "SONGA   PCM", 300, 100000); s++;
        dirent(132, s, "SONGB   PCM", 400, 70000);  s++;
        if (cd.decoys) begin
            dirent(132, s, "CONFIG  TXX", CFG_CLUS, cd.size); s++;
            dirent(132, s, "CONFIG1 TXT", CFG_CLUS, cd.size); s++;
            dirent(132, s, "CONFIG  TX_", CFG_CLUS, cd.size); s++;
            dirent(132, s, "ONFIG   TXT", CFG_CLUS, cd.size); s++;
        end
        if (cd.c7) begin
            dirent(132, s, "\345ONFIG  TXT", CFG_CLUS, cd.size); s++;                  // 已删除（0xE5）
            dirent_a(132, s, "CONFIG  TXT", CFG_CLUS, cd.size, 8'h10); s++;             // 目录
            dirent_a(132, s, "CONFIG  TXT", CFG_CLUS, cd.size, 8'h08); s++;             // 卷标
            dirent(132, s, "CONFIG  TXT", CFG_CLUS, 0); s++;                             // 0 字节
            wr8(132, s*32, 8'h00); s++;                                                  // 目录结束
            dirent(132, s, "CONFIG  TXT", CFG_CLUS, cd.size); s++;                       // 结束标志之后
        end
        if (cd.has && cd.pos == 1) begin dirent(132, s, "CONFIG  TXT", CFG_CLUS, cd.size); s++; end
        if (cd.pos == 2) begin
            dirent(133, 1, "CONFIG  TXT", CFG_CLUS, cd.size);
            wr8(133, 2*32, 8'h00);
        end else if (!cd.c7)
            wr8(132, s*32, 8'h00);
        fat_set(CFG_CLUS, CFG_CLUS + 1); fat_set(CFG_CLUS + 1, 32'h0fffffff);
        put_str(clba(CFG_CLUS), cd.sec1);
        put_str(clba(CFG_CLUS + 1), cd.sec2);
        for (int k = 0; k < 4; k++) begin
            for (int n = 0; n < CLUS; n++) fat_set(img_cluster(k,n), n == CLUS-1 ? 32'h0fffffff : img_cluster(k,n+1));
            for (int off = 0; off < IMG_BYTES; off++) wr8(130 + img_cluster(k, off/512), off % 512, img_byte(k, off));
        end
    endtask

    // ---------------- DUT + loader 桩 ----------------
    wire ls, fc, pv, le, all_done; wire [1:0] li; wire [23:0] rgb; wire [5:0] cs;
    wire cfg_apply; wire [5:0] cfg_mask; wire [48:0] cfg_val;
    wire [4:0] pcm_count; reg [3:0] pcm_rd_idx = 0; wire [31:0] pcm_rd_lba; wire [23:0] pcm_rd_sectors;
    reg [3:0] pl_rd_idx = 0; wire [87:0] pl_rd_data;
    reg lb = 0, ld = 0; reg [3:0] img_ok = 0;
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
        .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .aud_sector_busy(), .aud_sector_valid(), .aud_sector_done(),
        .aud_sector_byte(), .aud_sector_error(), .aud_sector_byte_index(),
        .pcm_count(pcm_count), .pcm_rd_idx(pcm_rd_idx), .pcm_rd_lba(pcm_rd_lba), .pcm_rd_sectors(pcm_rd_sectors),
        .pl_rd_idx(pl_rd_idx), .pl_rd_data(pl_rd_data),
        .cfg_apply(cfg_apply), .cfg_mask(cfg_mask), .cfg_val(cfg_val));

    // ---------------- 记录 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 40) $display("ERR t=%0t %s", $time, m); endtask
    wire [3:0] msg = cs[5:2];
    int  n_begin = 0, n_apply = 0;
    string got_bytes = "";
    reg [5:0] last_mask; reg [48:0] last_val;
    always @(posedge clk) if (!rst) begin
        if (u.cfg_begin) begin n_begin++; got_bytes = ""; end
        if (u.cfg_byte_valid) got_bytes = {got_bytes, string'(byte'(u.cfg_byte))};
        if (cfg_apply) begin n_apply++; last_mask = cfg_mask; last_val = cfg_val; end
    end
    reg ovr = 0; always @(posedge clk) if (u.u_bmp_scaler.overrun) ovr <= 1;

    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) fail($sformatf("%s: got %0d exp %0d", what, got, exp));
        else $display("  ok  %-56s = %0d", what, got);
    endtask
    task automatic wait_msg(int m, int max_cyc, string what);
        int n = 0;
        while (msg != m && n < max_cyc) begin @(posedge clk); n++; end
        if (msg != m) fail($sformatf("%s: msg=%0d, waited %0d cycles for %0d", what, msg, n, m));
        else $display("  ok  %-56s (after %0d cycles)", what, n);
    endtask
    task automatic reboot(card_t cd);
        rst <= 1; dead = 0; build(cd); repeat (20) @(posedge clk);
        n_begin = 0; n_apply = 0; got_bytes = ""; last_mask = 'x; last_val = 'x;
        rst <= 0;
    endtask
    // 歌曲表：2 首，LBA = 130 + 簇号，扇区数向上取整，文件名
    task automatic chk_songs(string tag);
        chk({tag, " pcm_count"}, pcm_count, 2);
        pcm_rd_idx = 0; pl_rd_idx = 0; repeat (3) @(posedge clk);
        chk({tag, " song0 lba"}, pcm_rd_lba, 430); chk({tag, " song0 sectors"}, pcm_rd_sectors, 196);
        chk({tag, " song0 name"}, pl_rd_data[87:24] == "SONGA   ", 1);
        pcm_rd_idx = 1; pl_rd_idx = 1; repeat (3) @(posedge clk);
        chk({tag, " song1 lba"}, pcm_rd_lba, 530); chk({tag, " song1 sectors"}, pcm_rd_sectors, 137);
        chk({tag, " song1 name"}, pl_rd_data[87:24] == "SONGB   ", 1);
    endtask
    // 期望值：mask {VOL, MODE, CON, BRI, AUTO, INT}；无效项的值不比较
    task automatic chk_cfg(string tag, bit [5:0] m, int isec, int aon, int bri, int con, int mode, int vol);
        chk({tag, " cfg_mask"}, last_mask, m);
        if (m[0]) begin chk({tag, " INTERVAL sec"}, last_val[16:12], isec); chk({tag, " INTERVAL cycles"}, last_val[48:17], isec * 64'd100_000_000); end
        if (m[1]) chk({tag, " AUTO"}, last_val[11], aon);
        if (m[2]) chk({tag, " BRIGHT"}, last_val[10:9], bri);
        if (m[3]) chk({tag, " CONTRAST"}, last_val[8:6], con);
        if (m[4]) chk({tag, " MODE"}, last_val[5:4], mode);
        if (m[5]) chk({tag, " VOLUME"}, last_val[3:0], vol);
    endtask
    function automatic string pad(string s, int n);       // 取前 n 字节，不足补 0
        string r = ""; for (int k = 0; k < n; k++) r = {r, string'(byte'((k < s.len()) ? s[k] : 8'h00))}; return r;
    endfunction
    // 跑一个用例：加载完成后检查
    task automatic run_case(string tag, card_t cd, bit exp_cfg, bit [5:0] m = 0,
                            int isec = 0, int aon = 0, int bri = 0, int con = 0, int mode = 0, int vol = 0);
        int n;
        $display("%s", tag);
        reboot(cd);
        wait_msg(0, 2_000_000, {tag, " loads to msg 0"});
        repeat (100) @(posedge clk);
        chk({tag, " pics loaded"}, img_ok, 4'hf);
        chk({tag, " cfg_begin count"}, n_begin, exp_cfg);
        chk({tag, " cfg_apply count"}, n_apply, exp_cfg);
        if (exp_cfg) begin
            n = (cd.size < 512) ? cd.size : 512;
            chk({tag, " bytes fed to parser"}, got_bytes.len(), n);
            chk({tag, " bytes match file"}, got_bytes == pad(cd.sec1, n), 1);
            chk_cfg(tag, m, isec, aon, bri, con, mode, vol);
        end
        chk_songs(tag);
    endtask

    function automatic card_t base();
        card_t c; c.has = 1; c.pos = 0; c.sec1 = ""; c.sec2 = ""; c.size = 0; c.pics = 1; c.decoys = 0; c.c7 = 0; return c;
    endfunction

    initial begin
        card_t cd; string t, fill;
        // C0
        cd = base(); cd.has = 0; cd.decoys = 1; cd.sec1 = "VOLUME=3\n"; cd.size = 9;
        run_case("C0 no CONFIG.TXT (decoy names only)", cd, 0);
        // C1
        cd = base(); cd.pos = 0;
        cd.sec1 = "# shop\r\nINTERVAL=5\r\nAUTO=ON\r\nBRIGHT=2\r\nCONTRAST=4\r\nMODE=RND\r\nVOLUME=7\r\n"; cd.size = cd.sec1.len();
        run_case("C1 full config, before PICs", cd, 1, 6'b111111, 5, 1, 2, 4, 2, 7);
        // C2
        cd = base(); cd.pos = 1;
        cd.sec1 = {"\357\273\277# INTERVAL=9\n", "INTERVAL=45\nAUTO=maybe\nBRIGHT = 1   # \344\272\256\345\272\246 0~3\n",
                   "CONTRAST=9\nmode=one ; 1/0\nVOLUME=x\n\350\275\256#AUTO=1\n"};
        cd.size = cd.sec1.len();
        run_case("C2 partial invalid + BOM + comments, after PCMs", cd, 1, 6'b010100, 0, 0, 1, 0, 1, 0);
        // C3：700 字节，第一扇区以 "VOLUME=2" 结尾（第二扇区接着是 "5\n"），只看第一扇区 → VOL=2
        cd = base(); fill = "";
        t = "BRIGHT=0\n";
        while (t.len() + 9 + 8 < 512) t = {t, "#........\n"};
        while (t.len() < 512 - 8) t = {t, " "};
        t = {t, "VOLUME=2"};
        cd.sec1 = t; cd.sec2 = "5\nMODE=RND\nCONTRAST=0\n"; cd.size = 700;
        run_case("C3 700-byte file: first sector only", cd, 1, 6'b100100, 0, 0, 0, 0, 0, 2);
        // C4：21 字节，后面是垃圾
        cd = base(); cd.sec1 = "AUTO=OFF\nINTERVAL=12\nMODE=RND\nCONTRAST=5\nVOLUME=1\n"; cd.size = 21;
        run_case("C4 21-byte file, garbage after EOF", cd, 1, 6'b000011, 12, 0, 0, 0, 0, 0);
        // C5：长度截在键名中间 "BRIGHT=1\nVOL"
        cd = base(); cd.sec1 = "BRIGHT=1\nVOLUME=4\n"; cd.size = 12;
        run_case("C5 EOF inside key name", cd, 1, 6'b000100, 0, 0, 1, 0, 0, 0);
        // C6：根目录第二簇，单行无换行，30 秒（最大）
        cd = base(); cd.pos = 2; cd.sec1 = "interval = 30"; cd.size = cd.sec1.len();
        run_case("C6 CONFIG.TXT in 2nd root cluster", cd, 1, 6'b000001, 30, 0, 0, 0, 0, 0);
        // C7
        cd = base(); cd.has = 0; cd.c7 = 1; cd.sec1 = "VOLUME=3\n"; cd.size = 9;
        run_case("C7 deleted/dir/label/0-byte/after-end entries", cd, 0);

        // C8：没有图但有配置 → 扫描失败，重试期间不发 apply；修好后 1 次
        $display("C8 scan fail with config");
        cd = base(); cd.pics = 0; cd.sec1 = "VOLUME=6\nMODE=SEQ\n"; cd.size = cd.sec1.len();
        reboot(cd);
        wait_msg(4, 2_000_000, "C8 -> msg 4 (no pictures)");
        repeat (RETRY * 3 + 20000) @(posedge clk);
        chk("C8 driver retried, cfg_begin still 0", n_begin, 0);
        chk("C8 cfg_apply still 0", n_apply, 0);
        cd.pics = 1; build(cd);
        wait_msg(0, RETRY * 2 + 2_000_000, "C8 fixed -> loads to 0");
        repeat (100) @(posedge clk);
        chk("C8 cfg_apply count after fix", n_apply, 1);
        chk_cfg("C8", 6'b110000, 0, 0, 0, 0, 0, 6);
        chk_songs("C8");

        if (ovr) fail("scaler overrun");
        $display("DONE tb_cf errs=%0d", errs);
        $finish;
    end
    initial begin #400ms; $display("TIMEOUT errs=%0d", errs + 1); $finish; end
endmodule

// sd_card_top 行为模型（同 opt_cs/tb_cs.sv）
module sd_card_top #(parameter SPI_LOW_SPEED_DIV = 248, parameter SPI_HIGH_SPEED_DIV = 0) (
    input clk, input rst,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done,
    input sd_sec_read, input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data, output reg sd_sec_read_data_valid, output reg sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req, output sd_sec_write_end
);
    assign SD_nCS = 1'b1; assign SD_DCLK = 1'b0; assign SD_MOSI = 1'b1;
    assign sd_sec_write_data_req = 1'b0; assign sd_sec_write_end = 1'b0;
    initial begin
        sd_init_done = 0; sd_sec_read_data = 0; sd_sec_read_data_valid = 0; sd_sec_read_end = 0;
        forever begin
            sd_init_done <= 0; sd_sec_read_data_valid <= 0; sd_sec_read_end <= 0;
            wait (!rst);
            repeat (50) @(posedge clk);
            if (!rst && tb.present) sd_init_done <= 1;
            while (!rst) begin
                @(posedge clk);
                if (sd_init_done && sd_sec_read && !rst) begin : rd_sector
                    reg [31:0] L; L = sd_sec_read_addr;
                    repeat (20) @(posedge clk);
                    for (int i = 0; i < 512 && !rst; i++) begin
                        while (tb.dead && !rst) @(posedge clk);
                        sd_sec_read_data <= tb.rd(L, i); sd_sec_read_data_valid <= 1; @(posedge clk);
                        sd_sec_read_data_valid <= 0; repeat (tb.BYTE_GAP - 1) @(posedge clk);
                    end
                    if (!rst) begin sd_sec_read_end <= 1; @(posedge clk); sd_sec_read_end <= 0; end
                end
            end
        end
    end
endmodule
