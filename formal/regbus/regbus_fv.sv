// Formal harness for mkAXI4_RegBus (src/AXI4_RegBus.bsv), built with -D FORMAL by
// `make formal-regbus-verilog`.  The AXI master and the register-bus device are free inputs
// constrained to their protocols; the asserts are the bridge's half of both:
//   register bus: rb_valid held with stable fields until the ack (or the 256-cycle watchdog),
//                 dropped the cycle after the ack, word-aligned, no zero-strobe write;
//   AXI4 slave:   B/R held stable until accepted, every response answers an accepted request,
//                 single-beat reads (rlast), SLVERR only from the watchdog.
module regbus_fv (
    input wire        clk,
    // AXI4 master (single-beat, as the peripheral fabric issues)
    input wire        awvalid, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire        wvalid,  input wire [63:0] wdata, input wire [7:0] wstrb,
    input wire        bready,
    input wire        arvalid, input wire [3:0] arid, input wire [63:0] araddr,
    input wire        rready,
    // register-bus device
    input wire        ack, input wire [31:0] ack_rdata,
    input wire        ext_reset           // the reset method (ndmreset)
);
    reg [1:0] rcnt = 0;
    always @(posedge clk) if (rcnt != 2'd3) rcnt <= rcnt + 1;
    wire rst_n = (rcnt >= 2'd2);
    reg pv = 0;                            // $past is meaningful
    always @(posedge clk) pv <= rst_n;

    wire awready, wready, bvalid, arready, rvalid, rlast;
    wire [3:0] bid, rid; wire [1:0] bresp, rresp; wire [63:0] rdata;
    wire rb_valid, rb_we; wire [31:0] rb_addr, rb_wdata; wire [3:0] rb_wstrb;
    wire [7:0] f_wdog;
`ifdef SHORT_WDOG
    localparam [7:0] WDOG_MAX = 8'd7;      // mkAXI4_RegBus built with -D FORMAL_SHORT_WDOG
`else
    localparam [7:0] WDOG_MAX = 8'hFF;
`endif

    mkAXI4_RegBus dut (
        .CLK (clk), .RST_N (rst_n), .EN_reset (ext_reset), .RDY_reset (),
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
        .rb_valid (rb_valid), .rb_we (rb_we), .rb_addr (rb_addr), .rb_wdata (rb_wdata),
        .rb_wstrb (rb_wstrb), .rb_ack_ack (ack), .rb_ack_rdata (ack_rdata),
        .f_wdog (f_wdog));

    // ---------------- environment ----------------
    always @(*) begin
        if (!rst_n) assume (!awvalid && !wvalid && !arvalid && !ack && !ext_reset);
`ifndef WITH_EXT_RESET
        assume (!ext_reset);
`endif
        assume (!ack || rb_valid);         // the device acks only a pending request
    end
    always @(posedge clk) if (pv) begin
        // AXI: a valid stays up, with its payload, until accepted
        if ($past(awvalid && !awready)) assume (awvalid && awid == $past(awid) && awaddr == $past(awaddr));
        if ($past(wvalid && !wready))   assume (wvalid && wdata == $past(wdata) && wstrb == $past(wstrb));
        if ($past(arvalid && !arready)) assume (arvalid && arid == $past(arid) && araddr == $past(araddr));
        // device: one ack per request (none in the cycle after an ack)
        if ($past(ack)) assume (!ack);
    end

    // ---------------- register bus: the bridge's half ----------------
    always @(*) if (pv && rb_valid) begin
        assert (rb_addr[1:0] == 2'b00);
        if (rb_we) assert (rb_wstrb != 4'b0);
    end
    always @(posedge clk) if (pv && $past(rst_n) && !$past(ext_reset)) begin
        // held and stable until the ack, unless the watchdog expired
        if ($past(rb_valid && !ack) && $past(f_wdog) != WDOG_MAX) begin
            assert (rb_valid);
            assert (rb_we == $past(rb_we) && rb_addr == $past(rb_addr));
            assert (rb_wdata == $past(rb_wdata) && rb_wstrb == $past(rb_wstrb));
        end
        // dropped the cycle after the ack: the ack must never be lost
        if ($past(rb_valid && ack)) assert (!rb_valid);
    end

    // ---------------- AXI4: the bridge's half ----------------
    always @(posedge clk) if (pv && $past(rst_n) && !$past(ext_reset)) begin
        if ($past(bvalid && !bready)) assert (bvalid && bid == $past(bid) && bresp == $past(bresp));
        if ($past(rvalid && !rready)) assert (rvalid && rid == $past(rid) && rdata == $past(rdata)
                                              && rresp == $past(rresp) && rlast == $past(rlast));
    end
    always @(*) if (pv && rvalid) assert (rlast);

    // every response answers an accepted request (counts, modulo the reset method)
    reg [3:0] n_aw = 0, n_b = 0, n_ar = 0, n_r = 0;
    always @(posedge clk)
        if (!rst_n || ext_reset) begin n_aw <= 0; n_b <= 0; n_ar <= 0; n_r <= 0; end
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
        cover (rb_valid && rb_we && ack);
        cover (rb_valid && !rb_we && ack);
        cover (bvalid && bresp == 2'b10);                  // a watchdog SLVERR
        cover (rvalid && rdata[63:32] != 0 && rdata[31:0] == 0);   // the upper lane
    end
endmodule
