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
    assume (slave_arlen <= 8'd7);
    assume (slave_awlen <= 8'd7);
  end


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
  end
`endif
endmodule
`default_nettype wire
