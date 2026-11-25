# sw/game2d/portraits.py: the caricature sprites (32x32, a 15-colour bank each) of Proof
# Obligation's bosses, drawn by feature (hair, glasses, beard, clothes) with the Wikimedia Commons
# photographs in CREDITS as reference; the sprites carry those photographs' licences.
#   python3 portraits.py --c proof_portraits.c     regenerate the C source
#   python3 portraits.py preview.png               an 8x preview (needs Pillow)
import sys

W = H = 32
# colour indices shared by every portrait (the bank's palette differs per boss)
O, SK, SH, HA, HS, GL, LE, EY, CL, CS, CA, EM, MO, X1, X2 = range(1, 16)

def canvas(): return [[0] * W for _ in range(H)]
def put(g, r, c, v):
    if 0 <= r < H and 0 <= c < W: g[r][c] = v
def rect(g, r0, c0, r1, c1, v):
    for r in range(r0, r1 + 1):
        for c in range(c0, c1 + 1): put(g, r, c, v)
def ell(g, cr, cc, rr, rc, v, only=None):
    for r in range(H):
        for c in range(W):
            if ((r - cr) / rr) ** 2 + ((c - cc) / rc) ** 2 <= 1.0 and (only is None or g[r][c] in only):
                g[r][c] = v
def row(g, r, c0, s):                           # a literal run: chars index the colour table
    for i, ch in enumerate(s):
        if ch != ' ': put(g, r, c0 + i, int(ch, 16) if ch != '.' else 0)
