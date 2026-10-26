// AXI4 protocol check of Mem_Controller's slave port with the YosysHQ FVIP (DESTINATION agent).
// Environment: free AXI4 source (constrained by the FVIP's cp_* assumes), free raw memory
// (any data, any latency, but only the chunks it owes for the reads it was given), BSV method
// protocol (EN only when RDY). Bursts of up to 8 beats (Flute's masters issue AxLEN <= 7; the
// controller takes bursts directly, no AXI4_Deburster in front).
// Define REACH to turn the reachability witnesses into asserts that must FAIL.
`default_nettype none
module mc_fvip_top (
  input wire CLK,
  input wire slave_awvalid, input wire [3:0] slave_awid, input wire [63:0] slave_awaddr,
  input wire [7:0] slave_awlen, input wire [2:0] slave_awsize, input wire [1:0] slave_awburst,
  input wire slave_awlock, input wire [3:0] slave_awcache, input wire [2:0] slave_awprot,
  input wire [3:0] slave_awqos, input wire [3:0] slave_awregion,
  input wire slave_wvalid, input wire [63:0] slave_wdata, input wire [7:0] slave_wstrb, input wire slave_wlast,
  input wire slave_bready,
  input wire slave_arvalid, input wire [3:0] slave_arid, input wire [63:0] slave_araddr,
  input wire [7:0] slave_arlen, input wire [2:0] slave_arsize, input wire [1:0] slave_arburst,
  input wire slave_arlock, input wire [3:0] slave_arcache, input wire [2:0] slave_arprot,
  input wire [3:0] slave_arqos, input wire [3:0] slave_arregion,
  input wire slave_rready,
  input wire EN_server_reset_request_put, input wire EN_server_reset_response_get,
  input wire [63:0] set_addr_map_addr_base, input wire [63:0] set_addr_map_addr_lim, input wire EN_set_addr_map,
  input wire EN_to_raw_mem_request_get,
  input wire [63:0] to_raw_mem_response_put, input wire EN_to_raw_mem_response_put
`ifdef DATA
  , input wire [21:0] x_word_in, input wire [63:0] x_init_in   // symbolic, latched in cycle 0
`endif
);
  // Reset: low in cycle 0, high afterwards.
  reg rst_done = 1'b0;  // zero init: ic3 -init-zero zeroes every register
  always @(posedge CLK) rst_done <= 1'b1;
  wire RST_N = rst_done;

  wire slave_awready, slave_wready, slave_bvalid, slave_arready, slave_rvalid, slave_rlast;
  wire [3:0] slave_bid, slave_rid;
  wire [1:0] slave_bresp, slave_rresp;
  wire [63:0] slave_rdata;
  wire RDY_server_reset_request_put, RDY_server_reset_response_get, RDY_set_addr_map;
  wire RDY_to_raw_mem_request_get, RDY_to_raw_mem_response_put;
  wire [311:0] to_raw_mem_request_get;   // {write, line[18:0], b_first[1:0], b_last[1:0], wdata[255:0], wbe[31:0]}
  wire [7:0] status;

  wire       raw_rd     = EN_to_raw_mem_request_get && !to_raw_mem_request_get[311];
  wire [1:0] raw_bfirst = to_raw_mem_request_get[291:290];
  wire [1:0] raw_blast  = to_raw_mem_request_get[289:288];
  wire [2:0] raw_bursts = {1'b0, raw_blast} - {1'b0, raw_bfirst} + 3'd1;   // 3 bits: 4 bursts must not wrap
  wire [4:0] raw_chunks = {1'b0, raw_bursts, 1'b0};
  reg  [5:0] owed = 0;
  always @(posedge CLK)
    if (!RST_N) owed <= 0;
    else owed <= owed + (raw_rd ? raw_chunks : 5'd0) - (EN_to_raw_mem_response_put ? 6'd1 : 6'd0);

  // BSV method protocol.
  always @* begin
    // External reset is a boot-time-only operation in the SoC (power-on reset alone reaches READY).
    // Unconstrained, a mid-traffic server_reset clears the slave FIFOs and drops BVALID/RVALID before
    // the handshake (ap_B_BVALID_until_BREADY / ap_R_RVALID_until_RREADY fail at step 6).
    assume (!EN_server_reset_request_put);
    assume (!EN_server_reset_response_get || RDY_server_reset_response_get);
    assume (!EN_set_addr_map              || RDY_set_addr_map);
    assume (!EN_to_raw_mem_request_get    || RDY_to_raw_mem_request_get);
    assume (!EN_to_raw_mem_response_put   || RDY_to_raw_mem_response_put);
    // Raw memory returns exactly the chunks of the reads it took, in order (2 per burst)
    assume (!EN_to_raw_mem_response_put   || (owed != 0));
    // Masters wait for the controller to leave power-on reset (RDY_set_addr_map = rg_ready).
    // Up to Flute 112c371 the reset cycle cleared the slave transactor FIFOs while
    // AWREADY/WREADY/ARREADY were high, dropping a handshake (found by ap_live_r); fixed in the
    // drain change. NO_RDY_WAIT drops this assume to check that.
`ifndef NO_RDY_WAIT
    assume (RDY_set_addr_map || !(slave_arvalid || slave_awvalid || slave_wvalid));
