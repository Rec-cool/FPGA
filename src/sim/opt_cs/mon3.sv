module mon3; int t = 0;
  initial begin
    wait (tb.content == 4 && tb.msg == 5);
    repeat (5) begin
      $display("t=%0t busy=%0d failed=%0d init=%0d drv_rst=%0d wd=%0d scstate=%0d", $time, tb.u.scanner_busy, tb.u.scan_failed, tb.u.sd_init_done, tb.u.sd_drv_rst, tb.u.sd_wd_cnt, tb.u.u_scanner.state);
      repeat (7000) @(posedge tb.clk);
    end
    $finish;
  end
endmodule
