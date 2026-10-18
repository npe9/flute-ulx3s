#!/usr/bin/env python3
"""Logic-depth census of a Yosys ECP5 JSON netlist (pre-P&R).

Computes, for every sequential endpoint pin (TRELLIS_FF D/CE/LSR, DP16KD
inputs, MULT18X18D inputs, top-level outputs), the longest combinational
path in LUT levels from any sequential source (FF Q, BRAM DO, MULT P,
top-level inputs).  Prints a depth histogram and the deepest endpoints,
grouped by register name (bits merged).

Why: P&R takes ~40 min on this machine; this takes seconds and shows the
STRUCTURE (how many endpoints are deep, and which cones) so a BSV edit can
be judged before committing to a P&R run.  Depth is a proxy: ECP5 routing
dominates (~70-80% of path delay here), so use it for relative judgments
on the same netlist family, not for absolute MHz.

Usage: depth_census.py build/timing-exp/rld4.json [--top N] [--min-depth D]
       [--grep PATTERN]   (only count endpoints matching PATTERN)
"""
import json, sys, re, collections, argparse

SEQ_CELLS = {"TRELLIS_FF", "DP16KD", "MULT18X18D", "TRELLIS_IO", "EHXPLLL",
             "OSCG", "ODDRX1F", "IDDRX1F", "TRELLIS_DPR16X4", "DPR16X4C",
             "PDPW16KD", "USRMCLK", "DTR", "TRELLIS_SLICE"}
# comb cells: LUT4, CCU2C, PFUMX, L6MUX21, TRELLIS_COMB, ...
COMB_WEIGHT = {"LUT4": 1, "CCU2C": 0.25, "PFUMX": 0.4, "L6MUX21": 0.4,
               "TRELLIS_COMB": 1}