`endif
    assume (slave_arlen <= 8'd7);
    assume (slave_awlen <= 8'd7);
  end


`ifdef MC_SMALL
  wire dbg_age_out;
`endif
  mkMem_Controller dut (.*);

  amba_axi4_protocol_checker
    #('{ID_WIDTH:          4,
        ADDRESS_WIDTH:     64,
        DATA_WIDTH:        64,
        AWUSER_WIDTH:      1,
        WUSER_WIDTH:       1,
        BUSER_WIDTH:       1,
        ARUSER_WIDTH:      1,
        RUSER_WIDTH:       1,
        MAX_WR_BURSTS:     4,
        MAX_RD_BURSTS:     4,
        MAX_WR_LENGTH:     8,
        MAX_RD_LENGTH:     8,
        MAXWAIT:           15,
        VERIFY_AGENT_TYPE: amba_axi4_protocol_checker_pkg::DESTINATION,
        PROTOCOL_TYPE:     amba_axi4_protocol_checker_pkg::AXI4FULL,
        INTERFACE_REQS:    1,
        ENABLE_COVER:      1,
        ENABLE_XPROP:      0,
        ARM_RECOMMENDED:   0,
        CHECK_PARAMETERS:  1,
        OPTIONAL_WSTRB:    1,
        FULL_WR_STRB:      0,
        OPTIONAL_RESET:    0,
        EXCLUSIVE_ACCESS:  0,
        OPTIONAL_LP:       0})
  mc_chk (
    .ACLK(CLK), .ARESETn(RST_N),
    .AWID(slave_awid), .AWADDR(slave_awaddr), .AWREGION(slave_awregion), .AWLEN(slave_awlen),
    .AWSIZE(slave_awsize), .AWBURST(slave_awburst), .AWLOCK(slave_awlock), .AWCACHE(slave_awcache),
    .AWPROT(slave_awprot), .AWQOS(slave_awqos), .AWVALID(slave_awvalid), .AWREADY(slave_awready), .AWUSER(1'b0),
    .WDATA(slave_wdata), .WSTRB(slave_wstrb), .WLAST(slave_wlast), .WVALID(slave_wvalid), .WREADY(slave_wready), .WUSER(1'b0),
    .BID(slave_bid), .BRESP(slave_bresp), .BVALID(slave_bvalid), .BREADY(slave_bready), .BUSER(1'b0),
    .ARID(slave_arid), .ARADDR(slave_araddr), .ARREGION(slave_arregion), .ARLEN(slave_arlen),
    .ARSIZE(slave_arsize), .ARBURST(slave_arburst), .ARLOCK(slave_arlock), .ARCACHE(slave_arcache),
    .ARPROT(slave_arprot), .ARQOS(slave_arqos), .ARVALID(slave_arvalid), .ARREADY(slave_arready), .ARUSER(1'b0),
    .RID(slave_rid), .RDATA(slave_rdata), .RRESP(slave_rresp), .RLAST(slave_rlast), .RVALID(slave_rvalid),
    .RREADY(slave_rready), .RUSER(1'b0));

  // Outstanding transactions as seen at the port (AW/AR handshakes minus B/last-R handshakes).
  reg [3:0] wr_out = 0, rd_out = 0;
  always @(posedge CLK)
    if (!RST_N) begin wr_out <= 0; rd_out <= 0; end
    else begin
      wr_out <= wr_out + (slave_awvalid && slave_awready) - (slave_bvalid && slave_bready);
      rd_out <= rd_out + (slave_arvalid && slave_arready) - (slave_rvalid && slave_rready && slave_rlast);
    end
  // Source-side bound that the FVIP's DESTINATION scoreboard (MAX_WR_BURSTS = 4) relies on; a paired
  // SOURCE checker would supply it as cp_no_overflow_no_dead_end. Flute's masters stay well inside it.
  always @* assume (!(wr_out >= 4 && slave_awvalid));

  // Mem_Controller never owes more raw chunks than one line (8): the next raw read waits for the last.
  always @(posedge CLK) if (RST_N) begin
    ap_owed_le8: assert (owed <= 6'd8);
  end

`ifdef LIVE
  // Bounded liveness as safety. Environment: raw memory takes an offered request, and returns an owed
  // chunk the controller can accept, within RAW_W cycles; the master takes R and B within RDY_W cycles.
  // Every assume constrains only environment inputs while they are enabled, so none can block the DUT. Then a read in flight gets
  // an R beat, and a write whose AW and last W are both in gets its B, within LIVE_K cycles.
  // Defaults: a prompt environment (no wait), so LIVE_K bounds the controller's own latency. With
  // waits, LIVE_K must also cover them (up to 8 chunks x RAW_W for a 4-burst read).
