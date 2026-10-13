# OpenOCD script: load the HolyC REPL blob into SDRAM and run it.
# Intended to be sourced after init, e.g.:
#   openocd -f ulx3s_ft231x.ocd -f riscv.ocd -c "set IMAGE templeos/build/ulx3s_repl.blob.bin; source openocd/load_repl.tcl"

if {![info exists IMAGE]} {
    set IMAGE "templeos/build/ulx3s_repl.blob.bin"
}
set LOAD_ADDR 0x80000000

puts "Halting hart..."
halt

puts "Loading $IMAGE to $LOAD_ADDR ..."
load_image $IMAGE $LOAD_ADDR bin

puts "Setting PC to $LOAD_ADDR ..."
reg pc $LOAD_ADDR

puts "Resuming..."
resume
puts "Done."
