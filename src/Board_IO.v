// ================================================================
// Board_IO: the small ULX3S board devices, on the register bus (protocol in src/AXI4_RegBus.bsv).
//
//   0xC000_6000  i2c0: the I2C bus shared by the RTC (MCP7940N, address 0x6F) and HDMI DDC (0x50).
//     Registers of the OpenCores I2C master, so Linux `opencores,i2c-ocores` works with
//     reg-shift = 2, reg-io-width = 4:
//       0x00 PRERlo  RW  prescale: SCL = clk / (5 * (PRER + 1))
//       0x04 PRERhi  RW
//       0x08 CTR     RW  [7] EN, [6] IEN (stored only: no interrupt is wired, the driver polls)
//       0x0C RXR/TXR     read: last byte received; write: next byte to send
//       0x10 SR/CR       read SR:  [7] RxACK (1 = no ack) [6] bus busy [5] arbitration lost
//                                  [1] transfer in progress [0] done flag
//                        write CR: [7] STA [6] STO [5] RD [4] WR [3] ACK (1 = send no ack)
//                                  [0] IACK (clears the done flag).  Ignored while EN = 0 or
//                                  a transfer is in progress.
//       0x1C ID      RO  0x49324331 ("I2C1"), not in the OpenCores map
//     A device holding SCL low stalls the transfer (clock stretching); clearing EN abandons it
//     and releases both lines.
//   0xC000_8000  gpio1
//       0x00 ID      RO  0x47504931 ("GPI1")
//       0x04 BTN     RO  [6:0] buttons, 1 = pressed: 0 PWR, 1 FIRE1 (also the SoC reset),
//                        2 FIRE2, 3 UP, 4 DOWN, 5 LEFT, 6 RIGHT.  Not debounced.
//       0x08 SW      RO  [3:0] DIP switches, 1 = on
// ================================================================