# CCU2C is a carry-chain cell: ~0.1-0.2 ns per cell vs ~0.5 ns + routing per
# LUT level, so weight it as a quarter level.  Override with --ccu.

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--min-depth", type=float, default=0)
    ap.add_argument("--grep", default=None)
    ap.add_argument("--trace", default=None, help="regex: trace the deepest path to the first endpoint matching this instead of the overall deepest")
    ap.add_argument("--deep", type=float, default=15, help="threshold for the per-module table")
    ap.add_argument("--ccu", type=float, default=None, help="weight of a CCU2C cell")
    args = ap.parse_args()
    if args.ccu is not None:
        COMB_WEIGHT["CCU2C"] = args.ccu

    d = json.load(open(args.json))
    mods = d["modules"]
    # pick the top (non-blackbox module with most cells)
    top = max(mods.items(), key=lambda kv: len(kv[1].get("cells", {})))[1]
    cells = top["cells"]
    # net id -> list of (cell, port) consumers; net id -> driver (cell, port)
    drivers = {}
    consumers = collections.defaultdict(list)
    comb_cells = {}
    seq_src_nets = set()
    seq_sink_pins = []   # (net, cellname, port)
    for cname, c in cells.items():
        t = c["type"]
        dirs = c.get("port_directions", {})
        is_seq = t in SEQ_CELLS or t.startswith("DP16") or t.startswith("MULT")
        is_comb = t in COMB_WEIGHT
        for port, bits in c["connections"].items():
            dirn = dirs.get(port, "input")
            for b in bits:
                if not isinstance(b, int):
                    continue
                if dirn == "output":
                    drivers[b] = (cname, port)
                    if is_seq:
                        seq_src_nets.add(b)
                else:
                    consumers[b].append((cname, port))
                    if is_seq:
                        seq_sink_pins.append((b, cname, port))
        if is_comb:
            comb_cells[cname] = c
    # top-level ports
    for pname, p in top.get("ports", {}).items():
        for b in p["bits"]:
            if not isinstance(b, int):
                continue
            if p["direction"] == "input":
                seq_src_nets.add(b)
                drivers.setdefault(b, ("$port:" + pname, "out"))
            else:
                seq_sink_pins.append((b, "$port:" + pname, "in"))

    # depth(net) = longest weighted comb depth from a seq source to this net
    sys.setrecursionlimit(1000000)
    memo = {}
    onstack = set()
    def depth(net):
        if net in memo:
            return memo[net]
        if net in seq_src_nets or net not in drivers:
            memo[net] = (0.0, None)
            return memo[net]
        if net in onstack:          # comb loop (shouldn't happen) -> cut
            memo[net] = (0.0, None)
            return memo[net]
        onstack.add(net)
        cname, _ = drivers[net]
        c = cells.get(cname)
        if c is None or c["type"] not in COMB_WEIGHT:
            memo[net] = (0.0, None)
            onstack.discard(net)
            return memo[net]
        w = COMB_WEIGHT[c["type"]]
        best = (0.0, None)
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            if dirs.get(port, "input") == "output":
                continue
            for b in bits:
                if isinstance(b, int):
                    dd = depth(b)
                    if dd[0] > best[0] or best[1] is None:
                        best = (dd[0], b)
        memo[net] = (best[0] + w, best[1])
        onstack.discard(net)
        return memo[net]

    def regname(cname):
        # strip bit suffixes / yosys mangling to group endpoints
        n = re.sub(r"\$_?TRELLIS_FF_Q.*$", "", cname)
        n = re.sub(r"_TRELLIS_FF_Q.*$", "", n)
        n = re.sub(r"\[\d+\]$", "", n)
        n = re.sub(r"_\d+$", "", n)
        return n

    pat = re.compile(args.grep) if args.grep else None
    results = []
    for net, cname, port in seq_sink_pins:
        if pat and not pat.search(cname):
            continue
        dd = depth(net)
        results.append((dd[0], cname, port, net))
    results.sort(reverse=True)
    hist = collections.Counter(int(r[0]) for r in results)
    total = len(results)
    print(f"endpoint pins: {total}")
    print("depth(LUT levels) : endpoints  (cumulative share >= depth)")
    cum = 0
    for k in sorted(hist, reverse=True):
        cum += hist[k]
        print(f"  {k:3d} : {hist[k]:6d}   ({100.0*cum/total:5.1f}% >= {k})")
    # per-module share of deep endpoints (>= --deep levels)
    deep_thr = args.deep
    mod = collections.Counter(); modall = collections.Counter(); modmax = {}
    for dep, cname, port, net in results:
        parts = cname.split(".")
        key = ".".join(parts[:5]) if len(parts) > 5 else ".".join(parts[:-1])
        key = re.sub(r"_TRELLIS.*$", "", key)
        modall[key] += 1
        if dep >= deep_thr:
            mod[key] += 1
        modmax[key] = max(modmax.get(key, 0), dep)
    print(f"\nendpoints with depth >= {deep_thr} by module (count / all, max depth):")
    for key, n in mod.most_common(25):
        print(f"  {n:6d} / {modall[key]:6d}  max {modmax[key]:5.1f}  {key}")
    # group deepest endpoints by register name
    groups = collections.OrderedDict()
    for dep, cname, port, net in results:
        if dep < args.min_depth:
            break
        key = (regname(cname), port)
        if key not in groups:
            groups[key] = [dep, 0]
        groups[key][1] += 1
        if len(groups) > args.top * 4:
            break
    print(f"\ndeepest endpoint groups (max depth, #bits, register.port):")
    for i, (key, v) in enumerate(groups.items()):
        if i >= args.top:
            break
        print(f"  {v[0]:5.1f}  x{v[1]:<4d} {key[0]}.{key[1]}")
    # trace the single deepest path (or the deepest matching --trace)
    pick = results[0] if results else None
    if args.trace:
        tp = re.compile(args.trace)
        pick = next(((d, c, p, n) for d, c, p, n in results if tp.search(c + "." + p)), None)
    if pick:
        dep, cname, port, net = pick
        print(f"\ndeepest path to {cname}.{port} (depth {dep}):")
        n = net
        steps = 0
        while n is not None and steps < 200:
            drv = drivers.get(n, ("?", "?"))
            c = cells.get(drv[0])
            t = c["type"] if c else "port/none"
            print(f"   {memo.get(n, (0, None))[0]:5.1f}  {t:12s} {drv[0]}")
            n = memo.get(n, (0, None))[1]
            steps += 1

if __name__ == "__main__":
    main()
