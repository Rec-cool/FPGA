`timescale 1ns/1ps
// A3 等价比对：旧扫描器(512B sector_buffer) 与新扫描器(字段直抓) 同激励逐拍比对全部输出。
module tb;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg scan_start = 0;
    // ---------------- 扇区模型（稀疏卡镜像）----------------
    byte unsigned img [longint];
    function automatic byte unsigned rd(longint lba, int i);
        longint k = lba*512 + i; return img.exists(k) ? img[k] : 8'h00;
    endfunction
    task automatic wr8(longint lba, int i, byte unsigned v); img[lba*512+i] = v; endtask
    task automatic wr16(longint lba, int i, int v); wr8(lba,i,v[7:0]); wr8(lba,i+1,v[15:8]); endtask
    task automatic wr32(longint lba, int i, int v); wr16(lba,i,v[15:0]); wr16(lba,i+2,v[31:16]); endtask
    task automatic sig(longint lba); wr8(lba,510,8'h55); wr8(lba,511,8'haa); endtask
    task automatic dirent(longint lba, int slot, string name11, byte unsigned attr, int clus, int size);
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

    wire req_o, req_n; wire [31:0] lba_o, lba_n;
    reg busy = 0, valid = 0, done = 0; reg [7:0] sbyte = 0; reg [8:0] sidx = 0; reg [7:0] serr = 0;
    integer reads = 0;
    always @(posedge clk) if (req_o) begin : serve
        longint L; L = lba_o; busy <= 1; reads = reads + 1;
        repeat (3 + ($urandom & 3)) @(posedge clk);
        for (int i = 0; i < 512; i++) begin
            valid <= 1; sbyte <= rd(L, i); sidx <= i; @(posedge clk); valid <= 0;
            repeat ($urandom & 1) @(posedge clk);
        end
        done <= 1; @(posedge clk); done <= 0; busy <= 0;
    end

    wire bo, bn, do_, dn; wire [7:0] eo, en, so, sn; wire [31:0] po,pn,fo,fn,dso,dsn,mo,mn;
    wire [3:0] vo, vn; wire [31:0] c0o,c1o,c2o,c3o,s0o,s1o,s2o,s3o,c0n,c1n,c2n,c3n,s0n,s1n,s2n,s3n;
    fat32_volume_scanner_old uo(clk,rst_n,scan_start,bo,do_,eo,po,so,fo,dso,mo,vo,c0o,c1o,c2o,c3o,s0o,s1o,s2o,s3o,
                                req_o,lba_o,busy,valid,sbyte,sidx,done,serr);
    fat32_volume_scanner     un(clk,rst_n,scan_start,bn,dn,en,pn,sn,fn,dsn,mn,vn,c0n,c1n,c2n,c3n,s0n,s1n,s2n,s3n,
                                req_n,lba_n,busy,valid,sbyte,sidx,done,serr);
    wire [511:0] out_o = {bo,do_,eo,po,so,fo,dso,mo,vo,c0o,c1o,c2o,c3o,s0o,s1o,s2o,s3o,req_o,lba_o};
    wire [511:0] out_n = {bn,dn,en,pn,sn,fn,dsn,mn,vn,c0n,c1n,c2n,c3n,s0n,s1n,s2n,s3n,req_n,lba_n};
    integer errs = 0;
    always @(posedge clk) if (rst_n && out_o !== out_n) begin
        errs = errs + 1; if (errs < 5) $display("MISMATCH t=%0t", $time);
    end

    task automatic run(string name);
        @(posedge clk); scan_start <= 1; @(posedge clk); scan_start <= 0;
        wait (do_); @(posedge clk);
        $display("[%s] err=%h valid=%b part=%0d spc=%0d fat=%0d data=%0d maxc=%0d c=%0d/%0d/%0d/%0d s=%0d/%0d/%0d/%0d",
            name, en, vn, pn, sn, fn, dsn, mn, c0n, c1n, c2n, c3n, s0n, s1n, s2n, s3n);
        repeat (10) @(posedge clk);
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        // ---- 场景1：MBR 分区 + 根目录 3 簇 FAT 链 + 干扰目录项 ----
        wr8(0,450,8'h0c); wr32(0,454,100); sig(0);
        boot(100, 512, 1, 4, 2, 2, 1000, 2);           // fat=104 data=108
        wr32(104, 2*4, 5); wr32(104, 5*4, 9); wr32(104, 9*4, 32'h0fffffff);
        deleted_fill(108); deleted_fill(111); deleted_fill(115);
        dirent(108,0,"MYCARD     ",8'h08,0,0);         // 卷标
        dirent(108,1,"PIC5    BMP",8'h20,30,111);      // 编号外
        dirent(108,2,"AIC1    BMP",8'h0f,31,222);      // 长文件名项
        dirent(108,3,"PIC1    BMP",8'h10,32,333);      // 目录
        dirent(108,4,"PIC2    BMP",8'h21,40,921654);   // 只读位不影响
        dirent(111,0,"MUSIC   WAV",8'h20,50,123456);
        dirent(111,7,"PIC1    BMP",8'h20,60,921654);
        dirent(115,3,"PIC4    BMP",8'h20,70,921654);
        dirent(115,9,"PIC3    BMP",8'h20,80,921654);
        wr8(115, 10*32, 8'h00);                       // 簇9中途结束
        run("mbr_chain");
        // ---- 场景2：无分区表 + spc=2，目录在第二扇区结束，只有 2 张 ----
        img.delete();
        boot(0, 512, 2, 8, 1, 4, 5000, 3);             // fat=8 data=12，root 簇3 -> lba14
        deleted_fill(14);
        dirent(14,2,"PIC3    BMP",8'h20,9,1000);
        dirent(15,0,"PIC1    BMP",8'h20,7,2000);
        run("superfloppy");
        // ---- 场景3：签名错误 ----
        img.delete(); wr8(0,450,8'h0c); wr32(0,454,100); run("bad_sig");
        // ---- 场景4：BPB 不支持(1024B/扇区) ----
        img.delete(); boot(0, 1024, 1, 4, 2, 2, 1000, 2); run("bad_bpb");
        // ---- 场景5：找不到资源 ----
        img.delete(); boot(0, 512, 1, 4, 2, 2, 1000, 2);
        wr32(4, 2*4, 32'h0fffffff); dirent(8,0,"README  TXT",8'h20,5,10); run("missing");
        $display("DONE sector_reads=%0d errs=%0d", reads, errs);
        $finish;
    end
endmodule
