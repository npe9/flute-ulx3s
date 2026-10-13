#!/usr/bin/expect -f
# Expect wrapper around repl_interact.py to exercise the ULX3S HolyC REPL.
# Usage: expect scripts/repl_expect.tcl <image> [cmd1 cmd2 ...]

set timeout 300
set image [lindex $argv 0]
set cmds [lrange $argv 1 end]
set port "/dev/cu.usbserial-120001"
set baud 625000

spawn sh -c "make program && python3 scripts/repl_interact.py $image -p $port -b $baud"

expect "entering interactive mode"
sleep 2

# Wait for the first REPL prompt.
expect "\n> "

foreach cmd $cmds {
    send "$cmd\r"
    # Wait for the command echo, then the next prompt.
    expect -timeout 60 "$cmd"
    expect -timeout 60 "\n> "
}

# Send an empty line to see a clean prompt, then quit.
send "\r"
expect -timeout 10 "\n> "
send "\x1d"
expect eof
