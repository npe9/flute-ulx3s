// i2c_host_mon: an I2C host (master) at the wires, against the host's trace of its commands, in
// the style of the AXI4 FVIP: HOST_IS_DUT=1 assumes the rest of the bus (the slaves, below) and
// asserts the host's rules; 0 would check a slave model against a host.
//
// The host's commands are the OpenCores I2C master's: {STA, STO, RD, WR, ACK} and a byte to send.
// Trace inputs (one-cycle events, on the edge that makes the change):
//   cmd_valid, cmd, cmd_tx   a command starts
//   start, stop              the host pulls SDA low / releases it, with SCL high
//   rx_valid, rx             a read's 8th bit is sampled; rx is the byte
//   ack_valid, ack           a write's acknowledge bit is sampled
//   done, al                 the command ends (al: it lost arbitration); abort: it is abandoned
//
// Bus model (assumed): each line is low when the host or a slave pulls it (open drain).  A slave
// moves SDA only while SCL is low, and starts holding SCL low (clock stretching) only while it is
// already low; there is no second host.
//
// Host rules (asserted):
//   * SDA changes while SCL stays high only as the START or STOP the trace announced (or as the
//     lines are released when a command is abandoned), so no data bit looks like a condition;
//   * one command at a time; START only when the command asked for one, then 9 SCL pulses for a
//     read or a write, then one more and the STOP if it asked for one, and nothing else;
//   * at each data pulse of a write the host drives the command's byte MSB first (pulls SDA low
//     for a 0, releases it for a 1); during a read it releases SDA, and drives the acknowledge
//     (low unless ACK asked for no-ack); during a write's acknowledge it releases SDA;
//   * a sample is taken while SCL is high, after its pulse: rx is the 8 bits on the wire at the 8
//     pulses, ack the bit at the 9th;
//   * arbitration is lost exactly when a write's released 1 reads back as 0, and nothing follows;
//   * the host releases SCL and pulls SDA only during a command (or as it is abandoned);
//   * data hold: the host pulls SDA low only once SCL is already low on the wire (or as a START),
//     never on the same edge as it pulls SCL low.
`default_nettype none
module i2c_host_mon #(parameter integer HOST_IS_DUT = 1) (
    input  wire       clk, rst,
    input  wire       scl_low, sda_low,      // the host's open-drain drivers (1 = pull low)
    input  wire       scl, sda,              // the wires
    input  wire       cmd_valid, input wire [4:0] cmd, input wire [7:0] cmd_tx,
    input  wire       start, stop, rx_valid, input wire [7:0] rx, input wire ack_valid, ack,
    input  wire       done, al, abort,
    // the monitor's state, for the user's covers and invariants
    output reg        pend,           // a command is in progress
    output reg  [4:0] q,              // its {STA, STO, RD, WR, ACK}
    output reg  [7:0] tx,             // and its byte
    output reg        started,        // its START has happened
    output reg        arm,            // the host has pulled SCL low since: pulses count
    output reg  [3:0] n,              // SCL pulses counted in this command
    output reg  [7:0] got,            // the wire's SDA at each pulse (newest in bit 0)
    output reg        lb,             // the wire's SDA at the latest pulse
    output reg        al_due,         // a write's 1 read back as 0
    output reg        scl_q, sda_q, scll_q, sdal_q,
    output wire       pulse                  // a counted SCL pulse starts now
);
    initial begin
        pend = 1'b0;
        q = 5'd0;
        tx = 8'd0;
        started = 1'b0;
        arm = 1'b0;
        n = 4'd0;
        got = 8'd0;
        lb = 1'b1;
        al_due = 1'b0;
        scl_q = 1'b1;
        sda_q = 1'b1;
        scll_q = 1'b0;
        sdal_q = 1'b0;
    end
    wire q_sta = q[4], q_sto = q[3], q_rd = q[2], q_wr = q[1], q_ack = q[0];
    wire rw    = q_rd || q_wr;
    wire [3:0] need = (rw ? 4'd9 : 4'd0) + (q_sto ? 4'd1 : 4'd0);
    wire go    = pend && (started || !q_sta);          // past the START, if any
    wire rise  = scl && !scl_q;
    assign pulse = rise && arm && go;
    reg  ev_q = 1'b0, st_q = 1'b0, sp_q = 1'b0, ab_q = 1'b0, pend_q = 1'b0, r_q = 1'b1;
    always @(posedge clk) begin
        scl_q <= scl;  sda_q <= sda;  scll_q <= scl_low;  sdal_q <= sda_low;
        ev_q <= start || stop || abort;  st_q <= start;  sp_q <= stop;  ab_q <= abort;
        pend_q <= pend;  r_q <= rst;
        if (go && scl_low) arm <= 1'b1;
        if (pulse) begin
            n  <= n + 4'd1;
            lb <= sda;
            if (rw && n < 4'd8) begin
                got <= {got[6:0], sda};
                if (q_wr && tx[3'd7 - n[2:0]] && !sda) al_due <= 1'b1;
            end
        end
        if (start) begin started <= 1'b1; arm <= 1'b0; n <= 4'd0; end
        if (cmd_valid) begin
            pend <= 1'b1;  q <= cmd;  tx <= cmd_tx;
            started <= 1'b0;  arm <= 1'b0;  n <= 4'd0;  got <= 8'd0;  al_due <= 1'b0;
        end
        if (done || abort) pend <= 1'b0;
        if (rst) begin pend <= 1'b0; al_due <= 1'b0; end
    end

    // ---------------- the rest of the bus ----------------
    (* anyseq *) reg sl_scl, sl_sda;                   // a slave pulling each line
    reg sl_scl_q = 1'b0, sl_sda_q = 1'b0;
    always @(posedge clk) begin sl_scl_q <= sl_scl; sl_sda_q <= sl_sda; end
    wire w_lines = (scl == !(scl_low || sl_scl)) && (sda == !(sda_low || sl_sda));
    wire w_sda   = !(scl && scl_q) || sl_sda == sl_sda_q;
    wire w_scl   = !(sl_scl && !sl_scl_q) || !scl_q;

    // ---------------- the host ----------------
    wire h_cond   = !(scl && scl_q && sda_low != sdal_q) || ev_q;
    wire h_start  = !st_q || (sda_low && !sdal_q && scl && scl_q);
    wire h_stop   = !sp_q || (!sda_low && sdal_q && scl && scl_q);
    wire h_wire   = !(scl && scl_q && sda != sda_q) || ev_q;
    wire h_one    = !cmd_valid || !pend;
    wire h_ev     = !(start || stop || rx_valid || ack_valid || done || al) || pend;
    wire h_sta    = !start || (q_sta && !started);
    wire h_pulses = !pulse || (n < need && !al_due);
    wire h_drive  = !pulse || !rw || n > 4'd8 ||
                    (n < 4'd8 ? sda_low == (q_wr && !tx[3'd7 - n[2:0]])
                              : sda_low == (q_rd && !q_ack));
    wire h_rx     = !rx_valid || (q_rd && go && n == 4'd8 && scl && !al_due && rx == got);
    wire h_ack    = !ack_valid || (q_wr && go && n == 4'd9 && scl && !al_due && ack == lb);
    wire h_al     = !al || (al_due && done && q_wr && scl);
    wire h_stp    = !stop || (q_sto && go && n == need && !al_due);
    wire h_done   = !done || al || (go && n == need && (q_sto == stop));
    wire h_scl    = !(scll_q && !scl_low) || pend_q || ab_q;
    wire h_sda    = !(!sdal_q && sda_low) || pend_q;
    wire h_hold   = !(!sdal_q && sda_low) || !scl_q || st_q;
    generate if (HOST_IS_DUT) begin : host
        always @(*) begin
            assume (w_lines);
            if (!rst) begin assume (w_sda); assume (w_scl); end
        end
        always @(*) if (!rst && !r_q) begin
            assert (h_cond); assert (h_start); assert (h_stop); assert (h_wire); assert (h_one);
            assert (h_ev); assert (h_sta); assert (h_pulses); assert (h_drive); assert (h_rx);
            assert (h_ack); assert (h_al); assert (h_stp); assert (h_done); assert (h_scl);
            assert (h_sda); assert (h_hold);
        end
    end endgenerate
endmodule
