// fb_capture: writes the DVI block's scan-out (src/Video_DVI.v pre-encoder taps) to a PPM.
// +fb_ppm=<file>: at the end of every frame that had active pixels, the 640x480 picture is
// written to <file> (overwritten frame by frame, so the file holds the last full frame).
// +fb_frames=<n>: stop writing after n frames (default: no limit).  Without +fb_ppm nothing
// happens.  In the Verilator benches the pixel clock is the system clock.
module fb_capture (
    input wire        clk,
    input wire [23:0] rgb,
    input wire        de,
    input wire        vs     // active low
);
    reg [23:0] img [0:640*480-1];
    reg [1023:0] fname;
    reg        on = 0;
    integer    limit = -1, frames = 0, x = 0, y = 0, n = 0, fd, i;
    reg        de_q = 0, vs_q = 1;

    initial begin
        if ($value$plusargs("fb_ppm=%s", fname)) on = 1;
        if (!$value$plusargs("fb_frames=%d", limit)) limit = -1;
    end

    always @(posedge clk) if (on) begin
        de_q <= de;
        vs_q <= vs;
        if (de) begin
            if (x < 640 && y < 480) img[y * 640 + x] = rgb;
            x = x + 1;
            n = n + 1;
        end
        if (de_q && !de) begin x = 0; y = y + 1; end
        if (vs_q && !vs) begin                  // vsync start: the frame is complete
            if (n == 640 * 480 && (limit < 0 || frames < limit)) begin
                fd = $fopen(fname, "wb");
                $fwrite(fd, "P6\n640 480\n255\n");
                for (i = 0; i < 640 * 480; i = i + 1)
                    $fwrite(fd, "%c%c%c", img[i][23:16], img[i][15:8], img[i][7:0]);
                $fclose(fd);
                frames = frames + 1;
                $display("[fb_capture] frame %0d written to %0s", frames, fname);
            end
            x = 0; y = 0; n = 0;
        end
    end
endmodule
