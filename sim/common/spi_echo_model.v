// spi_echo_model: a stand-in in the on-board ADC's place for the strict bench.  NOT a MAX11125
// model (its datasheet has not been read here): it checks the host side only.  SPI mode 0, MSB
// first, 16-bit words counted across the whole time CS is low (so a word sent as two 8-bit frames
// under CSMODE HOLD, with a pause between them, is one word).  Each word shifted out is the
// previous word shifted in; the first after power-up is 16'hA5C3.  Clocked: sck is sampled on clk.
module spi_echo_model (
    input  wire clk,
    input  wire sck,
    input  wire mosi,
    input  wire cs_n,
    output wire miso
);
    reg        sck_q = 1'b0, cs_q = 1'b1;
    reg [15:0] in_sr = 16'h0, out_sr = 16'hA5C3, last = 16'hA5C3;
    reg [3:0]  cnt = 4'd0;
    reg        reload = 1'b0;
    assign miso = cs_n ? 1'b1 : out_sr[15];
    always @(posedge clk) begin
        sck_q <= sck;
        cs_q  <= cs_n;
        if (cs_q && !cs_n) begin              // CS asserted: the last word goes out
            cnt <= 4'd0; out_sr <= last; reload <= 1'b0;
        end else if (!cs_n) begin
            if (!sck_q && sck) begin          // rising edge: sample
                in_sr <= {in_sr[14:0], mosi};
                cnt   <= cnt + 4'd1;
                if (cnt == 4'd15) begin last <= {in_sr[14:0], mosi}; reload <= 1'b1; end
            end
            if (sck_q && !sck) begin          // falling edge: next bit out
                if (reload) begin out_sr <= last; reload <= 1'b0; end
                else        out_sr <= {out_sr[14:0], 1'b0};
            end
        end
    end
endmodule
