`timescale 1ns/1ps

// 11-01 SV：保存参数。KEY4+KEY2 同时按住 1 s，把当前 6 项参数写回 TF 卡根目录的 CONFIG.TXT（sd_card_clk 域）。
// 流程（全程 hold=1，挡住音频的扇区请求；音频缓冲约 85 ms，正常一次保存只占卡几毫秒）：
//   1. 读 CONFIG.TXT 目录项所在扇区存进 BRAM，核对文件名和簇号（开机后换过卡就不写），顺便看文件大小是不是 512
//   2. 重写文件第 1 扇区（模板文本 + 当前值，后面补空格到 512 字节），再读回逐字节核对
//   3. 文件大小不是 512 时，把目录项里的大小改成 512 写回目录扇区，再读回核对（第二次保存起就不用了）
// 卡上没有 CONFIG.TXT 不新建（不动 FAT 表），result = 1。任何一步核对不上 result = 2。
// 总超时 TIMEOUT_CYC：判失败，并发 drv_rst 让上层复位 SD 驱动（写卡途中拔卡时驱动会一直等卡应答）。
// 文件内容（CRLF；# 开头的行不生效，没在 CONFIG.TXT 里设过的间隔、音量写成注释，保持原来的默认值）：
//   #CONFIG.TXT  (KEY4+KEY2 hold 1s = save)
//   #INTERVAL 1~30 s, AUTO ON/OFF, BRIGHT 0~3
//   #CONTRAST 0~5 (2=1.0x), MODE SEQ/ONE/RND
//   #VOLUME 0~10. Lines starting with # are off
//   ?INTERVAL=??
//   AUTO=???
//   BRIGHT=?
//   CONTRAST=?
//   MODE=???
//   ?VOLUME=??
//   （共 239 字节，后面补空格到 512 字节）
module cfg_saver #(
    parameter integer TIMEOUT_CYC = 200_000_000     // 2 s
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        save_req,         // 单拍
    input  wire        bus_ready,        // 图片已加载完（总线归音频）且 SD 已初始化
    input  wire [18:0] val,              // {间隔已设, 间隔秒[4:0], 自动, 亮度[1:0], 对比度[2:0], 模式[1:0], 音量已设, 音量[3:0]}
    // 扫描器记下的 CONFIG.TXT 位置
    input  wire        cfg_found,
    input  wire [31:0] cfg_cluster,
    input  wire [31:0] cfg_data_lba,     // 文件第 1 扇区
    input  wire [31:0] cfg_dir_lba,      // 目录项所在扇区
    input  wire [3:0]  cfg_dir_ent,      // 目录项在扇区里的序号（0~15）
    // 读扇区（经 sd_card_bmp 的仲裁器，rd_own=1 时归本模块）
    output reg         hold,             // 1 = 挡住音频的新请求
    output reg         rd_own,
    output reg         rd_req,
    output reg  [31:0] rd_lba,
    input  wire        rd_busy,
    input  wire        rd_valid,
    input  wire [7:0]  rd_byte,
    input  wire [8:0]  rd_idx,
    input  wire        rd_done,
    // 写扇区（直接接 sd_card_top 的 sd_sec_write_*）
    output reg         wr_req,           // 电平，到 wr_end 撤销
    output reg  [31:0] wr_lba,
    output reg  [7:0]  wr_data,          // wr_data_req 的下一拍有效，保持到下一个 wr_data_req
    input  wire        wr_data_req,
    input  wire        wr_end,
    output reg         drv_rst,          // 单拍：超时，请求复位 SD 驱动
    output wire        busy,
    output reg         done,             // 单拍
    output reg  [1:0]  result            // 0 = 成功，1 = 卡上没有 CONFIG.TXT，2 = 失败
);
    localparam [2:0] ST_IDLE = 3'd0, ST_DRAIN = 3'd1, ST_RREQ = 3'd2, ST_RWAIT = 3'd3,
                     ST_RCHK = 3'd4, ST_WR = 3'd5, ST_FIN = 3'd6;
    // step：0 读目录扇区核对，1 写文件，2 读回文件核对，3 写目录扇区，4 读回目录扇区核对
    reg [2:0]  st;
    reg [2:0]  step;
    reg [1:0]  wcnt;                     // ST_DRAIN / ST_RCHK 等几拍（挡住请求生效、读数比对流水线排空）
    reg [27:0] tmo;
    reg [18:0] sv;                       // 按下保存时的快照
    reg [8:0]  widx;                     // 写：下一个要送的字节；读回：正在比对的字节
    reg        p1, p2;                   // 读回比对流水线
    reg [7:0]  vbyte;
    reg        ent_ok, sz512, mism;
    reg [7:0]  g_q, d_q;                 // 模板字节、BRAM 读出（都比 widx 晚 1 拍）
    reg [7:0]  dbuf [0:511];             // 目录扇区

    assign busy = (st != ST_IDLE);

    // ---------- 文件内容：模板 + 当前值 ----------
    wire       int_set = sv[18];
    wire [4:0] int_sec = sv[17:13];
    wire       auto_on = sv[12];
    wire [1:0] bri     = sv[11:10];
    wire [2:0] con     = sv[9:7];
    wire [1:0] mode    = sv[6:5];
    wire       vol_set = sv[4];
    wire [3:0] vol     = sv[3:0];
    wire [1:0] int_t   = (int_sec >= 5'd30) ? 2'd3 : (int_sec >= 5'd20) ? 2'd2 : (int_sec >= 5'd10) ? 2'd1 : 2'd0;
    wire [3:0] int_o   = int_sec - {int_t, 3'd0} - {1'b0, int_t, 1'b0};      // 个位 = 秒 - 十位×10
    wire [3:0] vol_o   = (vol >= 4'd10) ? (vol - 4'd10) : vol;

    function [7:0] tpl;
        input [8:0] i;
        begin
            case (i)
                9'd0: tpl = 8'h23;
                9'd1: tpl = 8'h43;
                9'd2: tpl = 8'h4f;
                9'd3: tpl = 8'h4e;
                9'd4: tpl = 8'h46;
                9'd5: tpl = 8'h49;
                9'd6: tpl = 8'h47;
                9'd7: tpl = 8'h2e;
                9'd8: tpl = 8'h54;
                9'd9: tpl = 8'h58;
                9'd10: tpl = 8'h54;
                9'd11: tpl = 8'h20;
                9'd12: tpl = 8'h20;
                9'd13: tpl = 8'h28;
                9'd14: tpl = 8'h4b;
                9'd15: tpl = 8'h45;
                9'd16: tpl = 8'h59;
                9'd17: tpl = 8'h34;
                9'd18: tpl = 8'h2b;
                9'd19: tpl = 8'h4b;
                9'd20: tpl = 8'h45;
                9'd21: tpl = 8'h59;
                9'd22: tpl = 8'h32;
                9'd23: tpl = 8'h20;
                9'd24: tpl = 8'h68;
                9'd25: tpl = 8'h6f;
                9'd26: tpl = 8'h6c;
                9'd27: tpl = 8'h64;
                9'd28: tpl = 8'h20;
                9'd29: tpl = 8'h31;
                9'd30: tpl = 8'h73;
                9'd31: tpl = 8'h20;
                9'd32: tpl = 8'h3d;
                9'd33: tpl = 8'h20;
                9'd34: tpl = 8'h73;
                9'd35: tpl = 8'h61;
                9'd36: tpl = 8'h76;
                9'd37: tpl = 8'h65;
                9'd38: tpl = 8'h29;
                9'd39: tpl = 8'h0d;
                9'd40: tpl = 8'h0a;
                9'd41: tpl = 8'h23;
                9'd42: tpl = 8'h49;
                9'd43: tpl = 8'h4e;
                9'd44: tpl = 8'h54;
                9'd45: tpl = 8'h45;
                9'd46: tpl = 8'h52;
                9'd47: tpl = 8'h56;
                9'd48: tpl = 8'h41;
                9'd49: tpl = 8'h4c;
                9'd50: tpl = 8'h20;
                9'd51: tpl = 8'h31;
                9'd52: tpl = 8'h7e;
                9'd53: tpl = 8'h33;
                9'd54: tpl = 8'h30;
                9'd55: tpl = 8'h20;
                9'd56: tpl = 8'h73;
                9'd57: tpl = 8'h2c;
                9'd58: tpl = 8'h20;
                9'd59: tpl = 8'h41;
                9'd60: tpl = 8'h55;
                9'd61: tpl = 8'h54;
                9'd62: tpl = 8'h4f;
                9'd63: tpl = 8'h20;
                9'd64: tpl = 8'h4f;
                9'd65: tpl = 8'h4e;
                9'd66: tpl = 8'h2f;
                9'd67: tpl = 8'h4f;
                9'd68: tpl = 8'h46;
                9'd69: tpl = 8'h46;
                9'd70: tpl = 8'h2c;
                9'd71: tpl = 8'h20;
                9'd72: tpl = 8'h42;
                9'd73: tpl = 8'h52;
                9'd74: tpl = 8'h49;
                9'd75: tpl = 8'h47;
                9'd76: tpl = 8'h48;
                9'd77: tpl = 8'h54;
                9'd78: tpl = 8'h20;
                9'd79: tpl = 8'h30;
                9'd80: tpl = 8'h7e;
                9'd81: tpl = 8'h33;
                9'd82: tpl = 8'h0d;
                9'd83: tpl = 8'h0a;
                9'd84: tpl = 8'h23;
                9'd85: tpl = 8'h43;
                9'd86: tpl = 8'h4f;
                9'd87: tpl = 8'h4e;
                9'd88: tpl = 8'h54;
                9'd89: tpl = 8'h52;
                9'd90: tpl = 8'h41;
                9'd91: tpl = 8'h53;
                9'd92: tpl = 8'h54;
                9'd93: tpl = 8'h20;
                9'd94: tpl = 8'h30;
                9'd95: tpl = 8'h7e;
                9'd96: tpl = 8'h35;
                9'd97: tpl = 8'h20;
                9'd98: tpl = 8'h28;
                9'd99: tpl = 8'h32;
                9'd100: tpl = 8'h3d;
                9'd101: tpl = 8'h31;
                9'd102: tpl = 8'h2e;
                9'd103: tpl = 8'h30;
                9'd104: tpl = 8'h78;
                9'd105: tpl = 8'h29;
                9'd106: tpl = 8'h2c;
                9'd107: tpl = 8'h20;
                9'd108: tpl = 8'h4d;
                9'd109: tpl = 8'h4f;
                9'd110: tpl = 8'h44;
                9'd111: tpl = 8'h45;
                9'd112: tpl = 8'h20;
                9'd113: tpl = 8'h53;
                9'd114: tpl = 8'h45;
                9'd115: tpl = 8'h51;
                9'd116: tpl = 8'h2f;
                9'd117: tpl = 8'h4f;
                9'd118: tpl = 8'h4e;
                9'd119: tpl = 8'h45;
                9'd120: tpl = 8'h2f;
                9'd121: tpl = 8'h52;
                9'd122: tpl = 8'h4e;
                9'd123: tpl = 8'h44;
                9'd124: tpl = 8'h0d;
                9'd125: tpl = 8'h0a;
                9'd126: tpl = 8'h23;
                9'd127: tpl = 8'h56;
                9'd128: tpl = 8'h4f;
                9'd129: tpl = 8'h4c;
                9'd130: tpl = 8'h55;
                9'd131: tpl = 8'h4d;
                9'd132: tpl = 8'h45;
                9'd133: tpl = 8'h20;
                9'd134: tpl = 8'h30;
                9'd135: tpl = 8'h7e;
                9'd136: tpl = 8'h31;
                9'd137: tpl = 8'h30;
                9'd138: tpl = 8'h2e;
                9'd139: tpl = 8'h20;
                9'd140: tpl = 8'h4c;
                9'd141: tpl = 8'h69;
                9'd142: tpl = 8'h6e;
                9'd143: tpl = 8'h65;
                9'd144: tpl = 8'h73;
                9'd145: tpl = 8'h20;
                9'd146: tpl = 8'h73;
                9'd147: tpl = 8'h74;
                9'd148: tpl = 8'h61;
                9'd149: tpl = 8'h72;
                9'd150: tpl = 8'h74;
                9'd151: tpl = 8'h69;
                9'd152: tpl = 8'h6e;
                9'd153: tpl = 8'h67;
                9'd154: tpl = 8'h20;
                9'd155: tpl = 8'h77;
                9'd156: tpl = 8'h69;
                9'd157: tpl = 8'h74;
                9'd158: tpl = 8'h68;
                9'd159: tpl = 8'h20;
                9'd160: tpl = 8'h23;
                9'd161: tpl = 8'h20;
                9'd162: tpl = 8'h61;
                9'd163: tpl = 8'h72;
                9'd164: tpl = 8'h65;
                9'd165: tpl = 8'h20;
                9'd166: tpl = 8'h6f;
                9'd167: tpl = 8'h66;
                9'd168: tpl = 8'h66;
                9'd169: tpl = 8'h0d;
                9'd170: tpl = 8'h0a;
                9'd172: tpl = 8'h49;
                9'd173: tpl = 8'h4e;
                9'd174: tpl = 8'h54;
                9'd175: tpl = 8'h45;
                9'd176: tpl = 8'h52;
                9'd177: tpl = 8'h56;
                9'd178: tpl = 8'h41;
                9'd179: tpl = 8'h4c;
                9'd180: tpl = 8'h3d;
                9'd183: tpl = 8'h0d;
                9'd184: tpl = 8'h0a;
                9'd185: tpl = 8'h41;
                9'd186: tpl = 8'h55;
                9'd187: tpl = 8'h54;
                9'd188: tpl = 8'h4f;
                9'd189: tpl = 8'h3d;
                9'd193: tpl = 8'h0d;
                9'd194: tpl = 8'h0a;
                9'd195: tpl = 8'h42;
                9'd196: tpl = 8'h52;
                9'd197: tpl = 8'h49;
                9'd198: tpl = 8'h47;
                9'd199: tpl = 8'h48;
                9'd200: tpl = 8'h54;
                9'd201: tpl = 8'h3d;
                9'd203: tpl = 8'h0d;
                9'd204: tpl = 8'h0a;
                9'd205: tpl = 8'h43;
                9'd206: tpl = 8'h4f;
                9'd207: tpl = 8'h4e;
                9'd208: tpl = 8'h54;
                9'd209: tpl = 8'h52;
                9'd210: tpl = 8'h41;
                9'd211: tpl = 8'h53;
                9'd212: tpl = 8'h54;
                9'd213: tpl = 8'h3d;
                9'd215: tpl = 8'h0d;
                9'd216: tpl = 8'h0a;
                9'd217: tpl = 8'h4d;
                9'd218: tpl = 8'h4f;
                9'd219: tpl = 8'h44;
                9'd220: tpl = 8'h45;
                9'd221: tpl = 8'h3d;
                9'd225: tpl = 8'h0d;
                9'd226: tpl = 8'h0a;
                9'd228: tpl = 8'h56;
                9'd229: tpl = 8'h4f;
                9'd230: tpl = 8'h4c;
                9'd231: tpl = 8'h55;
                9'd232: tpl = 8'h4d;
                9'd233: tpl = 8'h45;
                9'd234: tpl = 8'h3d;
                9'd237: tpl = 8'h0d;
                9'd238: tpl = 8'h0a;
                default: tpl = " ";
            endcase
        end
    endfunction

    reg [7:0] gen;
    always @(*) begin
        case (widx)
            9'd171: gen = int_set ? " " : "#";
            9'd181: gen = (int_t == 2'd0) ? " " : {6'h0c, int_t};
            9'd182: gen = {4'h3, int_o};
            9'd190: gen = "O";
            9'd191: gen = auto_on ? "N" : "F";
            9'd192: gen = auto_on ? " " : "F";
            9'd202: gen = {6'h0c, bri};
            9'd214: gen = {5'h06, con};
            9'd222: gen = (mode == 2'd0) ? "S" : (mode == 2'd1) ? "O" : "R";
            9'd223: gen = (mode == 2'd0) ? "E" : "N";
            9'd224: gen = (mode == 2'd0) ? "Q" : (mode == 2'd1) ? "E" : "D";
            9'd227: gen = vol_set ? " " : "#";
            9'd235: gen = (vol >= 4'd10) ? "1" : " ";
            9'd236: gen = {4'h3, vol_o};
            default: gen = tpl(widx);
        endcase
    end

    // 目录扇区：文件大小（第 28~31 字节）改成 512 = 00 02 00 00
    wire       in_ent = (widx[8:5] == cfg_dir_ent);
    wire [7:0] dpatch = (in_ent && widx[4:2] == 3'b111) ? ((widx[1:0] == 2'd1) ? 8'h02 : 8'h00) : d_q;
    wire [7:0] src    = (step >= 3'd3) ? dpatch : g_q;

    // 目录项核对：8.3 文件名 "CONFIG  TXT"
    function [7:0] cfg_name;
        input [3:0] k;
        begin
            case (k)
                4'd0: cfg_name = "C"; 4'd1: cfg_name = "O"; 4'd2: cfg_name = "N"; 4'd3: cfg_name = "F";
                4'd4: cfg_name = "I"; 4'd5: cfg_name = "G"; 4'd8: cfg_name = "T"; 4'd9: cfg_name = "X";
                4'd10: cfg_name = "T";
                default: cfg_name = " ";
            endcase
        end
    endfunction
    wire rd_in_ent = (rd_idx[8:5] == cfg_dir_ent);

    // BRAM：单独的无复位块，读口每拍无条件寄存
    always @(posedge clk) begin
        if (st == ST_RWAIT && step == 3'd0 && rd_valid)
            dbuf[rd_idx] <= rd_byte;
        d_q <= dbuf[widx];
    end
    always @(posedge clk) g_q <= gen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; step <= 3'd0; wcnt <= 2'd0; tmo <= 28'd0; sv <= 19'd0;
            widx <= 9'd0; p1 <= 1'b0; p2 <= 1'b0; vbyte <= 8'd0;
            ent_ok <= 1'b0; sz512 <= 1'b0; mism <= 1'b0;
            hold <= 1'b0; rd_own <= 1'b0; rd_req <= 1'b0; rd_lba <= 32'd0;
            wr_req <= 1'b0; wr_lba <= 32'd0; wr_data <= 8'd0;
            drv_rst <= 1'b0; done <= 1'b0; result <= 2'd0;
        end else begin
            rd_req  <= 1'b0;
            drv_rst <= 1'b0;
            done    <= 1'b0;
            tmo     <= (st == ST_IDLE) ? 28'd0 : tmo + 28'd1;

            // 读：目录扇区边读边核对；读回时延迟 2 拍和应写内容比对（widx 换地址 → g_q/d_q 出数）
            p1 <= (st == ST_RWAIT) && rd_valid;
            p2 <= p1;
            if (st == ST_RWAIT && rd_valid) begin
                widx  <= rd_idx;
                vbyte <= rd_byte;
                if (step == 3'd0 && rd_in_ent) begin
                    case (rd_idx[4:0])
                        5'd20: if (rd_byte != cfg_cluster[23:16]) ent_ok <= 1'b0;
                        5'd21: if (rd_byte != cfg_cluster[31:24]) ent_ok <= 1'b0;
                        5'd26: if (rd_byte != cfg_cluster[7:0])   ent_ok <= 1'b0;
                        5'd27: if (rd_byte != cfg_cluster[15:8])  ent_ok <= 1'b0;
                        5'd28, 5'd30, 5'd31: if (rd_byte != 8'h00) sz512 <= 1'b0;
                        5'd29: if (rd_byte != 8'h02) sz512 <= 1'b0;
                        default: if (rd_idx[4:0] < 5'd11 && rd_byte != cfg_name(rd_idx[3:0])) ent_ok <= 1'b0;
                    endcase
                end
            end
            if (p2 && step != 3'd0 && vbyte != src)
                mism <= 1'b1;

            if (st != ST_IDLE && st != ST_FIN && tmo >= TIMEOUT_CYC - 1) begin
                wr_req  <= 1'b0;
                drv_rst <= 1'b1;
                result  <= 2'd2;
                st      <= ST_FIN;
            end else case (st)
                ST_IDLE: if (save_req) begin
                    if (!bus_ready) begin
                        result <= 2'd2; done <= 1'b1;
                    end else if (!cfg_found) begin
                        result <= 2'd1; done <= 1'b1;
                    end else begin
                        sv   <= val;
                        hold <= 1'b1;
                        step <= 3'd0;
                        wcnt <= 2'd0;
                        st   <= ST_DRAIN;
                    end
                end
                ST_DRAIN: begin                  // hold 生效后等适配层把音频正在读的扇区读完
                    if (wcnt != 2'd3)
                        wcnt <= wcnt + 2'd1;
                    else if (!rd_busy) begin
                        rd_own <= 1'b1;
                        rd_lba <= cfg_dir_lba;
                        ent_ok <= 1'b1;
                        sz512  <= 1'b1;
                        st     <= ST_RREQ;
                    end
                end
                ST_RREQ: if (!rd_busy) begin
                    rd_req <= 1'b1;
                    mism   <= 1'b0;
                    st     <= ST_RWAIT;
                end
                ST_RWAIT: if (rd_done) begin
                    wcnt <= 2'd0;
                    st   <= ST_RCHK;
                end
                ST_RCHK: begin
                    if (wcnt != 2'd3)
                        wcnt <= wcnt + 2'd1;
                    else begin
                        widx <= 9'd0;
                        if (step == 3'd0) begin
                            if (!ent_ok) begin
                                result <= 2'd2; st <= ST_FIN;
                            end else begin
                                step <= 3'd1; wr_lba <= cfg_data_lba; st <= ST_WR;
                            end
                        end else if (mism) begin
                            result <= 2'd2; st <= ST_FIN;
                        end else if (step == 3'd2 && !sz512) begin
                            step <= 3'd3; wr_lba <= cfg_dir_lba; st <= ST_WR;
                        end else begin
                            result <= 2'd0; st <= ST_FIN;
                        end
                    end
                end
                ST_WR: begin
                    wr_req <= 1'b1;
                    if (wr_data_req) begin
                        wr_data <= src;
                        widx    <= widx + 9'd1;
                    end
                    if (wr_end) begin
                        wr_req <= 1'b0;
                        step   <= step + 3'd1;
                        rd_lba <= wr_lba;
                        st     <= ST_RREQ;
                    end
                end
                ST_FIN: begin
                    hold   <= 1'b0;
                    rd_own <= 1'b0;
                    done   <= 1'b1;
                    st     <= ST_IDLE;
                end
                default: st <= ST_IDLE;
            endcase
        end
    end
endmodule
