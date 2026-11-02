module mon2; int t = 0, last = 0;
  always @(posedge tb.clk) begin t++;
    if (tb.u.sd_sec_read_end || tb.u.sd_sec_read && !$past(tb.u.sd_sec_read) || tb.fc || tb.ls) $display("t=%0d rd_end=%0d rd=%0d lba=%0d ls=%0d fc=%0d pv_cnt", t, tb.u.sd_sec_read_end, tb.u.sd_sec_read, tb.u.sd_sec_read_addr, tb.ls, tb.fc);
    if (t == 60000) $finish;
  end
  int pv = 0; always @(posedge tb.clk) if (tb.pv) pv++;
  always @(posedge tb.clk) if (t % 5000 == 0) $display("t=%0d pixels=%0d stall_cnt=%0d", t, pv, tb.u.sd_stall_cnt);
endmodule
