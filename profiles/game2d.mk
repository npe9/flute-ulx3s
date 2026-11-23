# profiles/game2d.mk: the 2D game console (notes/soc-family-plan.md; Phase 5 G2 in
# notes/ulx3s-peripherals-plan.md).  Same core and ISA as linux (S-mode and Sv32 stay: dropping
# them is a new core configuration with its own formal and gate, not worth it until area says
# so).  Drops the SoC devices a game does not use, to give the VDP their area:
#   INCLUDE_SPI2   the on-board ADC's SPI host (0xC000_A000)
#   INCLUDE_UART1  the ESP32 UART (0xC000_B000)
# Their pins stay in the top level, tied off (src/ULX3S_Top.bsv).
SOC_DROP := INCLUDE_SPI2 INCLUDE_UART1
# Adds the VDP (src/Vdp.v, sw/vdp/vdp.h): a 320x240 tile layer and 64 sprites, shown through
# video MODE 4, registers at 0xC002_0000 and VRAM at 0xC108_0000.
# Adds APU1 (src/Apu.v, sw/apu/apu.h): 8 voices (pulse, triangle, noise, sample) at 32 kHz into
# the jack through src/Audio.v, registers and wave RAM at 0xC004_0000.
SOC_ADD := -D INCLUDE_VDP -D INCLUDE_APU