def outline(g):                                 # a dark edge around everything opaque
    e = [[g[r][c] for c in range(W)] for r in range(H)]
    for r in range(H):
        for c in range(W):
            if g[r][c] == 0 and any(0 <= r + dr < H and 0 <= c + dc < W and g[r + dr][c + dc] not in (0, O)
                                    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                e[r][c] = O
    return e

def face(g, top=2, bot=17, half=8, cc=15.5):    # the head: skin oval
    ell(g, (top + bot) / 2, cc, (bot - top) / 2 + 0.5, half + 0.4, SK)

def body(g, r0, clothes, collar=None):          # shoulders and chest, arms at the sides
    for r in range(r0, H):
        w = min(13, 9 + (r - r0))
        rect(g, r, 16 - w, r, 15 + w, CL)
    for r in range(r0 + 2, H):                  # arms: a shade line
        put(g, r, 16 - min(13, 9 + (r - r0)) + 2, CS); put(g, r, 15 + min(13, 9 + (r - r0)) - 2, CS)
    clothes(g, r0)

def eyes_glasses(g, r, l0=9, r0=17, w=6, h=3, thick=False):
    for c0 in (l0, r0):
        rect(g, r, c0, r + h - 1, c0 + w - 1, LE)
        for c in range(c0, c0 + w): put(g, r, c, GL); put(g, r + h - 1, c, GL) if thick else None
        for rr in range(r, r + h): put(g, rr, c0, GL); put(g, rr, c0 + w - 1, GL)
        if not thick:
            for c in range(c0, c0 + w): put(g, r + h - 1, c, GL)
        put(g, r + 1, c0 + w // 2, EY); put(g, r + 1, c0 + w // 2 - 1, EY)
    rect(g, r, l0 + w, r, r0 - 1, GL)                 # the bridge

def beard(g, r0, r1, cc=15.5, half=8, taper=0.6):
    for r in range(r0, r1 + 1):
        w = half - max(0, (r - r0 - 2)) * taper
        for c in range(W):
            if abs(c + 0.5 - cc - 0.5) <= w and g[r][c] in (0, SK, SH): g[r][c] = HA

# ---------------------------------------------------------------- the six
def mccarthy():
    g = canvas(); body(g, 20, plaid)
    face(g, 3, 17, 8)
    ell(g, 3, 15.5, 3, 9, HA, only=(0, SK)); ell(g, 2, 15.5, 2.5, 6, SK, only=(HA,))   # white fluff, bald crown
    for r in range(3, 10): put(g, r, 7, HA); put(g, r, 24, HA); put(g, r, 6, HA if r > 4 else 0); put(g, r, 25, HA if r > 4 else 0)
    row(g, 6, 9, "44 4   4 44"); row(g, 6, 17, "4 44 4")
    eyes_glasses(g, 7, 8, 17, 7, 4, thick=True)       # the heavy black frames
    rect(g, 7, 8, 7, 23, GL); rect(g, 10, 8, 10, 23, GL)
    beard(g, 11, 21, half=8.5, taper=0.55)
    row(g, 11, 14, "22 2"); row(g, 12, 12, "55555555"); row(g, 13, 13, "1dd1d1")   # moustache, open mouth
    row(g, 14, 14, "5555")
    return g
def plaid(g, r0):
    for r in range(r0, H):
        for c in range(W):
            if g[r][c] == CL and (c % 4 == 0 or r % 4 == 0): g[r][c] = CA
    row(g, r0, 11, "bbb      bbb"); row(g, r0 + 1, 12, "bbb    bbb"); row(g, r0 + 2, 13, "bb    bb")

def dijkstra():
    g = canvas(); body(g, 20, vest)
    face(g, 3, 17, 7.5)
    ell(g, 3.5, 15, 3.2, 8.6, HA, only=(0, SK)); ell(g, 4.5, 16.5, 2.0, 6, SK, only=(HA,))  # swept grey hair
    row(g, 1, 11, "44455"); row(g, 2, 9, "4454455544")
    for r in range(4, 11): put(g, r, 8, HA); put(g, r, 23, HS)
    put(g, 9, 7, SK); put(g, 10, 7, SK); put(g, 9, 24, SK)                             # ears
    row(g, 6, 10, "555   55 555")
    eyes_glasses(g, 8, 9, 17, 6, 3)                   # thin wire frames, set low
    beard(g, 12, 20, half=7.6, taper=0.65)
    rect(g, 12, 9, 12, 22, SH)
    row(g, 12, 13, "55555 "); row(g, 13, 14, "1dd1"); row(g, 11, 15, "33")
    return g
def vest(g, r0):
    for r in range(r0, H):                      # check shirt sleeves, rust V-neck vest
        for c in range(W):
            if g[r][c] == CL and (c < 9 or c > 22): g[r][c] = CA if (r + c) % 3 == 0 else CA - 0 if False else CA
    for r in range(r0, H):
        for c in range(W):
            if g[r][c] == CA and (r + c) % 2 == 0: g[r][c] = X1
    for k in range(6):
        row(g, r0 + k, 13 - k // 2, "b" + "b" * (2 + (5 - k) // 2) if False else "")
    row(g, r0, 12, "bbbbbbbb"); row(g, r0 + 1, 13, "bbbbbb"); row(g, r0 + 2, 14, "bbbb"); row(g, r0 + 3, 15, "bb")

def hoare():
    g = canvas(); body(g, 20, jacket)
    face(g, 2, 17, 8)
    row(g, 1, 11, "4  4 44"); row(g, 2, 10, "4445 45444")                              # wispy white top
    for r in range(4, 11): put(g, r, 7, HA); put(g, r, 24, HA); put(g, r, 8, HS if r > 5 else SK)
    put(g, 9, 6, SK); put(g, 10, 6, SK); put(g, 9, 25, SK); put(g, 10, 25, SK)       # ears
    row(g, 6, 10, "444   44  444")
    eyes_glasses(g, 7, 9, 17, 6, 3)
    beard(g, 13, 19, half=7, taper=0.7)
    row(g, 12, 13, "3dddd3"); row(g, 11, 15, "33")                                    # a smile
    rect(g, 13, 10, 13, 21, HA)
    return g
def jacket(g, r0):
    for r in range(r0, H):
        for c in range(W):
            if g[r][c] == CL and abs(c - 15.5) < 3 + (r - r0) * 0.4: g[r][c] = CA      # shirt in the V
    row(g, r0, 13, "bbbbbb"); row(g, r0 + 1, 14, "b55b")

def lamport():
    g = canvas(); body(g, 21, tshirt)
    face(g, 4, 17, 7)
    ell(g, 7, 15.5, 7.5, 10.5, HA, only=(0,)); ell(g, 3, 15.5, 2.6, 8, HA, only=(0, SK))   # a grey mane
    for r in range(2, 15):
        for c in (5, 6, 25, 26):
            if g[r][c] == HA and (r * 3 + c) % 7 == 0: g[r][c] = HS
    row(g, 4, 10, "455445544554")
    eyes_glasses(g, 8, 9, 17, 6, 3)
    beard(g, 12, 21, half=8, taper=0.55)
    for r in range(12, 22):
        for c in range(W):
            if g[r][c] == HA and (r * 5 + c * 3) % 11 == 0: g[r][c] = HS
    row(g, 12, 13, "555555"); row(g, 13, 14, "1dd1"); row(g, 11, 15, "33")
    return g
def tshirt(g, r0):
    row(g, r0, 13, "55555"); row(g, r0 + 1, 14, "555")
    row(g, r0 + 6, 10, "aaa a aa a")                                                  # a print

def appel():
    g = canvas(); body(g, 19, sweater)
    face(g, 3, 16, 7)
    ell(g, 3.5, 15.5, 3.8, 9, HA, only=(0, SK)); ell(g, 5.2, 15.5, 1.6, 6.5, SK, only=(HA,))   # dark curls
    for r in range(0, 8):
        for c in range(W):
            if g[r][c] == HA and (r + c) % 3 == 0: g[r][c] = HS
    for r in range(5, 12): put(g, r, 7, HA); put(g, r, 24, HA)
    row(g, 6, 9, "4444   4444")
    eyes_glasses(g, 7, 9, 17, 6, 3)
    beard(g, 11, 18, half=6.8, taper=0.7)
    row(g, 11, 13, "4444 4"); row(g, 12, 14, "dddd"); row(g, 10, 15, "33")
    return g
def sweater(g, r0):
    for r in range(r0 + 3, H):
        for c in range(W):
            if g[r][c] in (CL, CS):
                if r in (r0 + 4, r0 + 5, r0 + 8, r0 + 9) and c % 2 == 0: g[r][c] = CA
                if r == r0 + 11 and (c + r) % 4 < 2: g[r][c] = CA
    row(g, r0, 13, "bbbbbb"); row(g, r0 + 1, 14, "bbbb")
    rect(g, r0 + 6, 19, r0 + 8, 22, X1)                                               # the name badge

def harper():
    g = canvas(); body(g, 20, fleece)
    face(g, 5, 18, 8.6)
    ell(g, 4, 15.5, 4, 9.2, CA, only=(0, SK)); rect(g, 5, 6, 6, 25, CA)               # the cap
    rect(g, 7, 7, 7, 26, CA); rect(g, 8, 9, 8, 27, CS)                                 # its bill
    row(g, 2, 14, "ff"); row(g, 3, 14, "ff")                    # the logo
    rect(g, 10, 8, 10, 23, GL)                                                         # wraparound sunglasses
    rect(g, 11, 9, 11, 14, LE); rect(g, 11, 17, 11, 22, LE); put(g, 11, 8, GL); put(g, 11, 23, GL)
    row(g, 10, 10, "77"); row(g, 10, 18, "77")
    row(g, 14, 12, "3dddddd3"); row(g, 15, 13, "3dddd3")                                # a broad smile
    for r in (12, 13, 14): put(g, r, 7, SH); put(g, r, 24, SH)
    return g
def fleece(g, r0):
    for r in range(r0, H):
        for c in range(W):
            if g[r][c] == CL and abs(c - 15.5) < 2.5 + (r - r0) * 0.35: g[r][c] = X1      # blue shirt
    row(g, r0, 12, "aa      aa")
    for r in range(r0 + 1, H): put(g, r, 5, CA); put(g, r, 26, CA)                     # backpack straps

PORTRAITS = [
    ("McCarthy", mccarthy, [0x181818, 0xE8B49C, 0xB88068, 0xF2F2F2, 0xB0B4C0, 0x101010, 0x8090B0, 0x202020,
                            0x7880B0, 0x4C5490, 0xF0F0F8, 0xC0FF60, 0x501818, 0, 0]),
    ("Dijkstra", dijkstra, [0x141008, 0xE0A080, 0xB07058, 0x9C9480, 0x605848, 0xB0A890, 0xE8E0D0, 0x202020,
                            0xA84020, 0xF0ECE0, 0xF4F0E8, 0xA0D0FF, 0x501810, 0xC0B8A8, 0]),
    ("Hoare",    hoare,    [0x181410, 0xF0C4AC, 0xC89078, 0xF4F0EC, 0xC0B8B0, 0x484040, 0xE8E4E0, 0x282020,
                            0xC8B494, 0xF4F0F0, 0xF8F8F8, 0xFFD080, 0x804040, 0, 0]),
    ("Lamport",  lamport,  [0x181818, 0xD8A088, 0xA87060, 0xC8C8C8, 0x808080, 0x383838, 0xE0E0E0, 0x202020,
                            0xE8ECF4, 0xC0C4D0, 0x4060A0, 0xE0B0FF, 0x603030, 0, 0]),
    ("Appel",    appel,    [0x101010, 0xD89878, 0xA86850, 0x241C18, 0x4C3C30, 0x707070, 0xE0E0E0, 0x202020,
                            0x506048, 0x2C3828, 0xE8E8E0, 0x80FFF0, 0x803030, 0xF8F8F8, 0]),
    ("Harper",   harper,   [0x101010, 0xE0A890, 0xB07860, 0, 0, 0x2C2C34, 0x485868, 0x202020,
                            0x384050, 0x202838, 0x283040, 0xFFB0A0, 0x702828, 0x2050C0, 0xD02020]),
]
# Harper's cap is CA (index 11): dark navy; the B logo X2 is red (index 15 -> 'e' in rows is 14?)

def grid(fn):
    g = outline(fn())
    return g

def to_rows(g): return ["".join("0123456789abcdef"[v] for v in r) for r in g]

def main():
    if sys.argv[1] == "--c":
        print_c(sys.argv[2])
    else:
        from PIL import Image
        S = 8
        out = Image.new("RGB", (len(PORTRAITS) * (W * S + 8), H * S), (40, 40, 60))
        for i, (n, fn, pal) in enumerate(PORTRAITS):
            g = grid(fn)
            for r in range(H):
                for c in range(W):
                    v = g[r][c]
                    if v:
                        col = pal[v - 1]
                        for y in range(S):
                            for x in range(S): out.putpixel((i * (W * S + 8) + c * S + x, r * S + y), (col >> 16, (col >> 8) & 255, col & 255))
        out.save(sys.argv[1])

CREDITS = [
    ("John McCarthy", "File:John McCarthy Stanford.jpg", "\"null0\"", "CC BY-SA 2.0"),
    ("Edsger W. Dijkstra", "File:Edsger Wybe Dijkstra.jpg", "Hamilton Richards", "CC BY-SA 3.0"),
    ("Tony Hoare", "File:Sir Tony Hoare IMG 5125.jpg", "Rama", "CC BY-SA 2.0 fr"),
    ("Leslie Lamport", "File:Leslie Lamport.jpg", "Leslie Lamport", "copyrighted free use"),
    ("Andrew Appel", "File:Andrew Apple (FloC 2006).jpg", "Dennis Hamilton", "CC BY 2.0"),
    ("Robert Harper", "File:Robert Harper in Tasmania.jpg", "RobertWHarper", "CC BY-SA 4.0"),
]
def print_c(path):
    L = []
    L.append("// sw/game2d/proof_portraits.c: caricature sprites (32x32, one 15-colour bank each) of six of")
    L.append("// Proof Obligation's bosses, drawn by feature from these Wikimedia Commons photographs.  Each")
    L.append("// sprite is a derivative of its photograph and is licensed under that photograph's licence:")
    for (n, f, a, lic) in CREDITS:
        L.append(f"//   {n}: commons.wikimedia.org/wiki/{f.replace(' ', '_')}, by {a}, {lic}")
    L.append("// The rest of the game is not derived from them.  Adam Chlipala has no freely licensed")
    L.append("// photograph on Commons, so that boss stays the original emblem figure (proof.c).")
    L.append("// Generated by sw/game2d/portraits.py (python3 portraits.py --c proof_portraits.c); each")
    L.append("// character is a colour index into the boss's bank (0 transparent).")
    L.append('#include "proof_int.h"')
    L.append("")
    L.append("const char *const portrait_rows [6][32] = {")
    for (n, fn, pal) in PORTRAITS:
        L.append(f"   {{  // {n}")
        for r in to_rows(grid(fn)): L.append(f'      "{r}",')
        L.append("   },")
    L.append("};")
    L.append("const uint32_t portrait_pal [6][15] = {")
    for (n, fn, pal) in PORTRAITS:
        L.append("   { " + ", ".join(f"0x{c:06X}" for c in pal) + " },   // " + n)
    L.append("};")
    open(path, "w").write("\n".join(L) + "\n")

if __name__ == "__main__":
    main()
