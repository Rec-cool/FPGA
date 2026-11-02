module mon; int last = 0, mx = 0, n = 0, t = 0; reg [3:0] m_q = 0;
  always @(posedge tb.clk) begin t++;
    if (tb.rst) begin last = t; mx = 0; end
    else begin
      if (tb.u.sd_sec_read_end) begin if (t - last > mx && tb.u.card_busy_phase) mx = t - last; last = t; n++; end
      if (tb.msg != m_q) $display("t=%0d msg %0d -> %0d  ctrl=%0d idx=%0d scan_c=%0d busy=%0d stall_cnt=%0d sectors=%0d maxgap=%0d lb=%0d", t, m_q, tb.msg, tb.u.load_ctrl_state, tb.u.load_ctrl_idx, tb.u.scan_complete, tb.u.card_busy_phase, tb.u.sd_stall_cnt, n, mx, tb.lb);
      m_q = tb.msg;
    end
    if (t == 400000) $finish;
  end
endmodule
