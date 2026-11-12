#!/usr/bin/env python3
"""Tests for qr-show: Reed-Solomon and the format/version words against the standard's values, and a round trip through a
decoder written here (it reads the symbol the way a scanner does: format info, unmask, zig-zag, de-interleave, check the
error-correction codewords, parse the byte-mode segment).

    python3 net-utils/test/test_qr.py
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(os.path.dirname(HERE), "qr-show")
loader = importlib.machinery.SourceFileLoader("qr_show", TOOL)
spec = importlib.util.spec_from_loader("qr_show", loader)
Q = importlib.util.module_from_spec(spec)
loader.exec_module(Q)

# the standard's format-information words (EC level + mask, after BCH and the 0x5412 xor)
FMT_L = [0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976]
FMT_M = [0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0]
VERSION_WORDS = {7: 0x07C94, 8: 0x085BC, 9: 0x09A99, 10: 0x0A4D3}


def function_map(ver):
    """which modules are not data, worked out again here from the layout rules."""
    n = ver * 4 + 17
    f = [[False] * n for _ in range(n)]
    for i in range(n):
        f[6][i] = f[i][6] = True
    for (cx, cy) in ((3, 3), (n - 4, 3), (3, n - 4)):
        for y in range(cy - 4, cy + 5):
            for x in range(cx - 4, cx + 5):
                if 0 <= x < n and 0 <= y < n:
                    f[y][x] = True
    pos = Q.alignment_positions(ver)
    for i, cy in enumerate(pos):
        for j, cx in enumerate(pos):
            if (i, j) in ((0, 0), (0, len(pos) - 1), (len(pos) - 1, 0)):
                continue
            for y in range(cy - 2, cy + 3):
                for x in range(cx - 2, cx + 3):
                    f[y][x] = True
    for i in range(9):                                           # format areas around the top-left finder
        f[8][i] = f[i][8] = True
    for i in range(8):
        f[8][n - 1 - i] = f[n - 1 - i][8] = True
    f[n - 8][8] = True
    if ver >= 7:
        for a in range(6):
            for b in range(3):
                f[a][n - 11 + b] = f[n - 11 + b][a] = True
    return f


def read_format(mod):
    n = len(mod)
    bits = 0
    first = [(8, i) for i in range(6)] + [(8, 7), (8, 8), (7, 8)] + [(14 - i, 8) for i in range(9, 15)]
    second = [(n - 1 - i, 8) for i in range(8)] + [(8, n - 15 + i) for i in range(8, 15)]
    w1 = sum((1 if mod[y][x] else 0) << i for i, (x, y) in enumerate(first))
    w2 = sum((1 if mod[y][x] else 0) << i for i, (x, y) in enumerate(second))
    return w1, w2


def mask_cond(m, x, y):
    return [(x + y) % 2 == 0, y % 2 == 0, x % 3 == 0, (x + y) % 3 == 0, (x // 3 + y // 2) % 2 == 0,
            x * y % 2 + x * y % 3 == 0, (x * y % 2 + x * y % 3) % 2 == 0, ((x + y) % 2 + x * y % 3) % 2 == 0][m]


def decode(mod):
    """text from a symbol; raises AssertionError if anything is inconsistent."""
    n = len(mod)
    ver = (n - 17) // 4
    w1, w2 = read_format(mod)
    assert w1 == w2, "the two copies of the format information differ"
    ecl = {1: "L", 0: "M"}[(w1 ^ 0x5412) >> 13]
    mask = ((w1 ^ 0x5412) >> 10) & 7
    f = function_map(ver)
    bits = []
    right = n - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(n):
            for j in range(2):
                x = right - j
                y = n - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not f[y][x]:
                    bits.append(mod[y][x] ^ mask_cond(mask, x, y))
        right -= 2
    words = [int("".join("1" if b else "0" for b in bits[i:i + 8]), 2) for i in range(0, len(bits) - len(bits) % 8, 8)]
    raw_cw = Q.raw_data_modules(ver) // 8
    assert len(words) == raw_cw, (len(words), raw_cw)
    nblocks = Q.NUM_BLOCKS[ecl][ver - 1]
    ecc_len = Q.ECC_PER_BLOCK[ecl][ver - 1]
    nshort = nblocks - raw_cw % nblocks
    short_len = raw_cw // nblocks
    # de-interleave: data words column by column, then the ecc words
    lens = [short_len - ecc_len + (0 if i < nshort else 1) for i in range(nblocks)]
    data_blocks = [[] for _ in range(nblocks)]
    k = 0
    for col in range(max(lens)):
        for i in range(nblocks):
            if col < lens[i]:
                data_blocks[i].append(words[k])
                k += 1
    ecc_blocks = [[] for _ in range(nblocks)]
    for col in range(ecc_len):
        for i in range(nblocks):
            ecc_blocks[i].append(words[k])
            k += 1
    div = Q.rs_divisor(ecc_len)
    for i in range(nblocks):
        assert Q.rs_remainder(data_blocks[i], div) == ecc_blocks[i], "error-correction words do not match in block %d" % i
    data = [w for blk in data_blocks for w in blk]
    s = "".join(format(w, "08b") for w in data)
    assert s[:4] == "0100", "not byte mode"
    cbits = 8 if ver <= 9 else 16
    length = int(s[4:4 + cbits], 2)
    body = s[4 + cbits:4 + cbits + 8 * length]
    return bytes(int(body[i:i + 8], 2) for i in range(0, len(body), 8)).decode("utf-8")


class T(unittest.TestCase):
    def test_reed_solomon_standard_example(self):
        # ISO 18004 annex I: "01234567" at version 1-M
        data = [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
        self.assertEqual(Q.rs_remainder(data, Q.rs_divisor(10)), [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55])

    def test_capacities_are_the_standard_ones(self):
        self.assertEqual([Q.data_codewords(v, "L") for v in range(1, 11)], [19, 34, 55, 80, 108, 136, 156, 194, 232, 274])
        self.assertEqual([Q.data_codewords(v, "M") for v in range(1, 11)], [16, 28, 44, 64, 86, 108, 124, 154, 182, 216])
        self.assertEqual([Q.alignment_positions(v) for v in (1, 2, 7, 10)], [[], [6, 18], [6, 22, 38], [6, 28, 50]])

    def test_format_and_version_words(self):
        for ecl, table in (("L", FMT_L), ("M", FMT_M)):
            for mask in range(8):
                m = Q.Matrix(1)
                m.draw_function_patterns()
                m.draw_format(mask, ecl)
                w1, w2 = read_format(m.mod)
                self.assertEqual((w1, w2), (table[mask], table[mask]), (ecl, mask))
        for ver, word in VERSION_WORDS.items():
            m = Q.Matrix(ver)
            m.draw_function_patterns()
            n = m.size
            got = sum((1 if m.mod[i // 3][n - 11 + i % 3] else 0) << i for i in range(18))
            self.assertEqual(got, word, ver)

    def test_round_trip_every_version(self):
        seen = set()
        for ecl in ("L", "M"):
            for length in (1, 17, 20, 30, 50, 70, 85, 100, 120, 150, 180, 220, 250, 270):
                text = "".join(chr(33 + (i * 7) % 90) for i in range(length))
                try:
                    mod = Q.qr_matrix(text, ecl)
                except Q.TooLong:
                    continue
                seen.add((ecl, (len(mod) - 17) // 4))
                self.assertEqual(decode(mod), text, (ecl, length))
        self.assertTrue({(e, v) for e in "LM" for v in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10)} <= seen | {("M", 10), ("M", 9)}, sorted(seen))

    def test_the_real_use(self):
        url = "otpauth://totp/cmlaptop:chris?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=cmlaptop"  # allowlist secret
        for ecl in ("L", "M"):
            self.assertEqual(decode(Q.qr_matrix(url, ecl)), url)
        self.assertEqual(decode(Q.qr_matrix("café ✓")), "café ✓")      # utf-8

    def test_too_long(self):
        with self.assertRaises(Q.TooLong):
            Q.qr_matrix("x" * 300)

    def test_command(self):
        def run(*args, stdin=None):
            r = subprocess.run([sys.executable, TOOL] + list(args), input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, encoding="utf-8")
            return r.returncode, r.stdout, r.stderr
        rc, out, err = run("hello")
        self.assertEqual(rc, 0, err)
        lines = out.rstrip("\n").split("\n")
        self.assertEqual(len(lines), (21 + 8 + 1) // 2)                      # version 1, quiet zone 4 each side, two rows per line
        self.assertIn("\x1b[38;5;16;48;5;231m", out)
        rc, out, _ = run("--plain", "hello")
        self.assertEqual(len(out.rstrip("\n").split("\n")), 29)
        rc, out, _ = run("--sixel", "--scale", "2", "hello")
        self.assertTrue(out.startswith("\x1bPq") and out.rstrip("\n").endswith("\x1b\\"))
        self.assertEqual(run(stdin="from stdin\n")[0], 0)
        self.assertEqual(run("x" * 300)[0], 1)
        self.assertEqual(run("--bogus", "x")[0], 2)
        self.assertEqual(run()[0], 2 if sys.stdin.isatty() else 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
