# nextpnr-ecp5 --pre-place script: split the LFE5U-85's four EBR rows (y = 22, 46, 70, 82;
# 52 DP16KD sites each) between the CPU and the HDMI framebuffer.
#
#   BTB RAMs:                                         row 22 (next to fetch)
#   other CPU / SoC RAMs (caches, register file, ...): rows 22 and 46 (top)
#   framebuffer (video.fb*: 76 RAMs, read muxes, fbq): rows 70 and 82 (bottom)
#   palette (video.pal): free
#
# The CPU's branch-predictor loop (BTB RAM -> predict -> imem_req_addr -> BTB RAM address)
# runs at ~55 MHz only with the BTB in the row next to fetch (y ~ 9-26).  Left free, the
# framebuffer (pulled to the top-left by the GPDI pins) took that row, and with only the
# framebuffer constrained the BTB still drifted to the bottom rows: two ~5 ns cross-die hops
# in one cycle, 43-47 MHz.  Pinning the L1 cache RAMs to row 22 as well is worse: they take
# the sites next to fetch and push the BTB out to x ~ 69.  The framebuffer's system port is
# registered on both sides (src/Video_DVI.v) and its pixel side runs at 25 MHz, so the trip
# down costs it nothing.
ctx.createRectangularRegion("ebr_top", 0, 0, 125, 58)
ctx.createRectangularRegion("ebr_fetch", 0, 0, 125, 34)    # row 22 only
ctx.createRectangularRegion("ebr_bottom", 0, 59, 125, 94)
n = {"btb": 0, "soc": 0, "fb": 0}
for name, cell in ctx.cells:
    if name.startswith("video.fb"):
        # the framebuffer RAMs, their lane read muxes and fbq (one register stage after the
        # mux): the long trip up is then fbq -> rb_rdata, register to register
        ctx.constrainCellToRegion(name, "ebr_bottom")
        n["fb"] += 1
    elif cell.type == "DP16KD" and "stageF_branch_predictor" in name:
        ctx.constrainCellToRegion(name, "ebr_fetch")
        n["btb"] += 1
    elif cell.type == "DP16KD" and not name.startswith("video."):
        ctx.constrainCellToRegion(name, "ebr_top")
        n["soc"] += 1
print("video_floorplan: %d BTB RAMs in row 22, %d SoC RAMs in rows 22/46, "
      "%d framebuffer cells in rows 70/82" % (n["btb"], n["soc"], n["fb"]))