`ifndef LIVE_RAW_W
`define LIVE_RAW_W 1
`endif
`ifndef LIVE_RDY_W
`define LIVE_RDY_W 1
`endif
`ifndef LIVE_K
`define LIVE_K 12
`endif
  localparam RAW_W = `LIVE_RAW_W, RDY_W = `LIVE_RDY_W, LIVE_K = `LIVE_K;
  reg [3:0] raw_req_wait = 0, raw_rsp_wait = 0, r_wait = 0, b_wait = 0;
  reg [4:0] rd_stall = 0, wr_stall = 0;
  reg [3:0] wl_out = 0;   // last-W handshakes not yet answered by B
  always @(posedge CLK)
    if (!RST_N) begin
      raw_req_wait <= 0; raw_rsp_wait <= 0; r_wait <= 0; b_wait <= 0; rd_stall <= 0; wr_stall <= 0; wl_out <= 0;
    end else begin
      raw_req_wait <= (RDY_to_raw_mem_request_get && !EN_to_raw_mem_request_get) ? raw_req_wait + 1 : 0;
      raw_rsp_wait <= ((owed != 0) && RDY_to_raw_mem_response_put && !EN_to_raw_mem_response_put) ? raw_rsp_wait + 1 : 0;
      r_wait <= (slave_rvalid && !slave_rready) ? r_wait + 1 : 0;
      b_wait <= (slave_bvalid && !slave_bready) ? b_wait + 1 : 0;
      wl_out <= wl_out + (slave_wvalid && slave_wready && slave_wlast) - (slave_bvalid && slave_bready);
      rd_stall <= ((rd_out != 0) && !(slave_rvalid && slave_rready)) ? rd_stall + 1 : 0;
      wr_stall <= ((wr_out != 0) && (wl_out != 0) && !(slave_bvalid && slave_bready)) ? wr_stall + 1 : 0;
    end
  // Source rules the DESTINATION checker does not assume, needed so "AW and last W in" means the
  // same to the harness as to Mem_Controller (which counts beats from AWLEN): W only for an
  // accepted AW, WLAST exactly on beat AWLEN.
  reg [7:0] lv_len [0:3];
  reg [1:0] lv_tail = 0, lv_ptr = 0;
  reg [2:0] lv_open = 0;
  reg [7:0] lv_beat = 0;
  always @(posedge CLK)
    if (!RST_N) begin lv_tail <= 0; lv_ptr <= 0; lv_open <= 0; lv_beat <= 0; end
    else begin
      if (slave_awvalid && slave_awready) begin lv_len[lv_tail] <= slave_awlen; lv_tail <= lv_tail + 1; end
      if (slave_wvalid && slave_wready) begin
        if (slave_wlast) begin lv_ptr <= lv_ptr + 1; lv_beat <= 0; end else lv_beat <= lv_beat + 1;
      end
      lv_open <= lv_open + (slave_awvalid && slave_awready) - (slave_wvalid && slave_wready && slave_wlast);
    end
  always @* begin
    assume (!slave_wvalid || lv_open != 0);
    assume (!slave_wvalid || (slave_wlast == (lv_beat == lv_len[lv_ptr])));
  end
  always @* begin
    assume (raw_req_wait < RAW_W);
    assume (raw_rsp_wait < RAW_W);
    assume (r_wait < RDY_W);
    assume (b_wait < RDY_W);
  end
  always @(posedge CLK) if (RST_N) begin
    ap_live_r: assert (rd_stall < LIVE_K);
    ap_live_b: assert (wr_stall < LIVE_K);
  end
