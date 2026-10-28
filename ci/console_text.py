#!/usr/bin/env python3
"""Print the UART console text of a Bluesim Repl_Boot_Tb log (decoded from its '[tb] txc XX' lines).

The TB's direct echo of each character is interleaved with its own log lines, so the console text is
never contiguous in the raw log; grep this script's output instead.
"""
import re
import sys

log = open(sys.argv[1], errors="replace").read()
sys.stdout.write("".join(chr(int(h, 16)) for h in re.findall(r"^\[tb\] txc ([0-9a-f]{2})", log, re.M)))