module board_io (
    input  wire        clk,
    input  wire        rst,         // active high
    input  wire        rb_valid,
    input  wire        rb_we,
    input  wire [15:0] rb_addr,     // the low bits are enough: the fabric only routes mapped windows
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_wstrb,
    output reg         rb_ack,
    output reg  [31:0] rb_rdata,

    input  wire [6:0]  btn_i,       // at the pin: btn_i[0] is active low, the others active high
    input  wire [3:0]  sw_i,

    input  wire        scl_i,
    input  wire        sda_i,
    output reg         scl_low,     // 1 = drive the line low, 0 = release it
    output reg         sda_low
`ifdef FORMAL
    ,
    output wire [2:0]  f_state,
    output wire [2:0]  f_ph,
    output wire [3:0]  f_bits,
    output wire        f_en,
    output wire        f_wr,
    output wire        f_rd,
    output wire        f_sto,
    output wire [7:0]  f_shift,
    output wire        f_is_tick,
    output wire        f_tip,
    output wire        f_scl_s,
    output wire        f_sda_s,
    output wire [7:0]  f_rxr,
    output wire [7:0]  f_txr
`endif
);
    localparam S_IDLE = 3'd0, S_START = 3'd1, S_BITS = 3'd2, S_ACK = 3'd3, S_STOP = 3'd4;

    // ---------------- input synchronizers ----------------
    reg [1:0] scl_m, sda_m;
    reg [6:0] btn_m, btn_s;
    reg [3:0] sw_m, sw_s;
    wire scl_s = scl_m[1];
    wire sda_s = sda_m[1];
    always @(posedge clk) begin
        scl_m <= {scl_m[0], scl_i};
        sda_m <= {sda_m[0], sda_i};
        btn_m <= btn_i;  btn_s <= {btn_m[6:1], ~btn_m[0]};
        sw_m  <= sw_i;   sw_s  <= sw_m;
    end

    // ---------------- registers ----------------
    reg [15:0] prer;
    reg [7:0]  ctr, txr, rxr;
    reg        rxack, busy, al, tip, irq_flag;
    reg        c_sta, c_sto, c_rd, c_wr, c_ack;
    wire       en = ctr[7];

    wire       sel_i2c  = (rb_addr[15:12] == 4'h6);
    wire       sel_gpio = (rb_addr[15:12] == 4'h8);
    wire [2:0] reg_a    = rb_addr[4:2];
    wire       take     = rb_valid && !rb_ack;
    wire       wr_i2c   = take && rb_we && sel_i2c && rb_wstrb[0];
    wire       wr_cr    = wr_i2c && (reg_a == 3'd4);
    wire [7:0] sr       = {rxack, busy, al, 3'b0, tip, irq_flag};

    // ---------------- engine ----------------
    // One tick is PRER + 1 clocks, one bit is 5 ticks.
    reg [2:0]  state, ph;
    reg [3:0]  bits;
    reg [7:0]  shift;
    reg [15:0] cnt;
    wire       is_tick = (cnt == 0);
    wire       tx_bit  = (state == S_ACK) ? (c_rd ? c_ack : 1'b1)
                                          : (c_wr ? shift[7] : 1'b1);
    reg        sda_q, scl_q;     // for the bus-busy detector

    wire start_cmd = wr_cr && en && !tip;
    wire [7:0] cr_w = rb_wdata[7:0];

    // the next step once a phase of bytes ends
    task finish;
        begin
            state    <= S_IDLE;
            tip      <= 1'b0;
            irq_flag <= 1'b1;
        end
    endtask

    always @(posedge clk) begin
        rb_ack <= 1'b0;
        if (take) begin
            rb_ack   <= 1'b1;
            rb_rdata <= 32'b0;
            if (!rb_we) begin
                if (sel_gpio)
                    case (rb_addr[3:2])
                        2'd0: rb_rdata <= 32'h47504931;
                        2'd1: rb_rdata <= {25'b0, btn_s};
                        2'd2: rb_rdata <= {28'b0, sw_s};
                        default: ;
                    endcase
                else if (sel_i2c)
                    case (reg_a)
                        3'd0: rb_rdata <= {24'b0, prer[7:0]};
                        3'd1: rb_rdata <= {24'b0, prer[15:8]};
                        3'd2: rb_rdata <= {24'b0, ctr};
                        3'd3: rb_rdata <= {24'b0, rxr};
                        3'd4: rb_rdata <= {24'b0, sr};
                        3'd7: rb_rdata <= 32'h49324331;
                        default: ;
                    endcase
            end
        end

        if (wr_i2c)
            case (reg_a)
                3'd0: prer[7:0]  <= rb_wdata[7:0];
                3'd1: prer[15:8] <= rb_wdata[7:0];
                3'd2: ctr        <= rb_wdata[7:0];
                3'd3: txr        <= rb_wdata[7:0];
                default: ;
            endcase

        // bus busy: START and STOP as seen on the wires, by anyone
        sda_q <= sda_s;
        scl_q <= scl_s;
        if (scl_s && scl_q && sda_q && !sda_s) busy <= 1'b1;
        if (scl_s && scl_q && !sda_q && sda_s) busy <= 1'b0;

        if (wr_cr && cr_w[0]) irq_flag <= 1'b0;

        cnt <= is_tick ? prer : cnt - 16'd1;

        if (start_cmd && (cr_w[7:4] != 0)) begin
            c_sta <= cr_w[7];  c_sto <= cr_w[6];  c_rd <= cr_w[5];  c_wr <= cr_w[4];
            c_ack <= cr_w[3];
            shift <= txr;
            bits  <= 4'd8;
            al    <= 1'b0;
            tip   <= 1'b1;
            cnt   <= prer;
            ph    <= 3'd0;
            state <= cr_w[7] ? S_START : ((cr_w[5] || cr_w[4]) ? S_BITS : S_STOP);
        end
        else if (is_tick && (state != S_IDLE) && !(ph == 3'd3 && !scl_s)) begin
            ph <= (ph == 3'd4) ? 3'd0 : ph + 3'd1;
            case (state)
                S_START:
                    case (ph)
                        3'd0: sda_low <= 1'b0;      // repeated start: data high while SCL is low
                        3'd1: scl_low <= 1'b0;
                        3'd3: sda_low <= 1'b1;      // the START: data falls with SCL high
                        3'd4: begin
                            scl_low <= 1'b1;
                            if (c_rd || c_wr) state <= S_BITS;
                            else if (c_sto)   state <= S_STOP;
                            else              finish;
                        end
                        default: ;
                    endcase
                S_BITS, S_ACK:
                    case (ph)
                        3'd0: scl_low <= 1'b1;
                        3'd1: sda_low <= !tx_bit;
                        3'd2: scl_low <= 1'b0;
                        3'd4: begin
                            if (tx_bit && !sda_s && ((state == S_BITS && c_wr))) begin
                                // another master holds the data line: stop driving at once
                                al       <= 1'b1;
                                scl_low  <= 1'b0;
                                sda_low  <= 1'b0;
                                finish;
                            end
                            else if (state == S_BITS) begin
                                shift <= {shift[6:0], sda_s};
                                bits  <= bits - 4'd1;
                                if (bits == 4'd1) begin
                                    state <= S_ACK;
                                    if (c_rd) rxr <= {shift[6:0], sda_s};
                                end
                            end
                            else begin
                                if (c_wr) rxack <= sda_s;
                                if (c_sto) state <= S_STOP;
                                else begin
                                    // hold the clock low until the next command
                                    scl_low <= 1'b1;
                                    sda_low <= 1'b0;
                                    finish;
                                end
                            end
                        end
                        default: ;
                    endcase
                S_STOP:
                    case (ph)
                        3'd0: scl_low <= 1'b1;
                        3'd1: sda_low <= 1'b1;
                        3'd2: scl_low <= 1'b0;
                        3'd4: begin
                            sda_low <= 1'b0;        // the STOP: data rises with SCL high
                            finish;
                        end
                        default: ;
                    endcase
                default: ;
            endcase
        end

        if (rst || !en) begin
            // disabled: nothing driven, nothing in progress
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            state   <= S_IDLE;
            tip     <= 1'b0;
            ph      <= 3'd0;
        end
        if (rst) begin
            rb_ack   <= 1'b0;
            rb_rdata <= 32'b0;
            prer     <= 16'hFFFF;
            ctr      <= 8'b0;
            txr      <= 8'b0;
            rxr      <= 8'b0;
            rxack    <= 1'b0;
            busy     <= 1'b0;
            al       <= 1'b0;
            irq_flag <= 1'b0;
            cnt      <= 16'hFFFF;
            c_sta <= 1'b0;  c_sto <= 1'b0;  c_rd <= 1'b0;  c_wr <= 1'b0;  c_ack <= 1'b0;
            shift <= 8'b0;
            bits  <= 4'd0;
        end
    end

`ifdef FORMAL
    assign f_state = state;
    assign f_ph = ph;
    assign f_bits = bits;
    assign f_en = en;
    assign f_wr = c_wr;
    assign f_rd = c_rd;
    assign f_sto = c_sto;
    assign f_shift = shift;
    assign f_is_tick = is_tick;
    assign f_tip = tip;
    assign f_scl_s = scl_s;
    assign f_sda_s = sda_s;
    assign f_rxr = rxr;
    assign f_txr = txr;
`endif
endmodule
