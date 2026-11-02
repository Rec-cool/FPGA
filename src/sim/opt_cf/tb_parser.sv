`timescale 1ns/1ps
// 10-29 CF：config_parser 单测。随机生成配置文本，按格式说明（不是照抄 RTL）写的黄金模型逐项比较。
//   每份文本：随机行数；每行随机是 正常键值 / 拼错的键 / 注释 / 空行 / 乱码；键名大小写、空格、制表符随机；
//   值可能是数字（含前导 0、超范围、超过 255）、ON/OFF/Y/N/SEQ/ONE/RND 等单词、混合字符；换行随机 LF/CR/CRLF；
//   最后一行一半概率不带换行。另有固定用例。字节之间随机插入空拍。
//   10-30：加 UTF-8 BOM（文件开头）、中文（>= 0x80 字节）、值后面的行尾注释（# / ; 后面带数字）。
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg bp = 0, bv = 0, ep = 0; reg [7:0] bi = 0;
    wire ap; wire [5:0] mask; wire [4:0] isec; wire [31:0] icyc; wire aon; wire [1:0] bri, mode; wire [2:0] con; wire [3:0] vol;
    config_parser #(.SEC_CYCLES(32'd100_000_000)) u (.clk(clk), .rst_n(rst_n), .begin_pulse(bp), .byte_valid(bv), .byte_in(bi),
        .end_pulse(ep), .apply(ap), .mask(mask), .interval_sec(isec), .interval_cycles(icyc), .auto_on(aon),
        .bri(bri), .con(con), .mode(mode), .vol(vol));

    integer errs = 0, files = 0, lines_n = 0;
    integer hit [6] = '{0, 0, 0, 0, 0, 0};
    task automatic fail(string m); errs++; if (errs < 30) $display("ERR %s", m); endtask

    // ---------------- 黄金模型 ----------------
    typedef struct { bit [5:0] m; int isec, aon, bri, con, mode, vol; } cfg_t;
    function automatic bit is_letter(byte c); return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z"); endfunction
    function automatic byte upc(byte c); return (c >= "a" && c <= "z") ? c - 32 : c; endfunction
    function automatic void golden_line(string ln, ref cfg_t g);
        int i, eq, n; string key, vl; int num; bit hasn; byte c;
        // 去掉行首空格/制表符/>= 0x80 的字节（BOM、中文）后，# 或 ; 开头是注释
        i = 0; while (i < ln.len() && (ln[i] == " " || ln[i] == "\t" || ln[i][7])) i++;
        if (i < ln.len() && (ln[i] == "#" || ln[i] == ";")) return;
        eq = -1; for (int k = 0; k < ln.len(); k++) if (ln[k] == "=") begin eq = k; break; end
        if (eq < 0) return;
        key = ""; for (int k = 0; k < eq; k++) if (is_letter(ln[k]) && key.len() < 3) key = {key, string'(upc(ln[k]))};
        num = 0; hasn = 0; vl = "";
        for (int k = eq + 1; k < ln.len(); k++) begin
            c = ln[k];
            if (c == "#" || c == ";") break;           // 行尾注释
            if (c >= "0" && c <= "9") begin num = num * 10 + (c - "0"); if (num > 255) num = 255; hasn = 1; end
            else if (is_letter(c) && vl.len() < 2) vl = {vl, string'(upc(c))};
        end
        if (key == "INT" && hasn && num >= 1 && num <= 30) begin g.isec = num; g.m[0] = 1; end
        if (key == "AUT") begin
            if (hasn && num <= 1) begin g.aon = num; g.m[1] = 1; end
            else if (!hasn && (vl == "ON" || vl == "OF" || (vl.len() >= 1 && (vl[0] == "Y" || vl[0] == "N")))) begin
                g.aon = (vl == "ON" || vl[0] == "Y"); g.m[1] = 1;
            end
        end
        if (key == "BRI" && hasn && num <= 3) begin g.bri = num; g.m[2] = 1; end
        if (key == "CON" && hasn && num <= 5) begin g.con = num; g.m[3] = 1; end
        if (key == "MOD") begin
            if (hasn && num <= 2) begin g.mode = num; g.m[4] = 1; end
            else if (!hasn && vl.len() >= 1 && (vl[0] == "S" || vl[0] == "O" || vl[0] == "R")) begin
                g.mode = (vl[0] == "S") ? 0 : (vl[0] == "O") ? 1 : 2; g.m[4] = 1;
            end
        end
        if (key == "VOL" && hasn && num <= 10) begin g.vol = num; g.m[5] = 1; end
    endfunction
    function automatic cfg_t golden(string txt);
        cfg_t g; string ln; g.m = 0; g.isec = 0; g.aon = 0; g.bri = 0; g.con = 0; g.mode = 0; g.vol = 0;
        ln = "";
        for (int k = 0; k < txt.len(); k++) begin
            if (txt[k] == 8'h0a || txt[k] == 8'h0d) begin golden_line(ln, g); ln = ""; end
            else ln = {ln, string'(txt[k])};
        end
        golden_line(ln, g);
        return g;
    endfunction

    // ---------------- 激励 ----------------
    task automatic feed(string txt);
        cfg_t g; int t;
        g = golden(txt);
        @(posedge clk) bp <= 1; @(posedge clk) bp <= 0;
        for (int k = 0; k < txt.len(); k++) begin
            repeat ($urandom % 3) @(posedge clk);
            bv <= 1; bi <= txt[k]; @(posedge clk); bv <= 0;
        end
        repeat ($urandom % 3) @(posedge clk);
        ep <= 1; @(posedge clk); ep <= 0;
        t = 0; while (!ap && t < 100) begin @(posedge clk); t++; end
        if (!ap) begin fail("no apply"); return; end
        #1;
        files++;
        for (int b = 0; b < 6; b++) if (g.m[b]) hit[b]++;
        if (mask !== g.m) fail($sformatf("file %0d mask %b exp %b\n%s", files, mask, g.m, txt));
        else begin
            if (g.m[0] && (isec !== g.isec || icyc !== g.isec * 100_000_000)) fail($sformatf("file %0d INT %0d/%0d exp %0d", files, isec, icyc, g.isec));
            if (g.m[1] && aon !== g.aon[0]) fail($sformatf("file %0d AUTO %0d exp %0d\n%s", files, aon, g.aon, txt));
            if (g.m[2] && bri !== g.bri) fail($sformatf("file %0d BRI %0d exp %0d", files, bri, g.bri));
            if (g.m[3] && con !== g.con) fail($sformatf("file %0d CON %0d exp %0d", files, con, g.con));
            if (g.m[4] && mode !== g.mode) fail($sformatf("file %0d MODE %0d exp %0d\n%s", files, mode, g.mode, txt));
            if (g.m[5] && vol !== g.vol) fail($sformatf("file %0d VOL %0d exp %0d", files, vol, g.vol));
        end
        @(posedge clk);
        if (ap) fail("apply longer than 1 cycle");
    endtask

    function automatic string rcase(string s);
        string r = s;
        for (int k = 0; k < r.len(); k++) if (is_letter(r[k]) && $urandom % 2) r[k] = r[k] ^ 8'h20;
        return r;
    endfunction
    function automatic string rsp(); int n = $urandom % 4; string s = ""; repeat (n) s = {s, ($urandom % 3 == 0) ? "\t" : " "}; return s; endfunction
    function automatic string rval();
        string words [] = '{"ON", "OFF", "on", "Off", "YES", "NO", "y", "n", "SEQ", "ONE", "RND", "seq", "Rnd", "one",
                            "OK", "X", "S", "R", "O", "ONX", "OFFLINE", "random"};
        case ($urandom % 6)
            0: return $sformatf("%0d", $urandom % 4);
            1: return $sformatf("%0d", $urandom % 12);
            2: return $sformatf("%0d", $urandom % 40);
            3: return $sformatf("%0d", $urandom % 100000);
            4: return words[$urandom % words.size()];
            default: return $sformatf("%0d%s", $urandom % 9, ($urandom % 2) ? "S" : ".5");
        endcase
    endfunction
    function automatic string rline();
        string keys [] = '{"INTERVAL", "AUTO", "BRIGHT", "CONTRAST", "MODE", "VOLUME", "INT", "AUT", "BRI", "CON", "MOD", "VOL",
                           "IN", "AU", "VOLUMEX", "BRIGHTNESS", "CONTRASTS", "MODES", "I N T", "1INT", "IN_TERVAL", "XYZ", ""};
        case ($urandom % 10)
            0: return {rsp(), ($urandom % 2) ? "#" : ";", " INTERVAL=5 ", rval()};
            1: return rsp();
            2: begin string s = ""; repeat ($urandom % 12) s = {s, string'(byte'(32 + $urandom % 95))}; return s; end
            3: return {rsp(), rzh(), ($urandom % 2) ? "#" : ";", rzh(), " BRIGHT=1 ", rzh()};   // 中文后面的注释
            default: return {rsp(), rzh(), rcase(keys[$urandom % keys.size()]), rsp(), "=", rsp(), rcase(rval()), rsp(),
                             ($urandom % 4 == 0) ? {($urandom % 2) ? " # " : ";", rval(), " 1/0 ", rzh()} : ""};
        endcase
    endfunction
    // 随机 0~2 个汉字（UTF-8 三字节，>= 0x80）
    function automatic string rzh();
        string s = "";
        repeat (($urandom % 3 == 0) ? 1 + $urandom % 2 : 0)
            s = {s, string'(byte'(8'he4 + $urandom % 6)), string'(byte'(8'h80 + $urandom % 64)), string'(byte'(8'h80 + $urandom % 64))};
        return s;
    endfunction
    function automatic string reol(); case ($urandom % 3) 0: return "\n"; 1: return "\r"; default: return "\r\n"; endcase endfunction

    initial begin
        string t;
        repeat (5) @(posedge clk); rst_n <= 1; repeat (5) @(posedge clk);
        // 固定用例
        feed("INTERVAL=5\r\nAUTO=ON\r\nBRIGHT=2\r\nCONTRAST=4\r\nMODE=RND\r\nVOLUME=7\r\n");
        feed("# my shop\ninterval = 12\nauto=off\nbright=3\ncontrast=0\nmode=one\nvolume=10");   // 最后一行没有换行
        feed("INTERVAL=0\nINTERVAL=31\nAUTO=2\nBRIGHT=4\nCONTRAST=6\nMODE=3\nVOLUME=11\n");     // 全部超范围
        feed("VOLUME=3\nVOLUME=8\n");                                                           // 后面的覆盖前面的
        feed("");                                                                               // 空文件
        feed("   ; comment\n\n\r\nMODE=seq\rAUTO=1\r");
        feed("INTERVAL=030\nBRIGHT=0\n");                                                       // 前导 0
        feed("INTERVAL=99999999\n");                                                            // 钳位到 255，超范围
        feed({"\357\273\277", "# INTERVAL=5\nBRIGHT=1\n"});                                     // BOM + 注释行：INTERVAL 不生效
        feed("AUTO=OFF   # 1/0\nVOLUME=4;10\nMODE = RND # SEQ\nCONTRAST=3#\n");                  // 行尾注释
        feed({"INTERVAL=8 \347\247\222\n", "\350\275\256#VOLUME=1\n"});                          // 中文说明、中文后面的注释
        // 随机
        for (int f = 0; f < 4000; f++) begin
            automatic int n = $urandom % 9;
            t = ($urandom % 4 == 0) ? "\357\273\277" : "";
            for (int l = 0; l < n; l++) begin t = {t, rline()}; if (l != n - 1 || $urandom % 2) t = {t, reol()}; lines_n++; end
            feed(t);
        end
        $display("valid-item hits INT=%0d AUTO=%0d BRI=%0d CON=%0d MODE=%0d VOL=%0d", hit[0], hit[1], hit[2], hit[3], hit[4], hit[5]);
        $display("DONE tb_parser files=%0d random_lines=%0d errs=%0d", files, lines_n, errs);
        $finish;
    end
endmodule
