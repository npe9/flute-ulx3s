#!/usr/bin/expect -f
# Expect wrapper around repl_interact.py to exercise the ULX3S HolyC REPL.
# Waits for the real boot prompt (after "DMesg;" in the banner) before sending.

set timeout 300
set image [lindex $argv 0]
set cmds [lrange $argv 1 end]
set port "/dev/cu.usbserial-120001"
set baud 625000

log_file -noappend /tmp/repl_expect2.log

spawn sh -c "make program && python3 scripts/repl_interact.py $image -p $port -b $baud"

# Wait until the boot banner finishes and the REPL prints its first prompt.
expect "DMesg;\r\n\r\n> "

foreach cmd $cmds {
    send "$cmd\r"
    # Wait for the next prompt after the command has executed.
    expect -timeout 60 "\r\n> "
}

# Send an empty line and one more prompt to confirm liveness, then quit.
send "\r"
expect -timeout 10 "\r\n> "
send "\x1d"
expect eof
