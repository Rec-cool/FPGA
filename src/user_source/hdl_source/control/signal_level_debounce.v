`timescale 1ns/1ps

  // 单路电平消抖：两级同步 + 稳定计数，按键和拨码通用。
  // 同步后电平与 stable 不同时开始计数，连续 DEBOUNCE_MS 不变才更新
  //stable；
  // 中途抖回去计数清零。rise/fall 为 stable 的单拍边沿。
  // INIT_LEVEL 设成输入的静止电平，避免复位释放后产生假边沿：
  //   低有效按键（上拉）→ 1，按下取 fall；拨码 → 0（默认档位）。
  module signal_level_debounce #(
      parameter integer CLK_FREQ_HZ = 100_000_000,
      parameter integer DEBOUNCE_MS = 20,
      parameter [0:0]   INIT_LEVEL  = 1'b0
  ) (
      input  wire clk,
      input  wire rst_n,
      input  wire din,
      output reg  stable,
      output reg  rise,
      output reg  fall
  );
      localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) *
  DEBOUNCE_MS;
      localparam integer CNT_W = (DEBOUNCE_CYCLES <= 2) ? 1 :
  $clog2(DEBOUNCE_CYCLES);

      reg             sync0, sync1;
      reg [CNT_W-1:0] cnt;

      always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
              sync0  <= INIT_LEVEL;
              sync1  <= INIT_LEVEL;
              stable <= INIT_LEVEL;
              cnt    <= 0;
              rise   <= 1'b0;
              fall   <= 1'b0;
          end else begin
              sync0 <= din;
              sync1 <= sync0;
              rise  <= 1'b0;
              fall  <= 1'b0;
              if (stable == sync1) begin
                  cnt <= 0;
              end else if (cnt >= DEBOUNCE_CYCLES - 1) begin
                  cnt    <= 0;
                  stable <= sync1;
                  rise   <=  sync1;
                  fall   <= ~sync1;
              end else begin
                  cnt <= cnt + 1'b1;
              end
          end
      end
  endmodule