`endif

`ifdef DATA
  // Data integrity for one symbolic 64-bit word X (word offset x_word from addr_base; x_init is its
  // initial memory content). Raw memory is modelled as storage for X alone: raw writes update mem_x
  // through wbe, raw reads snapshot it at the request and must return the snapshot in X's chunk.
  // AXI side: shadow takes every OKAY-burst W beat to X; an R beat for X must equal shadow unless
  // a write to X was in flight at any time between that read's AR and the beat (AXI leaves the
  // order of overlapping reads and writes open).
  reg [21:0] x_word = 0; reg [63:0] x_init = 0;
  always @(posedge CLK) if (!RST_N) begin x_word <= x_word_in; x_init <= x_init_in; end
  function [63:0] merge (input [63:0] old, input [63:0] d, input [7:0] be);
    integer i;
    for (i = 0; i < 8; i = i + 1) merge[8*i +: 8] = be[i] ? d[8*i +: 8] : old[8*i +: 8];
  endfunction

  // Address map: fixed before the first AR/AW handshake (the controller computes offsets later).
  reg        any_hs = 0;
  reg [63:0] base_q = 0, lim_q = 0;
  wire ar_hs = slave_arvalid && slave_arready, aw_hs = slave_awvalid && slave_awready;
  wire w_hs  = slave_wvalid && slave_wready,   r_hs  = slave_rvalid && slave_rready;
  wire b_hs  = slave_bvalid && slave_bready;
  always @(posedge CLK) begin
    if (ar_hs || aw_hs) any_hs <= 1;
    if (EN_set_addr_map) begin base_q <= set_addr_map_addr_base; lim_q <= set_addr_map_addr_lim; end
  end
  function aligned (input [63:0] a, input [2:0] sz);
    aligned = (sz == 0) || (sz == 1 && a[0] == 0) || (sz == 2 && a[1:0] == 0) || (sz == 3 && a[2:0] == 0);
  endfunction
  function burst_ok (input [63:0] a, input [7:0] len, input [2:0] sz, input [1:0] bu);
    reg [63:0] last;
    begin
      last = a + (({56'b0, len} << 3) | 64'd7);
      burst_ok = aligned (a, sz) && base_q <= a && a < lim_q
                 && (len == 0 || (sz == 3 && bu == 2'b01 && base_q <= last && last < lim_q));
    end
  endfunction
  wire [63:0] ar_off = slave_araddr - base_q, aw_off = slave_awaddr - base_q;

  // AW queue (wr_out <= 4 by the assume above): first word, ok, touches X.
  reg [21:0] aw_w0 [0:3]; reg [7:0] aw_len [0:3]; reg aw_ok [0:3]; reg aw_x [0:3];
  reg [2:0] aw_n = 0;           // AWs accepted, not yet B'd
  reg [1:0] aw_tail = 0, w_ptr = 0, b_ptr = 0;
  reg [2:0] w_open = 0;         // AWs whose W burst is not finished
  reg [7:0] w_beat = 0;
  wire aw_hit = burst_ok (slave_awaddr, slave_awlen, slave_awsize, slave_awburst)
                && ({1'b0, x_word} >= {1'b0, aw_off[24:3]}) && ({1'b0, x_word} <= {1'b0, aw_off[24:3]} + slave_awlen);
  // W only for an accepted AW (the harness pairs beats with AWs; Flute's fabric sends AW first)
  always @* assume (!slave_wvalid || w_open != 0);
  wire [21:0] w_word = aw_w0[w_ptr] + w_beat;
  // WLAST on beat AWLEN (a source rule the DESTINATION checker does not assume; Mem_Controller
  // counts beats from AWLEN and ignores WLAST)
  always @* assume (!slave_wvalid || (slave_wlast == (w_beat == aw_len[w_ptr])));
  wire w_to_x = w_hs && aw_ok[w_ptr] && (w_word == x_word);
  reg [2:0] x_wr_pend = 0;      // outstanding AWs that touch X
  wire x_busy = (x_wr_pend != 0) || (aw_hs && aw_hit);

  // AR queue (bounded to 4 here): first word, len, ok, taint.
  always @* assume (!(rd_out >= 4 && slave_arvalid));
  reg [21:0] ar_w0 [0:3]; reg ar_ok [0:3]; reg ar_t [0:3];
  reg [1:0] ar_tail = 0, r_ptr = 0;
  reg [7:0] r_beat = 0;
  reg [63:0] shadow = 0;
  integer k;
  always @(posedge CLK)
    if (!RST_N) begin
      shadow <= x_init_in;
    end else begin
      if (aw_hs) begin
        aw_w0[aw_tail] <= aw_off[24:3]; aw_len[aw_tail] <= slave_awlen;
        aw_ok[aw_tail] <= burst_ok (slave_awaddr, slave_awlen, slave_awsize, slave_awburst);
        aw_x[aw_tail] <= aw_hit; aw_tail <= aw_tail + 1;
      end
      if (w_hs) begin
        if (w_to_x) shadow <= merge (shadow, slave_wdata, slave_wstrb);
        if (slave_wlast) begin w_ptr <= w_ptr + 1; w_beat <= 0; end else w_beat <= w_beat + 1;
      end
      w_open    <= w_open + aw_hs - (w_hs && slave_wlast);
      x_wr_pend <= x_wr_pend + (aw_hs && aw_hit) - (b_hs && aw_x[b_ptr]);
      if (b_hs) b_ptr <= b_ptr + 1;
      if (ar_hs) begin
        ar_w0[ar_tail] <= ar_off[24:3];
        ar_ok[ar_tail] <= burst_ok (slave_araddr, slave_arlen, slave_arsize, slave_arburst);
        ar_t[ar_tail]  <= x_busy; ar_tail <= ar_tail + 1;
      end
      if (x_busy) for (k = 0; k < 4; k = k + 1) ar_t[k] <= 1;   // stale entries are rewritten at AR
      if (r_hs) begin
        if (slave_rlast) begin r_ptr <= r_ptr + 1; r_beat <= 0; end else r_beat <= r_beat + 1;
      end
    end
  wire [21:0] r_word = ar_w0[r_ptr] + r_beat;
  always @(posedge CLK) if (RST_N && r_hs) begin
    ap_rresp:   assert (slave_rresp == (ar_ok[r_ptr] ? 2'b00 : 2'b10));
    ap_data_x:  assert (!(ar_ok[r_ptr] && !ar_t[r_ptr] && r_word == x_word) || slave_rdata == shadow);
  end
  always @(posedge CLK) if (RST_N && b_hs) begin
    ap_bresp:   assert (slave_bresp == (aw_ok[b_ptr] ? 2'b00 : 2'b10));
  end
  always @* assume (!EN_set_addr_map || !(any_hs || ar_hs || aw_hs));

  // Raw memory for X: storage, read snapshots (a read owes chunks b_first*2 .. b_last*2+1).
  reg [63:0] mem_x = 0;
  reg [18:0] rq_line [0:3]; reg [2:0] rq_c0 [0:3]; reg [2:0] rq_c1 [0:3]; reg [63:0] rq_snap [0:3];
  reg [1:0] rq_tail = 0, rq_head = 0;
  reg [2:0] rq_c = 0;                     // next chunk of the head read
  reg       rq_c_on = 0;                  // rq_c holds the head's progress (else start at c0)
  wire [311:0] rq = to_raw_mem_request_get;
  wire [2:0] cur_c = rq_c_on ? rq_c : rq_c0[rq_head];
  wire       wr_x = EN_to_raw_mem_request_get && rq[311] && (rq[310:292] == x_word[21:3]) && (rq[291] == x_word[2]);
  wire [1:0] wq = x_word[1:0];
  always @(posedge CLK)
    if (!RST_N) mem_x <= x_init_in;
    else begin
      if (wr_x) mem_x <= merge (mem_x, rq[32 + 64*wq +: 64], rq[8*wq +: 8]);
      if (raw_rd) begin
        rq_line[rq_tail] <= rq[310:292]; rq_c0[rq_tail] <= {rq[291:290], 1'b0}; rq_c1[rq_tail] <= {rq[289:288], 1'b1};
        rq_snap[rq_tail] <= mem_x; rq_tail <= rq_tail + 1;
      end
      if (EN_to_raw_mem_response_put) begin
        if (cur_c == rq_c1[rq_head]) begin rq_head <= rq_head + 1; rq_c_on <= 0; end
        else begin rq_c <= cur_c + 1; rq_c_on <= 1; end
      end
    end
  always @* assume (!(EN_to_raw_mem_response_put && rq_line[rq_head] == x_word[21:3] && cur_c == x_word[2:0])
                    || to_raw_mem_response_put == rq_snap[rq_head]);
`endif

  // Reachability witnesses (covers are not checked by sva2check yet): each must FAIL under REACH.
`ifdef REACH
  always @(posedge CLK) if (RST_N) begin
    reach_b_okay:  assert (!(slave_bvalid && slave_bready && slave_bresp == 2'b00));
    reach_r_okay:  assert (!(slave_rvalid && slave_rready && slave_rresp == 2'b00));
    reach_b_err:   assert (!(slave_bvalid && slave_bresp == 2'b10));
    reach_r_err:   assert (!(slave_rvalid && slave_rresp == 2'b10));
    reach_wr_out2: assert (wr_out < 2);
    reach_wr_out3: assert (wr_out < 3);
    reach_wr_out4: assert (wr_out < 4);
    reach_rd_out2: assert (rd_out < 2);
    reach_r_burst: assert (!(slave_rvalid && slave_rready && !slave_rlast));    // a multi-beat read
    reach_w_burst: assert (!(slave_wvalid && slave_wready && !slave_wlast));    // a multi-beat write
    reach_raw_wb:  assert (!(EN_to_raw_mem_request_get && to_raw_mem_request_get[311]));  // a writeback
`ifdef DATA
    // ap_data_x is checked on a read of X that returns data written through the port
    reach_data_x:  assert (!(r_hs && ar_ok[r_ptr] && !ar_t[r_ptr] && r_word == x_word && shadow != x_init));
    // ... and on one served from raw memory after a writeback of X (mem_x changed)
    reach_data_wb: assert (!(r_hs && ar_ok[r_ptr] && !ar_t[r_ptr] && r_word == x_word && mem_x != x_init
                             && EN_to_raw_mem_response_put));
`endif
`ifdef MC_SMALL
    // Formal-only build (build_small.sh: age-out after 4 dirty cycles, -D MC_FORMAL_PROBES): a
    // writeback taken while the buffer has aged out.
    reach_age_wb:  assert (!(EN_to_raw_mem_request_get && to_raw_mem_request_get[311] && dbg_age_out));
`endif
  end
`endif
endmodule
`default_nettype wire
