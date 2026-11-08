// Formal harness for mkAXI4_SPI (src/AXI4_SPI.bsv), built with -D FORMAL by
// `make formal-spi-verilog`.  The AXI master is a free input constrained to single-beat AXI;
// MISO is looped back to MOSI.  Checked:
//   FIFOs:   TX and RX levels never exceed 8;
//   CS:      a CS asserts only when selected and CSMODE != OFF (the flash, CS 1, only for CSID 1);
//            every SCK edge of a frame has the selected CS asserted (CSMODE != OFF);
//            HOLD persists while CSID / CSMODE / CSDEF keep their values (rewriting the same
//            value does not release it: FE310, what spi-sifive relies on);
//   data:    a tracked TXDATA byte goes out on MOSI as its own frame, in the frame's
//            mode (CPOL/CPHA, bit order), and through the loopback is read back from RXDATA
//            in FIFO order (when RX is enabled and not full);
//   AXI4:    B/R held until accepted, one response per request, rlast.
// Environment simplifications: SCKDIV <= 1 while a frame is queued or running (frame length),
// SCKMODE / FMT change only while idle (the driver's behaviour; the frame latches them).
// Proofs (spi.sby): prove_ctl (abc pdr, -D NO_DATA) FIFOs, CS, HOLD, AXI; prove_k (k-induction,
// k=6, -D DATA_ONLY) the data path with the invariants below, assuming the FIFO bounds prove_ctl
// proved (prove_ctl assumes nothing from it, so this is not circular).  The RX end is checked at
// the RXDATA pop (f_rx_pop), not on the R channel; the lane mapping is covered by Tb_AXI4_SPI.
module spi_fv (
    input wire        clk,
    input wire        awvalid, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire        wvalid,  input wire [63:0] wdata, input wire [7:0] wstrb,
    input wire        bready,
    input wire        arvalid, input wire [3:0] arid, input wire [63:0] araddr,
    input wire        rready,
    input wire        mark                 // picks the TXDATA byte to track
);
    reg [1:0] rcnt = 0;
    always @(posedge clk) if (rcnt != 2'd3) rcnt <= rcnt + 1;
    wire rst_n = (rcnt >= 2'd2);
    reg pv = 0, pv2 = 0;
    always @(posedge clk) begin pv <= rst_n; pv2 <= pv; end
    reg inited = 0;
    always @(posedge clk) if (rst_n) inited <= 1;
    wire do_init = rst_n && !inited;

    wire awready, wready, bvalid, arready, rvalid, rlast;
    wire [3:0] bid, rid; wire [1:0] bresp, rresp; wire [63:0] rdata;
    wire sclk, mosi, irq; wire [1:0] cs_n;
    wire [3:0] tx_level, rx_level; wire busy, endian, dir, frame_end;
    wire [31:0] csid; wire [1:0] csmode, csdef, sckmode; wire [11:0] sckdiv;
    wire [8:0] tx_enq, rx_push, rx_pop;
    wire [3:0] tx_rp, rx_rp; wire [63:0] v_tx, v_rx; wire [4:0] edge_n;
    wire [11:0] cnt, f_div; wire [7:0] sh_tx, sh_rx; wire r_pha, r_end, r_dir, miso_q;

    mkAXI4_SPI dut (
        .CLK (clk), .RST_N (rst_n),
        .init_axi4_id (4'd0), .init_addr_base (64'h0), .init_addr_lim (64'h1000),
        .EN_init (do_init), .RDY_init (), .EN_reset (1'b0), .RDY_reset (),
        .slave_awvalid (awvalid), .slave_awid (awid), .slave_awaddr (awaddr),
        .slave_awlen (8'd0), .slave_awsize (3'd2), .slave_awburst (2'b01), .slave_awlock (1'b0),
        .slave_awcache (4'd0), .slave_awprot (3'd0), .slave_awqos (4'd0), .slave_awregion (4'd0),
        .slave_awready (awready),
        .slave_wvalid (wvalid), .slave_wdata (wdata), .slave_wstrb (wstrb), .slave_wlast (1'b1),
        .slave_wready (wready),
        .slave_bvalid (bvalid), .slave_bid (bid), .slave_bresp (bresp), .slave_bready (bready),
        .slave_arvalid (arvalid), .slave_arid (arid), .slave_araddr (araddr),
        .slave_arlen (8'd0), .slave_arsize (3'd2), .slave_arburst (2'b01), .slave_arlock (1'b0),
        .slave_arcache (4'd0), .slave_arprot (3'd0), .slave_arqos (4'd0), .slave_arregion (4'd0),
        .slave_arready (arready),
        .slave_rvalid (rvalid), .slave_rid (rid), .slave_rdata (rdata), .slave_rresp (rresp),
        .slave_rlast (rlast), .slave_rready (rready),
        .interrupt_req (irq), .RDY_interrupt_req (),
        .sclk (sclk), .mosi (mosi), .cs_n (cs_n),
        .miso0_v (mosi), .miso1_v (mosi),                 // loopback
        .f_tx_level (tx_level), .f_rx_level (rx_level), .f_busy (busy), .f_csid (csid),
        .f_csmode (csmode), .f_csdef (csdef), .f_sckmode (sckmode), .f_endian (endian),
        .f_dir (dir), .f_sckdiv (sckdiv), .f_tx_enq (tx_enq), .f_frame_end (frame_end),
        .f_rx_push (rx_push), .f_rx_pop (rx_pop),
        .f_tx_rp (tx_rp), .f_rx_rp (rx_rp), .f_v_tx (v_tx), .f_v_rx (v_rx), .f_edge (edge_n),
        .f_cnt (cnt), .f_f_div (f_div), .f_sh_tx (sh_tx), .f_sh_rx (sh_rx),
        .f_f_pha (r_pha), .f_f_endian (r_end), .f_f_dir (r_dir), .f_miso_q (miso_q));

    wire idle = !busy && tx_level == 0;
    wire start = !busy && tx_level != 0;          // the engine starts a frame this cycle

    // ---------------- environment ----------------
    always @(*) begin
        if (!inited) assume (!awvalid && !wvalid && !arvalid);
        if (!idle) assume (sckdiv <= 12'd1);
    end
    always @(posedge clk) if (pv) begin
        if ($past(awvalid && !awready)) assume (awvalid && awid == $past(awid) && awaddr == $past(awaddr));
        if ($past(wvalid && !wready))   assume (wvalid && wdata == $past(wdata) && wstrb == $past(wstrb));
        if ($past(arvalid && !arready)) assume (arvalid && arid == $past(arid) && araddr == $past(araddr));
        if (!$past(idle)) assume (sckmode == $past(sckmode) && endian == $past(endian) && dir == $past(dir));
    end

    // ---------------- FIFOs ----------------
`ifdef DATA_ONLY
    // proved by prove_ctl, which assumes nothing from the data proof
    always @(*) begin assume (tx_level <= 4'd8); assume (rx_level <= 4'd8); end
`else
    always @(*) if (pv) begin
        assert (tx_level <= 4'd8);
        assert (rx_level <= 4'd8);
    end
`endif

`ifndef DATA_ONLY
    // ---------------- chip selects ----------------
    // cs_n is registered from the previous cycle's state
    always @(posedge clk) if (pv2) begin
        if (!cs_n[1]) assert ($past(csid) == 32'd1 && $past(csmode) != 2'd3);
        if (cs_n[0] != $past(csdef[0])) assert ($past(csid) == 32'd0 && $past(csmode) != 2'd3);
        // a frame's SCK edge has the selected CS asserted
        if ($past(busy) && sclk != $past(sclk) && $past(csmode) != 2'd3) begin
            if ($past(csid) == 32'd0) assert (cs_n[0] == !$past(csdef[0]));
            if ($past(csid) == 32'd1) assert (!cs_n[1]);
        end
    end
    // HOLD: asserted while idle in HOLD, unchanged CSID / CSMODE / CSDEF => still asserted
    always @(posedge clk) if (pv2 && $past(pv2)) begin
        if ($past(cs_n[0] == !$past(csdef[0]))           // asserted at t-1 (wrt csdef at t-2)
            && $past(!$past(busy)) && $past($past(csmode)) == 2'd2
            && $past(csid) == 32'd0 && $past($past(csid)) == 32'd0
            && $past(csmode) == 2'd2 && $past(csdef) == $past($past(csdef)))
            assert (cs_n[0] == !$past(csdef[0]));
    end

`endif
    // ---------------- data: one tracked byte, TX pin and RX FIFO ----------------
    localparam ST_IDLE = 0, ST_QUEUED = 1, ST_FRAME = 2, ST_RXQ = 3, ST_DONE = 4;
    reg [2:0] st = ST_IDLE;
    reg [7:0] tb = 0;                     // the tracked byte
    reg [3:0] ahead = 0;                  // frames to start before it / RX pops before it
    reg       f_pol = 0, f_pha = 0, f_end = 0, f_dir = 0;
    reg [7:0] dec = 0; reg [3:0] ndec = 0;   // MOSI decoder (sampled bits, in wire order)
    reg sclk_q = 0;
    always @(posedge clk) sclk_q <= sclk;
    wire leading  = (sclk != sclk_q) && (sclk_q == f_pol);
    wire trailing = (sclk != sclk_q) && (sclk_q != f_pol);
    wire sample   = f_pha ? trailing : leading;
    // the last sampling edge can coincide with frame_end: include this cycle's sample
    wire       take     = busy && sample && ndec < 8;
    wire [7:0] dec_n    = take ? {dec[6:0], mosi} : dec;
    wire [3:0] ndec_n   = take ? ndec + 4'd1 : ndec;
    wire [7:0] dec_byte = f_end ? {dec_n[0],dec_n[1],dec_n[2],dec_n[3],dec_n[4],dec_n[5],dec_n[6],dec_n[7]} : dec_n;

    always @(posedge clk) if (pv) begin
        case (st)
        ST_IDLE:
            if (tx_enq[8] && mark) begin
                st <= ST_QUEUED; tb <= tx_enq[7:0];
                ahead <= tx_level - (start ? 4'd1 : 4'd0);
            end
        ST_QUEUED:
            if (start) begin
                if (ahead == 0) begin
                    st <= ST_FRAME; f_pol <= sckmode[1]; f_pha <= sckmode[0];
                    f_end <= endian; f_dir <= dir; ndec <= 0;
                end else ahead <= ahead - 1;
            end
        ST_FRAME: begin
            dec <= dec_n; ndec <= ndec_n;
            if (frame_end) begin
                if (rx_push[8]) begin
                    st <= ST_RXQ; ahead <= rx_level - (rx_pop[8] ? 4'd1 : 4'd0);
                end else st <= ST_DONE;
            end
        end
        ST_RXQ:
            if (rx_pop[8]) begin
                if (ahead == 0) st <= ST_DONE; else ahead <= ahead - 1;
            end
        default: ;
        endcase
    end
`ifndef NO_DATA
    always @(*) if (pv) begin
        if (st == ST_QUEUED) assert (ahead < tx_level);
        if (st == ST_FRAME && frame_end) begin
            assert (ndec_n == 8);
            assert (dec_byte == tb);
            if (!f_dir && rx_level != 8) assert (rx_push[8] && rx_push[7:0] == tb);
            if (f_dir) assert (!rx_push[8]);
        end
        if (st == ST_RXQ && rx_pop[8] && ahead == 0) assert (rx_pop[7:0] == tb);
        if (st == ST_RXQ) assert (ahead < rx_level);
    end
`endif

`ifndef NO_DATA
    // ---------------- data invariants: make the data asserts inductive at low depth ----------------
    wire [7:0] wire_b  = f_end ? {tb[0],tb[1],tb[2],tb[3],tb[4],tb[5],tb[6],tb[7]} : tb;
    wire [3:0] e_half  = edge_n[4:1];                         // complete SCK periods
    wire [3:0] n_smp   = f_pha ? e_half : (edge_n[4:1] + {3'b0, edge_n[0]});   // sampling edges so far
    wire [2:0] tx_slot = tx_rp[2:0] + ahead[2:0];
    wire [2:0] rx_slot = rx_rp[2:0] + ahead[2:0];
    wire [3:0] e_m1    = e_half - 4'd1;
    wire [3:0] n_cap   = f_pha ? ((edge_n == 0) ? 4'd0 : (edge_n[0] ? e_half : e_m1)) : e_half;
    always @(*) if (pv) begin
        assert (rcnt >= 2'd2);
        // every frame, tracked or not: SCK follows the edge count and idles at CPOL
        if (busy) begin
            assert (edge_n <= 5'd16);
            assert (sclk == (sckmode[1] ^ edge_n[0]));
        end
        if (start) assert (sclk == sckmode[1]);
        if (st == ST_QUEUED) assert (v_tx[8*tx_slot +: 8] == tb);
        if (st == ST_RXQ)    assert (v_rx[8*rx_slot +: 8] == tb);
        if (st == ST_FRAME) begin
            assert (busy);
            assert (edge_n <= 5'd16);
            assert (r_pha == f_pha && r_end == f_end && r_dir == f_dir);
            assert (sckmode[1] == f_pol && sckmode[0] == f_pha);
            assert (endian == f_end && dir == f_dir);
            assert (sclk == (f_pol ^ edge_n[0]));
            assert (f_div <= 12'd1 && cnt <= f_div);
            assert (ndec_n == n_smp);
            assert ((dec_n & ((16'd1 << ndec_n) - 16'd1)) == (wire_b >> (4'd8 - ndec_n)));
            // the TX shifter: bits still to go
            if (!f_pha) assert (sh_tx == (wire_b << e_half));
            else        assert (sh_tx == (wire_b << (e_half + {3'b0, edge_n[0]})));
            // MOSI: the bit on the wire for this half period
            if (!f_pha && edge_n < 5'd16) assert (mosi == wire_b[3'd7 - e_half[2:0]]);
            if (f_pha && edge_n[0])       assert (mosi == wire_b[3'd7 - e_half[2:0]]);
            if (f_pha && !edge_n[0] && edge_n != 0) begin
                assert (mosi   == wire_b[3'd7 - e_m1[2:0]]);
                assert (miso_q == wire_b[3'd7 - e_m1[2:0]]);    // the capture about to happen
            end
            if (!f_pha && edge_n[0]) assert (miso_q == wire_b[3'd7 - e_half[2:0]]);
            // the RX shifter: bits captured so far (loopback)
            assert ((sh_rx & ((16'd1 << n_cap) - 16'd1)) == (wire_b >> (4'd8 - n_cap)));
        end
    end
`endif
`ifndef DATA_ONLY
    // ---------------- AXI4 ----------------
    always @(posedge clk) if (pv) begin
        if ($past(bvalid && !bready)) assert (bvalid && bid == $past(bid) && bresp == $past(bresp));
        if ($past(rvalid && !rready)) assert (rvalid && rid == $past(rid) && rdata == $past(rdata)
                                              && rresp == $past(rresp) && rlast == $past(rlast));
    end
    always @(*) if (pv && rvalid) assert (rlast);
    reg [3:0] n_aw = 0, n_b = 0, n_ar = 0, n_r = 0;
    always @(posedge clk)
        if (!rst_n) begin n_aw <= 0; n_b <= 0; n_ar <= 0; n_r <= 0; end
        else begin
            if (awvalid && awready) n_aw <= n_aw + 1;
            if (bvalid && bready)   n_b  <= n_b + 1;
            if (arvalid && arready) n_ar <= n_ar + 1;
            if (rvalid && rready)   n_r  <= n_r + 1;
        end
    always @(*) if (pv) begin
        if (bvalid) assert (n_b != n_aw);
        if (rvalid) assert (n_r != n_ar);
    end
`endif

    // ---------------- reachability ----------------
    always @(*) if (pv) begin
        cover (st == ST_RXQ && rx_pop[8] && ahead == 0);                  // byte read back
        cover (st == ST_FRAME && frame_end && f_pha && f_pol && f_end);    // mode 3, LSB first
        cover (!cs_n[0] && !busy && csmode == 2'd2 && st == ST_DONE);      // HOLD after a frame
        cover (!cs_n[1] && busy);                                          // a flash frame
    end
endmodule
