`timescale 1ns/1ps
// L1：在 B1 扫描器比对的基础上，另外检查歌单表 pl_rd_data = {文件名前 8 字节, 扇区数}，
// 并把扇区模型的字节间隔改成可调（GAP=0 时每拍一个字节，最紧的情况）。
// B1 比对：新扫描器不再"4 张图找齐就提前结束"，读扇区序列可能比旧的长，
// 所以新旧各接一个独立的扇区模型，在 scan_done 时比对图片相关输出；
// 另外按期望表逐项检查新增的 *.PCM 歌曲表。
module tb;
    parameter integer GAP = 1;     // 0：字节连续；1：0~1 拍随机（同 B1）
    string last_name;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg scan_start = 0;
    byte unsigned img [longint];
    function automatic byte unsigned rd(longint lba, int i);
        longint k = lba*512 + i; return img.exists(k) ? img[k] : 8'h00;
    endfunction
    task automatic wr8(longint lba, int i, byte unsigned v); img[lba*512+i] = v; endtask
    task automatic wr16(longint lba, int i, int v); wr8(lba,i,v[7:0]); wr8(lba,i+1,v[15:8]); endtask
    task automatic wr32(longint lba, int i, int v); wr16(lba,i,v[15:0]); wr16(lba,i+2,v[31:16]); endtask
    task automatic sig(longint lba); wr8(lba,510,8'h55); wr8(lba,511,8'haa); endtask
    task automatic dirent(longint lba, int slot, string name11, byte unsigned attr, int clus, int size);
        last_name = name11;
        for (int k = 0; k < 11; k++) wr8(lba, slot*32+k, name11[k]);
        wr8(lba, slot*32+11, attr);
        wr16(lba, slot*32+20, clus[31:16]); wr16(lba, slot*32+26, clus[15:0]);
        wr32(lba, slot*32+28, size);
    endtask
    task automatic deleted_fill(longint lba); for (int s = 0; s < 16; s++) wr8(lba, s*32, 8'he5); endtask
    task automatic boot(longint lba, int bps, int spc, int rsvd, int nfat, int fatsz, int tot, int rootc);
        wr8(lba,0,8'heb); wr16(lba,11,bps); wr8(lba,13,spc); wr16(lba,14,rsvd); wr8(lba,16,nfat);
        wr32(lba,32,tot); wr32(lba,36,fatsz); wr32(lba,44,rootc); sig(lba);
    endtask

    // ---------------- 两个独立扇区模型 ----------------
    wire req_o, req_n; wire [31:0] lba_o, lba_n;
    reg busy_o = 0, valid_o = 0, done_o = 0; reg [7:0] byte_o = 0; reg [8:0] idx_o = 0;
    reg busy_n = 0, valid_n = 0, done_n = 0; reg [7:0] byte_n = 0; reg [8:0] idx_n = 0;
    reg [7:0] serr = 0;
    integer reads_o = 0, reads_n = 0;
    always @(posedge clk) if (req_o) begin : serve_o
        longint L; L = lba_o; busy_o <= 1; reads_o = reads_o + 1;
        repeat (3 + ($urandom & 3)) @(posedge clk);
        for (int i = 0; i < 512; i++) begin
            valid_o <= 1; byte_o <= rd(L, i); idx_o <= i; @(posedge clk); valid_o <= 0;
            if (GAP) repeat ($urandom & 1) @(posedge clk);
        end
        done_o <= 1; @(posedge clk); done_o <= 0; busy_o <= 0;
    end
    always @(posedge clk) if (req_n) begin : serve_n
        longint L; L = lba_n; busy_n <= 1; reads_n = reads_n + 1;
        repeat (3 + ($urandom & 3)) @(posedge clk);
        for (int i = 0; i < 512; i++) begin
            valid_n <= 1; byte_n <= rd(L, i); idx_n <= i; @(posedge clk); valid_n <= 0;
            if (GAP) repeat ($urandom & 1) @(posedge clk);
        end
        done_n <= 1; @(posedge clk); done_n <= 0; busy_n <= 0;
    end

    wire bo, bn, do_, dn; wire [7:0] eo, en, so, sn; wire [31:0] po,pn,fo,fn,dso,dsn,mo,mn;
    wire [3:0] vo, vn; wire [31:0] c0o,c1o,c2o,c3o,s0o,s1o,s2o,s3o,c0n,c1n,c2n,c3n,s0n,s1n,s2n,s3n;
    wire [4:0] pcm_count; reg [3:0] pcm_rd_idx = 0; wire [31:0] pcm_lba; wire [23:0] pcm_sec; reg [3:0] pl_rd_idx = 0; wire [87:0] pl_data;
    fat32_volume_scanner_old uo(clk,rst_n,scan_start,bo,do_,eo,po,so,fo,dso,mo,vo,c0o,c1o,c2o,c3o,s0o,s1o,s2o,s3o,
                                req_o,lba_o,busy_o,valid_o,byte_o,idx_o,done_o,serr);
    fat32_volume_scanner     un(clk,rst_n,scan_start,bn,dn,en,pn,sn,fn,dsn,mn,vn,c0n,c1n,c2n,c3n,s0n,s1n,s2n,s3n,
                                pcm_count,pcm_rd_idx,pcm_lba,pcm_sec,pl_rd_idx,pl_data,
                                req_n,lba_n,busy_n,valid_n,byte_n,idx_n,done_n,serr);
    wire [511:0] res_o = {eo,po,so,fo,dso,mo,vo,c0o,c1o,c2o,c3o,s0o,s1o,s2o,s3o};
    wire [511:0] res_n = {en,pn,sn,fn,dsn,mn,vn,c0n,c1n,c2n,c3n,s0n,s1n,s2n,s3n};

    integer errs = 0;
    integer plchk = 0;
    int unsigned exp_lba [$]; int unsigned exp_sec [$]; string exp_name [$];
    task automatic run(string name);
        time t_o, t_n; int ro, rn;
        ro = reads_o; rn = reads_n;
        @(posedge clk); scan_start <= 1; @(posedge clk); scan_start <= 0;
        fork
            begin wait (do_); t_o = $time; end
            begin wait (dn);  t_n = $time; end
        join
        @(posedge clk);
        if (res_o !== res_n) begin errs++; $display("  MISMATCH image outputs"); end
        if (pcm_count != exp_lba.size()) begin
            errs++; $display("  MISMATCH pcm_count=%0d exp=%0d", pcm_count, exp_lba.size());
        end
        for (int i = 0; i < exp_lba.size() && i < 16; i++) begin
            pcm_rd_idx <= i; @(posedge clk); @(posedge clk);
            if (pcm_lba !== exp_lba[i] || pcm_sec !== exp_sec[i][23:0]) begin
                errs++; $display("  MISMATCH pcm[%0d] lba=%0d sec=%0d exp %0d/%0d", i, pcm_lba, pcm_sec, exp_lba[i], exp_sec[i]);
            end
            pl_rd_idx <= i; @(posedge clk); @(posedge clk);
            begin
                automatic reg [63:0] en8 = 0;
                for (int k = 0; k < 8; k++) en8[63-8*k -: 8] = exp_name[i][k];
                if (pl_data !== {en8, exp_sec[i][23:0]}) begin
                    errs++; $display("  MISMATCH pl[%0d] = %s/%0d exp %s/%0d", i, string'(pl_data[87:24]), pl_data[23:0], exp_name[i], exp_sec[i]);
                end else plchk++;
            end
        end
        $display("[%s] err=%h valid=%b c=%0d/%0d/%0d/%0d pcm=%0d reads old/new=%0d/%0d done_t old/new=%0t/%0t",
            name, en, vn, c0n, c1n, c2n, c3n, pcm_count, reads_o-ro, reads_n-rn, t_o, t_n);
        exp_lba.delete(); exp_sec.delete(); exp_name.delete();
        repeat (10) @(posedge clk);
    endtask
    task automatic expect_pcm(int unsigned lba, int unsigned sec); exp_lba.push_back(lba); exp_sec.push_back(sec); exp_name.push_back(last_name.substr(0, 7)); endtask

    initial begin
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        // ---- 场景0：歌曲表。4 张图都在第一个扇区（旧版到此提前结束），歌曲跨两个簇 ----
        // spc=1, fat=4, data=8 → LBA(c) = 6 + c；根目录簇链 2 -> 3 -> EOC
        boot(0, 512, 1, 4, 2, 2, 200000, 2);
        wr32(4, 2*4, 3); wr32(4, 3*4, 32'h0fffffff);
        dirent(8, 0,"PIC1    BMP",8'h20,100,921654);
        dirent(8, 1,"PIC2    BMP",8'h20,110,921654);
        dirent(8, 2,"PIC3    BMP",8'h20,120,921654);
        dirent(8, 3,"PIC4    BMP",8'h20,130,921654);
        dirent(8, 4,"SONG1   PCM",8'h20,200,26089472);   expect_pcm(206, 50956);
        dirent(8, 5,"XONG2   PCM",8'h20,210,9999999);  wr8(8, 5*32, 8'he5);   // 已删除
        dirent(8, 6,"_SONG~1 PCM",8'h22,220,4096000);   // 隐藏
        dirent(8, 7,"TINY    PCM",8'h20,230,65535);     // < 64KB
        dirent(8, 8,"SONG3   PCM",8'h01,300,65537);     expect_pcm(306, 129);   // 只读位不影响
        dirent(8, 9,"SONGX   PCM",8'h0f,310,999999);    // 长文件名项
        dirent(8,10,"DIRPC   PCM",8'h10,320,999999);    // 目录
        dirent(8,11,"SONG4   PCM",8'h20,32'h00010005,65536); expect_pcm(6+32'h00010005, 128);
        dirent(8,12,"SYS     PCM",8'h24,330,999999);    // 系统
        dirent(8,13,"SONG5   WAV",8'h20,340,999999);    // 扩展名不对
        dirent(8,14,"SONG6   PCM",8'h20,400,1000000);   expect_pcm(406, 1954);
        dirent(8,15,"SONG7   PCM",8'h20,410,512*1000);  expect_pcm(416, 1000);
        for (int k = 0; k < 13; k++) begin               // 簇3：13 首，表只收到满 16
            dirent(9, k, $sformatf("S%02d     PCM", k), 8'h20, 500+k, 70000+k);
            if (exp_lba.size() < 16) expect_pcm(506+k, (70000+k+511)/512);
        end
        wr8(9, 13*32, 8'h00);                             // 目录结束
        dirent(9,14,"LATE    PCM",8'h20,600,999999);    // 结束标志之后，不应收录
        run("pcm_table");
        // ---- 场景1：MBR 分区 + 根目录 3 簇 FAT 链 + 干扰目录项（同 A3）----
        img.delete();
        wr8(0,450,8'h0c); wr32(0,454,100); sig(0);
        boot(100, 512, 1, 4, 2, 2, 1000, 2);
        wr32(104, 2*4, 5); wr32(104, 5*4, 9); wr32(104, 9*4, 32'h0fffffff);
        deleted_fill(108); deleted_fill(111); deleted_fill(115);
        dirent(108,0,"MYCARD     ",8'h08,0,0);
        dirent(108,1,"PIC5    BMP",8'h20,30,111);
        dirent(108,2,"AIC1    BMP",8'h0f,31,222);
        dirent(108,3,"PIC1    BMP",8'h10,32,333);
        dirent(108,4,"PIC2    BMP",8'h21,40,921654);
        dirent(111,0,"MUSIC   WAV",8'h20,50,123456);
        dirent(111,7,"PIC1    BMP",8'h20,60,921654);
        dirent(115,3,"PIC4    BMP",8'h20,70,921654);
        dirent(115,9,"PIC3    BMP",8'h20,80,921654);
        wr8(115, 10*32, 8'h00);
        run("mbr_chain");
        // ---- 场景1b：4 张图在第一簇找齐，后面还有 2 个簇（旧版提前结束，新版扫完）----
        img.delete();
        boot(0, 512, 1, 4, 2, 2, 1000, 2);               // fat=4 data=8
        wr32(4, 2*4, 3); wr32(4, 3*4, 4); wr32(4, 4*4, 32'h0fffffff);
        deleted_fill(8); deleted_fill(9); deleted_fill(10);
        dirent(8,0,"PIC3    BMP",8'h20,20,921654); dirent(8,1,"PIC1    BMP",8'h20,21,921654);
        dirent(8,2,"PIC4    BMP",8'h20,22,921654); dirent(8,3,"PIC2    BMP",8'h20,23,921654);
        dirent(9,5,"README  TXT",8'h20,30,10);
        dirent(10,0,"LAST    PCM",8'h20,40,123456); expect_pcm(46, 242);
        run("early4");
        // ---- 场景2：无分区表 + spc=2，只有 2 张、无歌曲 ----
        img.delete();
        boot(0, 512, 2, 8, 1, 4, 5000, 3);
        deleted_fill(14);
        dirent(14,2,"PIC3    BMP",8'h20,9,1000);
        dirent(15,0,"PIC1    BMP",8'h20,7,2000);
        run("superfloppy");
        // ---- 场景3~5：错误 ----
        img.delete(); wr8(0,450,8'h0c); wr32(0,454,100); run("bad_sig");
        img.delete(); boot(0, 1024, 1, 4, 2, 2, 1000, 2); run("bad_bpb");
        img.delete(); boot(0, 512, 1, 4, 2, 2, 1000, 2);
        wr32(4, 2*4, 32'h0fffffff); dirent(8,0,"README  TXT",8'h20,5,10); run("missing");
        $display("DONE GAP=%0d errs=%0d pl_entries_checked=%0d", GAP, errs, plchk);
        $finish;
    end
endmodule
