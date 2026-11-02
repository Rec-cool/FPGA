`timescale 1ns/1ps

// B5：音乐播放列表（sd_card_clk 域），与图片轮播完全独立。
//   切歌来源：下一张键长按（next_req）、一首放完（stream_end，自动下一首）。
//   播放模式：KEY3（mode_req）轮换 顺序 → 单曲循环 → 随机。
//   每次切歌：音量 0.3 s 降到 0 → 换 track_idx → 等歌曲表读出 → restart → 音量升回。
//   音量 track_gain 每次只变 1，用格雷码输出，接收端 2FF 同步后直接解码即可。
module track_playlist_old #(
    parameter integer FADE_STEP_CYCLES = 117_647   // 100MHz 下 255 步 ≈ 0.3 s
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       play_enable,      // 图片加载完、播放器已开始工作
    input  wire [4:0] pcm_count,        // 歌曲表项数
    input  wire       next_req,         // 单拍：手动下一首
    input  wire       mode_req,         // 单拍：切换播放模式
    input  wire       stream_end,       // 电平：已同步到本域的"本首放完"
    output reg  [3:0] track_idx,        // 接歌曲表读地址
    output reg        restart,          // 单拍：通知播放器重新取 start_lba
    output reg  [1:0] play_mode,        // 0=顺序 1=单曲循环 2=随机
    output reg        song_event,       // 单拍：已切到新歌（给 OSD）
    output reg        mode_event,       // 单拍：模式已切换（给 OSD）
    output reg  [7:0] track_gain_gray   // 切歌淡入淡出增益（格雷码）
);
    localparam [1:0] MODE_SEQ = 2'd0;
    localparam [1:0] MODE_ONE = 2'd1;
    localparam [1:0] MODE_RND = 2'd2;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_DOWN  = 3'd1;   // 音量降到 0
    localparam [2:0] ST_PICK  = 3'd2;   // 选下一首
    localparam [2:0] ST_WAIT  = 3'd3;   // 等歌曲表读出（读口晚 1 拍）
    localparam [2:0] ST_UP    = 3'd4;   // 音量升回 255

    reg [2:0]  state;
    reg [7:0]  gain;
    reg [16:0] step_cnt;
    reg        auto_pending;    // 本次切歌由"放完"触发（单曲循环时不换曲目）
    reg [1:0]  wait_cnt;
    reg [15:0] lfsr;

    wire step = (step_cnt == FADE_STEP_CYCLES - 1);
    wire can_switch = play_enable && (pcm_count != 5'd0);
    // 顺序下一首（按 pcm_count 回绕）
    wire [3:0] seq_next = ({1'b0, track_idx} + 5'd1 >= pcm_count) ? 4'd0 : track_idx + 4'd1;
    // 随机候选：LFSR 低 4 位，超出曲目数或与当前相同则下一拍再试
    wire [3:0] rnd_cand = lfsr[3:0];
    wire       rnd_ok   = ({1'b0, rnd_cand} < pcm_count) && (rnd_cand != track_idx);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            gain            <= 8'd255;
            track_gain_gray <= 8'd255 ^ (8'd255 >> 1);
            step_cnt        <= 17'd0;
            auto_pending    <= 1'b0;
            wait_cnt        <= 2'd0;
            lfsr            <= 16'hACE1;
            track_idx       <= 4'd0;
            restart         <= 1'b0;
            play_mode       <= MODE_SEQ;
            song_event      <= 1'b0;
            mode_event      <= 1'b0;
        end else begin
            restart    <= 1'b0;
            song_event <= 1'b0;
            mode_event <= 1'b0;
            lfsr       <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            track_gain_gray <= gain ^ (gain >> 1);
            step_cnt   <= (state == ST_DOWN || state == ST_UP) && !step ? step_cnt + 17'd1 : 17'd0;

            if (mode_req) begin
                play_mode  <= (play_mode == MODE_RND) ? MODE_SEQ : play_mode + 2'd1;
                mode_event <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    // 放完用电平判断：上次切歌的淡入要 0.3 s，这期间播放器早已清掉 stream_end，
                    // 回到 IDLE 时若仍为高，说明新歌也已放完（或读扇区出错），继续切下一首
                    if (can_switch && (next_req || stream_end)) begin
                        auto_pending <= !next_req;
                        state        <= ST_DOWN;
                    end
                end
                ST_DOWN: begin
                    if (gain == 8'd0)
                        state <= ST_PICK;
                    else if (step)
                        gain <= gain - 8'd1;
                end
                ST_PICK: begin
                    if (auto_pending && play_mode == MODE_ONE) begin
                        state <= ST_WAIT;                     // 单曲循环：同一首重放
                    end else if (play_mode == MODE_RND && pcm_count > 5'd1) begin
                        if (rnd_ok) begin
                            track_idx <= rnd_cand;
                            state     <= ST_WAIT;
                        end
                    end else begin
                        track_idx <= seq_next;
                        state     <= ST_WAIT;
                    end
                    wait_cnt <= 2'd0;
                end
                ST_WAIT: begin
                    wait_cnt <= wait_cnt + 2'd1;
                    if (wait_cnt == 2'd2) begin
                        restart    <= 1'b1;
                        song_event <= 1'b1;
                        state      <= ST_UP;
                    end
                end
                ST_UP: begin
                    if (gain == 8'd255)
                        state <= ST_IDLE;
                    else if (step)
                        gain <= gain + 8'd1;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
