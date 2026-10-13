// ================================================================
// tb_mailbox.sv — probe 2b: inter-class communication under
// --no-timing (the F1 harness mode). Findings folded in from
// mini-probes: blocking mailbox put()/get() and semaphore put()
// are implemented over the blocking mailbox and ERROR under
// --no-timing (NOTIMING). Non-blocking try_put/try_get/num/peek
// work. So this probe uses the non-blocking API exclusively.
// ================================================================

class txn;
  int id;
  logic [7:0] data;
  function new(int id, logic [7:0] d);
    this.id = id;
    data = d;
  endfunction
endclass

module tb_top;
  mailbox #(txn) mbx;      // typed mailbox
  mailbox #(int) bounded;  // bounded mailbox: backpressure probe
  txn q[$];               // plain class-handle queue
  int n_ok = 0;

  initial begin
    txn t1;
    txn t2;
    txn t;
    int v;

    mbx = new(0);
    bounded = new(2);

    // --- put then get via try_* (non-blocking API only) ---
    t1 = new(1, 8'hAA);
    t2 = new(2, 8'h55);
    if (mbx.try_put(t1) == 1 && mbx.try_put(t2) == 1) begin
      n_ok++;
      $display("[tb] two try_puts accepted, num()==%0d", mbx.num());
    end
    if (mbx.try_get(t) == 1 && t.id == 1 && t.data == 8'hAA) begin
      n_ok++;
      $display("[tb] try_get: id=%0d data=0x%02x", t.id, t.data);
    end

    // --- try_peek then get; try_get on empty -> 0 ---
    if (mbx.try_peek(t) == 1 && t.id == 2) begin
      n_ok++;
      $display("[tb] try_peek sees id=%0d (still queued)", t.id);
    end
    void'(mbx.try_get(t));   // drains t2; mailbox now empty
    if (mbx.num() == 0 && mbx.try_get(t) == 0) begin
      n_ok++;
      $display("[tb] try_get on empty mailbox returned 0");
    end

    // --- bounded mailbox(cap 2): third put backpressures ---
    if (bounded.try_put(10) == 1 && bounded.try_put(20) == 1 &&
        bounded.try_put(30) == 0) begin
      n_ok++;
      $display("[tb] bounded mailbox(cap 2) backpressures 3rd put");
    end
    void'(bounded.try_get(v));
    void'(bounded.try_get(v));

    // --- class-handle queue: order + drain ---
    for (int i = 0; i < 4; i++) begin
      t = new(i, i * 3);
      q.push_back(t);
    end
    if (q.size() == 4 && q[0].id == 0 && q[3].id == 3) begin
      n_ok++;
      $display("[tb] class-handle queue push/size/index ok");
    end
    begin
      int sum = 0;
      while (q.size() > 0) begin
        t = q.pop_front();
        sum += t.data;
      end
      if (sum == 3 + 6 + 9) begin
        n_ok++;
        $display("[tb] queue drain order ok (sum=%0d)", sum);
      end
    end

    if (n_ok == 7) $display("MAILBOX: PASS");
    else           $display("MAILBOX: FAIL (n_ok=%0d/7)", n_ok);
    $finish;
  end
endmodule
