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
        .f_rx_push (rx_push), .f_rx_pop (rx_pop));

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
    always @(*) if (pv) begin
        assert (tx_level <= 4'd8);
        assert (rx_level <= 4'd8);
    end

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

    // ---------------- reachability ----------------
    always @(*) if (pv) begin
        cover (st == ST_RXQ && rx_pop[8] && ahead == 0);                  // byte read back
        cover (st == ST_FRAME && frame_end && f_pha && f_pol && f_end);    // mode 3, LSB first
        cover (!cs_n[0] && !busy && csmode == 2'd2 && st == ST_DONE);      // HOLD after a frame
        cover (!cs_n[1] && busy);                                          // a flash frame
    end
endmodule
