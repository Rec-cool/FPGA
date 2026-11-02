`timescale 1ns/1ps

// R3'-A: stream real audio content from the TF card and feed it into the
// existing HDMI audio chain (docs/29 rev: "what actually wins"). This module
// sits between the SD sector-read infrastructure and the PCM sample
// interface, using a dual-port BRAM circular buffer to absorb the ~12.5x
// rate mismatch between TF reads (~1.2 MB/s burst) and audio consumption
// (96 KB/s at 48 kHz 16-bit mono).
//
// Architecture:
//   TF sector bytes (mem_clk domain, byte-serial)
//     -> pair into 16-bit samples -> write into BRAM circular buffer
//   Audio sample ticks (pixel_clk domain, ~48 kHz)
//     -> read from BRAM -> output on valid/ready PCM interface
//
// The write side uses a sector-level state machine: issue one sector read,
// fill 256 samples (512 bytes), then issue the next. The read side consumes
// at the audio sample rate. Pointer crossing uses gray-coded 2FF sync (the
// established idiom). Buffer underflow outputs silence (zeros) with
// sample_valid still asserted, so the downstream HDMI chain never stalls.
//
// Data format: raw 16-bit signed little-endian PCM, 48 kHz mono. The PC
// tool (tools/make_audio_corpus.py) converts any WAV to this format before
// writing to the TF card. Endianness: TF bytes arrive LSB first.
module wav_stream_player #(
    parameter integer ADDR_WIDTH = 12,         // 4096 x 16-bit = 8 KB
    parameter integer SAMPLES_PER_SECTOR = 256 // 512 bytes / 2
) (
    // write side: mem_clk domain (SD SPI engine clock)
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        play_enable,        // level: stream active
    input  wire        restart,
    input  wire [31:0] start_lba,          // first data sector (after WAV header)
    input  wire [31:0] total_sectors,      // audio data extent in sectors
    output wire        sd_req,             // request a sector read
    output wire  [31:0] sd_lba,
    input  wire        sd_busy,
    input  wire        sd_valid,           // one byte per valid pulse
    input  wire [7:0]  sd_byte,
    input  wire [8:0]  sd_byte_index,      // 0..511 within sector
    input  wire        sd_done,
    input  wire [7:0]  sd_error,

    // read side: pixel_clk domain (audio chain clock)
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,        // ~48 kHz pulse: consume one sample
    output reg  signed [15:0] sample_out,
    output reg         sample_valid,
    input  wire        sample_ready,       // from downstream (always 1 in our chain)
    input  wire [7:0]  gain,               //rd_clk域：0=静音 255=原音量
    // status (read side)
    output reg  [31:0] sample_counter,     // samples consumed (for OSD)
    output wire        stream_active,      // play_enable && not ended
    output wire        stream_end,         // all data consumed
    output wire        buffer_low          // < 25% remaining (for OSD/status)
);
    // ---------------- circular buffer ----------------
    reg [15:0] buffer [0:(1<<ADDR_WIDTH)-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;    // write pointer (wr_clk domain)
    reg [ADDR_WIDTH-1:0] rd_ptr;    // read pointer (rd_clk domain)

    // write state sync to read domain (quasi-static, 2FF is safe)
    //reg [2:0] wstate_sync1, wstate_sync2;

    // gray-coded sync: wr_ptr -> rd_clk domain
    reg [ADDR_WIDTH-1:0] wr_gray;
    reg [ADDR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;
    // gray-coded sync: rd_ptr -> wr_clk domain
    reg [ADDR_WIDTH-1:0] rd_gray;
    reg [ADDR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;

    function [ADDR_WIDTH-1:0] to_gray;
        input [ADDR_WIDTH-1:0] b;
        begin
            to_gray = b ^ (b >> 1);
        end
    endfunction

    function [ADDR_WIDTH-1:0] from_gray;
        input [ADDR_WIDTH-1:0] g;
        reg [ADDR_WIDTH-1:0] b;
        integer i;
        begin
            b[ADDR_WIDTH-1] = g[ADDR_WIDTH-1];
            for (i = ADDR_WIDTH-2; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            from_gray = b;
        end
    endfunction

    // synchronized pointers (each in the other domain)
    wire [ADDR_WIDTH-1:0] wr_ptr_in_rd = from_gray(wr_gray_sync2);
    wire [ADDR_WIDTH-1:0] rd_ptr_in_wr = from_gray(rd_gray_sync2);

    // fill level in write domain (for flow control)
    // 水位按 2^ADDR_WIDTH 取模：写指针绕回(wr<rd)时差值仍正确。space_ok 保证水位
    // 不超过 DEPTH-512，所以"满"和"空"不会混淆。
    wire [ADDR_WIDTH-1:0] level_wr = wr_ptr - rd_ptr_in_wr;
    wire space_ok = (level_wr <= (1 << ADDR_WIDTH) - 2*SAMPLES_PER_SECTOR);

    // fill level in read domain (for buffer_low status)
    wire [ADDR_WIDTH-1:0] level_rd = wr_ptr_in_rd - rd_ptr;

    // ---------------- write side state machine ----------------
    localparam [2:0] WS_IDLE  = 3'd0;
    localparam [2:0] WS_REQ   = 3'd1;
    localparam [2:0] WS_FILL  = 3'd2;
    localparam [2:0] WS_DONE  = 3'd3;
    localparam [2:0] WS_END   = 3'd4;
    reg [2:0]  wstate;
    wire wstate_ended = (wstate == WS_END);
    reg [31:0] cur_lba;
    // 新增：播放中断
    reg abort_pending;//下停止歌曲指令，并且等待sd_done完成
    reg flush_toggle;//写侧产生，跨到读侧	通知读侧扔掉旧数据
    reg wr_end_q;
    reg [31:0] sectors_read;
    reg [7:0]  lo_byte;             // little-endian pair assembly
    reg        lo_pending;

    assign sd_req = (wstate == WS_REQ) && (space_ok) && (!abort_pending);
    assign sd_lba = cur_lba;
    //assign stream_active = play_enable && (wstate != WS_END);
    //assign stream_end = (wstate == WS_END);
    assign buffer_low = (level_rd < (1 << (ADDR_WIDTH-2))); // < 25%
    
    // BRAM 写口：单独的无复位 always 块，TD 才能推断为 BRAM（否则落到 LUT DRAM）
    wire buf_we = (wstate == WS_FILL) && sd_valid && lo_pending;
    always @(posedge wr_clk) begin
        if (buf_we)
            buffer[wr_ptr] <= {sd_byte, lo_byte};
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wstate         <= WS_IDLE;
            cur_lba        <= 32'd0;
            sectors_read   <= 32'd0;
            wr_ptr         <= {ADDR_WIDTH{1'b0}};
            lo_pending     <= 1'b0;
            lo_byte        <= 8'd0;
            rd_gray_sync1  <= {ADDR_WIDTH{1'b0}};
            rd_gray_sync2  <= {ADDR_WIDTH{1'b0}};
            wr_gray        <= {ADDR_WIDTH{1'b0}};
            abort_pending  <= 1'b0;
            flush_toggle   <= 1'b0;
            wr_end_q <= 1'b0;
        end else begin
            // 本域指针先转格雷码寄存（源域），对端只同步格雷码
            wr_gray      <= to_gray(wr_ptr);
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
            wr_end_q <= (wstate == WS_END);
            if(wstate != WS_IDLE && (restart || !play_enable))
                abort_pending <= 1'b1;
            case (wstate)
            WS_IDLE: begin
                if (play_enable && start_lba != 32'd0 && total_sectors != 32'd0) begin
                    cur_lba      <= start_lba;
                    sectors_read <= 32'd0;
                    //wr_ptr       <= {ADDR_WIDTH{1'b0}};
                    lo_pending   <= 1'b0;
                    flush_toggle <= ~flush_toggle;//通知读侧：旧数据作废
                    wstate       <= WS_REQ;
                    abort_pending <= 1'b0;
                end
            end
            WS_REQ: begin
                if(abort_pending) begin
                    wstate <= WS_IDLE;
                end
                else if (!sd_busy && space_ok) begin
                    //sd_lba  <= cur_lba;
                    wstate  <= WS_FILL;
                end
            end
            WS_FILL: begin
                if (sd_valid) begin
                    if (!lo_pending) begin
                        lo_byte    <= sd_byte;
                        lo_pending <= 1'b1;
                    end else begin
                        wr_ptr         <= wr_ptr + 1'b1;
                        lo_pending     <= 1'b0;
                    end
                end
                if (sd_done) begin
                    if(abort_pending) begin
                        wstate <= WS_IDLE;
                    end
                    else if (sd_error != 8'd0) begin
                        wstate <= WS_END;  // sector error: stop streaming
                    end else begin
                        sectors_read <= sectors_read + 1'b1;
                        cur_lba      <= cur_lba + 1'b1;
                        if (sectors_read + 1'b1 >= total_sectors)
                            wstate <= WS_END;
                        else
                            wstate <= WS_REQ;
                    end
                end
            end
            WS_DONE: wstate <= WS_REQ;  // unused, reserved
            WS_END: begin
                // stay ended until play_enable drops
                if (abort_pending)
                    wstate <= WS_IDLE;
            end
            default: wstate <= WS_IDLE;
            endcase

            // flow control: pause sector requests when buffer > 75% full
            // (the WS_REQ state naturally waits because we only advance
            // to WS_REQ from WS_FILL when the sector is done; the buffer
            // level check is implicit in the consumption rate)
        end
    end

    // ---------------- read side ----------------
    // BRAM 读口：每拍无条件读 rd_ptr。rd_ptr 只在 sample_tick 时变化（相隔约 520 拍），
    // 下一次 tick 时 buf_q 早已是 buffer[rd_ptr]；且该地址的数据在写侧写入后至少经过
    // 格雷码 2FF 同步才被读侧看见，不存在读写同址冲突。
    (* ASYNC_REG = "TRUE" *) reg pe_s1, pe_s2;
     (* ASYNC_REG = "TRUE" *) reg flush_s1, flush_s2;
      
      (* ASYNC_REG = "TRUE" *) reg end_s1, end_s2;
     reg  flush_s3, flush_d;
      wire flush_evt = flush_s3 ^ flush_d;
      reg end_s3;
    reg [15:0] buf_q;
    reg [7:0] wav_gain_s;
    wire signed [24:0] scaled = $signed(buf_q) * $signed({1'b0,wav_gain_s});
    wire ended_rd = end_s3 && (level_rd == {ADDR_WIDTH{1'b0}});
      assign stream_active = pe_s2 && !ended_rd;   // 现在是 video_clk 域，直接给 mux 用
      assign stream_end    = ended_rd;
    always @(posedge rd_clk) begin
        buf_q <= buffer[rd_ptr];
    end

    // 欠账 tick 计数：下游 HDMI 打包器等数据岛时 ready 会拉低超过一个采样周期，
    // 若直接丢掉这次 tick，实际送出的样本率只有 ~46.9kHz（ACR 声明 48k），
    // 电视端音频缓冲持续欠载会整体静音。这里记下没来得及发的 tick，ready 后补发。
    reg [2:0] tick_owed;
    reg       issued_d;     // 刚发过一拍：buf_q 要再等一拍才更新到新 rd_ptr
    wire      can_issue = (!sample_valid || sample_ready) && !issued_d;
    wire      issue     = can_issue && (sample_tick || tick_owed != 3'd0);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr         <= {ADDR_WIDTH{1'b0}};
            sample_out     <= 16'sd0;
            sample_valid   <= 1'b0;
            sample_counter <= 32'd0;
            tick_owed      <= 3'd0;
            issued_d       <= 1'b0;
            wr_gray_sync1  <= {ADDR_WIDTH{1'b0}};
            wr_gray_sync2  <= {ADDR_WIDTH{1'b0}};
            rd_gray        <= {ADDR_WIDTH{1'b0}};
            //wstate_sync1   <= 3'd0;
            //wstate_sync2   <= 3'd0;
            pe_s1 <= 1'b0;
            pe_s2 <= 1'b0;
            flush_s1 <= 1'b0;
            flush_s2 <= 1'b0;
            flush_s3 <= 1'b0;
            flush_d <= 1'b0;
            end_s1 <= 1'b0;
            end_s2 <= 1'b0;
            end_s3 <= 1'b0;
            wav_gain_s <= 1'b0;
        end else begin
            // 本域指针先转格雷码寄存（源域），对端只同步格雷码
            rd_gray      <= to_gray(rd_ptr);
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
            //wstate_sync1 <= wstate;
            //wstate_sync2 <= wstate_sync1;
             end_s1 <= wr_end_q;
              end_s2 <= end_s1;
              end_s3 <= end_s2;
              pe_s1 <= play_enable;
            pe_s2 <= pe_s1;
            flush_s1 <= flush_toggle;
            flush_s2 <= flush_s1;
            flush_s3 <= flush_s2;
            flush_d  <= flush_s3;
            if (sample_valid && sample_ready)
            sample_valid <= 1'b0;
            // 每个采样节拍，平滑音量变化（最多变 1）
            if (sample_tick) begin
                if (wav_gain_s < gain)      
                    wav_gain_s <= wav_gain_s + 1'b1;
                else if (wav_gain_s > gain) 
                    wav_gain_s <= wav_gain_s - 1'b1;
            end
            issued_d <= issue;
            // tick 到了但发不出去 → 记账；没新 tick 但补发了一个 → 销账
            if (sample_tick && !issue && tick_owed != 3'd7)
                tick_owed <= tick_owed + 1'b1;
            else if (!sample_tick && issue)
                tick_owed <= tick_owed - 1'b1;

            
            
            
            
            if (issue) begin
                if ((level_rd >= SAMPLES_PER_SECTOR || (end_s3 && level_rd != 0))) begin
                    // enough data (or stream ended with residual): play
                    sample_out   <=  scaled[23:8];
                    rd_ptr       <= rd_ptr + 1'b1;
                    sample_valid <= 1'b1;
                    sample_counter <= sample_counter + 1'b1;
                end else begin
                    // prefill or underflow: silence, don't consume
                    sample_out   <= 16'sd0;
                    sample_valid <= 1'b1;
                end
            end
            if (flush_evt) begin
                  rd_ptr         <= wr_ptr_in_rd;   // 追平写指针，旧数据全部作废
                  sample_counter <= 32'd0;
              end
            
        end
    end
endmodule
