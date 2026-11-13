// sdh_env: the environment for src/Sd_Host.v -- the DUT with every input free and one reset cycle.
// No checking here: the checker (sdh_wb.sv) is bound into the DUT.
`default_nettype none
module sdh_env (
    input wire        clk,
    input wire        rb_valid, input wire rb_we, input wire [11:0] rb_addr,
    input wire [31:0] rb_wdata, input wire [3:0] rb_wstrb,
    input wire        spi_sclk, input wire spi_mosi, input wire spi_cs_n,
    input wire        esp32_en, input wire esp32_strap,
    input wire        cmd_i,    input wire [3:0] dat_i
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    sd_host dut (.clk(clk), .rst(init), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(), .rb_rdata(),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n), .spi_miso(),
        .esp32_en(esp32_en), .esp32_strap(esp32_strap),
        .clk_o(), .cmd_o(), .cmd_oe(), .cmd_i(cmd_i), .dat_o(), .dat_oe(), .dat_i(dat_i));
endmodule
