// ================================================================
// spi_flash_model.v -- behavioral SPI NOR flash (W25Q128-like, 16 MB) for the Verilator benches.
//
// Synchronous to the bench clock like sd_spi_model.v: samples SCK/MOSI/CS every clk, mode 0
// (MOSI sampled on rising SCK, MISO changes after falling SCK).  Contents start erased (0xFF);
// +flash_image=<hex> preloads them ($readmemh, one byte per line, @<byte offset> lines allowed).
// +flash_trace=1 logs each command.  Commands: 03 READ, 0B FAST READ (one dummy byte),
// 9F JEDEC ID (EF 40 18), 05 RDSR (00), 66/99 reset, AB release power-down, B9 power-down;
// anything else is ignored until CS rises.  Writes are not modelled.
// ================================================================
`default_nettype none
module spi_flash_model #(parameter integer NBYTES = 16 * 1024 * 1024) (
    input  wire clk,
    input  wire sck,
    input  wire mosi,
    input  wire cs_n,
    output reg  miso
);
    reg [7:0]  mem [0:NBYTES-1];
    reg        sck_q, cs_q;
    reg [7:0]  rx_sh, tx_sh;
    reg [2:0]  bitcnt;
    reg [7:0]  cmd;
    integer    nbytes;        // bytes received since CS fell
    reg [23:0] addr;
    integer    i, trace;
    reg [63:0] cyc;
    reg [8*256-1:0] fname;

    // next byte to shift out, called at the falling edge that ends a byte
    function [7:0] out_byte (input integer n);
        begin
            out_byte = 8'hFF;
            case (cmd)
                8'h03: if (n >= 4) out_byte = mem[addr];
                8'h0B: if (n >= 5) out_byte = mem[addr];
                8'h9F: case (n) 1: out_byte = 8'hEF; 2: out_byte = 8'h40; 3: out_byte = 8'h18; default: ; endcase
                8'h05: out_byte = 8'h00;
                default: ;
            endcase
        end
    endfunction

    task got_byte (input [7:0] b);
        begin
            if (nbytes == 0) cmd = b;
            else if (nbytes <= 3 && (cmd == 8'h03 || cmd == 8'h0B)) addr = {addr[15:0], b};
            nbytes = nbytes + 1;
            if (trace != 0 && (nbytes == 1 && cmd != 8'h03 && cmd != 8'h0B))
                $display ("[flash] %0d cmd %02x", cyc, cmd);
            if (trace != 0 && nbytes == 4 && (cmd == 8'h03 || cmd == 8'h0B))
                $display ("[flash] %0d cmd %02x addr %06x", cyc, cmd, addr);
        end
    endtask

    initial begin
        for (i = 0; i < NBYTES; i = i + 1) mem[i] = 8'hFF;
        if (! $value$plusargs ("flash_trace=%d", trace)) trace = 0;
        if ($value$plusargs ("flash_image=%s", fname)) $readmemh (fname, mem);
        cyc = 0; sck_q = 0; cs_q = 1; bitcnt = 0; tx_sh = 8'hFF; miso = 1'b1; nbytes = 0;
        cmd = 8'h00; addr = 24'h0;
    end

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cs_n) begin
            bitcnt = 0; nbytes = 0; tx_sh = 8'hFF;
            miso <= 1'b1;
        end
        else begin
            if (cs_q) begin                                // CS fell
                tx_sh = 8'hFF;
                miso <= 1'b1;
            end
            else if (sck && !sck_q) begin                  // rising: sample
                rx_sh  = {rx_sh[6:0], mosi};
                bitcnt = bitcnt + 1;
                if (bitcnt == 0) got_byte (rx_sh);
            end
            else if (!sck && sck_q) begin                  // falling: next bit / next byte
                if (bitcnt == 0) begin
                    tx_sh = out_byte (nbytes);
                    if ((cmd == 8'h03 && nbytes >= 4) || (cmd == 8'h0B && nbytes >= 5)) addr = addr + 1;
                end
                else
                    tx_sh = {tx_sh[6:0], 1'b1};
                miso <= tx_sh[7];
            end
        end
        sck_q = sck;
        cs_q  = cs_n;
    end
endmodule
`default_nettype wire
