#!/usr/bin/env python3
"""
gen_crc.py -- generate parallel CRC-32 beat-update RTL (s2_crc32_gen.v)

CRC-32/IEEE-802.3 ("Ethernet" CRC; same polynomial PCIe uses for LCRC/ECRC):
  reflected polynomial 0xEDB88320, init 0xFFFFFFFF, final XOR 0xFFFFFFFF.
Golden reference = Python's zlib.crc32 (checked in selftest()).

What the generated modules compute, for a bus of N = W/8 byte lanes:

  crc_full = state after consuming ALL N lanes             (valid if keep = all ones)
  crc_part = state after consuming only the n valid lanes  (valid if keep is low-aligned)

Why this is cheap in hardware
-----------------------------
CRC is LINEAR over GF(2).  With T = "consume one zero byte":
    after N bytes:  s' = T^N * crc  XOR  sum_i T^(N-i) * byte_i
That is a plain XOR network (one big XOR per output bit, depth ~log2(#terms)),
NOT a chain of N byte-steps.

Partial last beat (n < N valid bytes): mask the dead lanes to zero, compute s'
as above (that is the state after N bytes with trailing zeros), then "unwind"
the (N-n) extra zero bytes using the INVERSE matrix T^-1.  The unwind is done
by binary decomposition: stage j applies (T^-1)^(2^j) when bit j of (N-n) is
set -> only log2(N)+1 small 32x32 XOR stages instead of N different matrices.
"""
import argparse
import random
import zlib

POLY_R = 0xEDB88320
MASK32 = 0xFFFFFFFF


# ---------------------------------------------------------------- GF(2) tools
def step8_zero(c):
    """T(c): shift the reflected CRC register 8 times with a zero input byte."""
    for _ in range(8):
        c = (c >> 1) ^ (POLY_R if (c & 1) else 0)
    return c


def mat_apply(M, v):
    r, i = 0, 0
    while v:
        if v & 1:
            r ^= M[i]
        v >>= 1
        i += 1
    return r


def mat_mul(A, B):
    """(A*B)(v) = A(B(v)); matrices stored as 32 column images."""
    return [mat_apply(A, B[i]) for i in range(32)]


def mat_pow(M, p):
    R = [1 << i for i in range(32)]
    base = M
    while p:
        if p & 1:
            R = mat_mul(base, R)
        base = mat_mul(base, base)
        p >>= 1
    return R


def mat_inv(M):
    n = 32
    rows = []
    for r in range(n):
        v = 0
        for i in range(n):
            if (M[i] >> r) & 1:
                v |= 1 << i
        rows.append(v | (1 << (n + r)))
    for col in range(n):
        piv = next((r for r in range(col, n) if (rows[r] >> col) & 1), None)
        if piv is None:
            raise ValueError("singular matrix")
        rows[col], rows[piv] = rows[piv], rows[col]
        for r in range(n):
            if r != col and (rows[r] >> col) & 1:
                rows[r] ^= rows[col]
    inv_rows = [(rows[r] >> n) & MASK32 for r in range(n)]
    cols = [0] * n
    for r in range(n):
        for i in range(n):
            if (inv_rows[r] >> i) & 1:
                cols[i] |= 1 << r
    return cols


def row_mask(M, r, in_bits=32, shift=0):
    """Bit mask of which input bits feed output bit r."""
    m = 0
    for i in range(in_bits):
        if (M[i] >> r) & 1:
            m |= 1 << (i + shift)
    return m


# ------------------------------------------------------ matrices for width W
class Tables:
    def __init__(self, W):
        self.W = W
        self.N = W // 8
        N = self.N
        T = [step8_zero(1 << i) for i in range(32)]
        self.T = T
        self.pw = [[1 << i for i in range(32)]]            # T^0
        for _ in range(N):
            self.pw.append(mat_mul(T, self.pw[-1]))        # T^1 .. T^N
        self.TN = self.pw[N]
        self.Tinv = mat_inv(T)
        self.kbits = N.bit_length()                        # floor(log2 N)+1
        self.unw = [mat_pow(self.Tinv, 1 << j) for j in range(self.kbits)]

        # masks over vin = {data[W-1:0], crc_in[31:0]}  (crc_in = low 32 bits)
        self.full_masks = []
        for r in range(32):
            m = row_mask(self.TN, r, 32, 0)
            for lane in range(N):
                img = self.pw[N - lane]                    # T^(N-lane)
                for k in range(8):
                    if (img[k] >> r) & 1:
                        m |= 1 << (32 + 8 * lane + k)
            self.full_masks.append(m)
        self.unw_masks = [[row_mask(self.unw[j], r) for r in range(32)]
                          for j in range(self.kbits)]

    # python evaluation of exactly what the Verilog does
    def eval_beat(self, crc_in, data, keep):
        N = self.N
        dm = 0
        n = 0
        for lane in range(N):
            if (keep >> lane) & 1:
                dm |= ((data >> (8 * lane)) & 0xFF) << (8 * lane)
                n += 1
        vin = (dm << 32) | crc_in
        full = 0
        for r in range(32):
            full |= (bin(vin & self.full_masks[r]).count("1") & 1) << r
        kz = N - n
        cur = full
        for j in range(self.kbits):
            if (kz >> j) & 1:
                nxt = 0
                for r in range(32):
                    nxt |= (bin(cur & self.unw_masks[j][r]).count("1") & 1) << r
                cur = nxt
        return full, cur, n


def ref_update(crc, data_bytes):
    """Independent byte-wise reference (reflected CRC register, no final XOR)."""
    for b in data_bytes:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (POLY_R if (crc & 1) else 0)
    return crc


def selftest(widths, iters=300, seed=7):
    rnd = random.Random(seed)
    # classic check value: CRC-32("123456789") == 0xCBF43926
    assert (~ref_update(MASK32, b"123456789")) & MASK32 == 0xCBF43926
    assert zlib.crc32(b"123456789") == 0xCBF43926
    for W in widths:
        t = Tables(W)
        N = W // 8
        for _ in range(iters):
            crc_in = rnd.getrandbits(32)
            data = rnd.getrandbits(W)
            n = rnd.randint(0, N)
            keep = (1 << n) - 1
            bs = [(data >> (8 * i)) & 0xFF for i in range(n)]
            exp = ref_update(crc_in, bs)
            full, part, nn = t.eval_beat(crc_in, data, keep)
            assert nn == n
            assert part == exp, (W, n, hex(part), hex(exp))
            if n == N:
                assert full == exp
        # whole-message check against zlib, random beat splitting
        for _ in range(20):
            L = rnd.randint(1, 5 * N)
            msg = bytes(rnd.getrandbits(8) for _ in range(L))
            crc = MASK32
            pos = 0
            while pos < L:
                chunk = msg[pos:pos + N]
                data = int.from_bytes(chunk.ljust(N, b"\0"), "little")
                keep = (1 << len(chunk)) - 1
                _, crc, _ = t.eval_beat(crc, data, keep)
                pos += N
            assert (~crc) & MASK32 == zlib.crc32(msg)
    print("gen_crc selftest OK for widths", widths)


# ------------------------------------------------------------ Verilog output
def hexlit(bits, val):
    nd = (bits + 3) // 4
    return "%d'h%0*X" % (bits, nd, val)


def emit_module(W):
    t = Tables(W)
    N, KB = t.N, t.kbits
    o = []
    o.append("// ---------------------------------------------------------------------------")
    o.append("// GENERATED by scripts/gen_crc.py -- do not edit by hand.")
    o.append("// Parallel CRC-32 (IEEE 802.3, reflected) update for a %d-bit (%d-byte) bus." % (W, N))
    o.append("//   crc_full : state after all %d lanes            (correct when keep is all ones)" % N)
    o.append("//   crc_part : state after the n valid low lanes   (correct when keep is low-aligned)")
    o.append("//   nvalid   : number of set bits in keep")
    o.append("// ---------------------------------------------------------------------------")
    o.append("module s2_crc32_beat_%d (" % W)
    o.append("    input  wire [31:0]     crc_in,")
    o.append("    input  wire [%d:0]  data," % (W - 1))
    o.append("    input  wire [%d:0]   keep," % (N - 1))
    o.append("    output wire [31:0]     crc_full,")
    o.append("    output wire [31:0]     crc_part,")
    o.append("    output wire [7:0]      nvalid")
    o.append(");")
    o.append("    integer i;")
    o.append("    reg [%d:0] dm;" % (W - 1))
    o.append("    reg [7:0]  pc;")
    o.append("    always @* begin")
    o.append("        pc = 8'd0;")
    o.append("        for (i = 0; i < %d; i = i + 1) begin" % N)
    o.append("            dm[8*i +: 8] = keep[i] ? data[8*i +: 8] : 8'h00;")
    o.append("            pc = pc + {7'd0, keep[i]};")
    o.append("        end")
    o.append("    end")
    o.append("    assign nvalid = pc;")
    o.append("    wire [7:0] kz = 8'd%d - pc;   // dead lanes to unwind" % N)
    o.append("    wire [%d:0] vin = {dm, crc_in};" % (W + 31))
    for r in range(32):
        o.append("    assign crc_full[%d] = ^(vin & %s);" % (r, hexlit(W + 32, t.full_masks[r])))
    prev = "crc_full"
    for j in range(KB):
        o.append("    wire [31:0] u%d;" % j)
        for r in range(32):
            o.append("    assign u%d[%d] = kz[%d] ? ^(%s & %s) : %s[%d];"
                     % (j, r, j, prev, hexlit(32, t.unw_masks[j][r]), prev, r))
        prev = "u%d" % j
    o.append("    assign crc_part = %s;" % prev)
    o.append("endmodule")
    o.append("")
    return "\n".join(o)


def emit_wrapper(widths):
    o = []
    o.append("// Width-selecting wrapper around the generated per-width modules.")
    o.append("module s2_crc32_beat #(parameter DATA_W = 64) (")
    o.append("    input  wire [31:0]          crc_in,")
    o.append("    input  wire [DATA_W-1:0]    data,")
    o.append("    input  wire [DATA_W/8-1:0]  keep,")
    o.append("    output wire [31:0]          crc_full,")
    o.append("    output wire [31:0]          crc_part,")
    o.append("    output wire [7:0]           nvalid")
    o.append(");")
    o.append("generate")
    first = True
    for W in widths:
        kw = "if" if first else "else if"
        first = False
        o.append("    %s (DATA_W == %d) begin : g_w%d" % (kw, W, W))
        o.append("        s2_crc32_beat_%d u (.crc_in(crc_in), .data(data), .keep(keep)," % W)
        o.append("            .crc_full(crc_full), .crc_part(crc_part), .nvalid(nvalid));")
        o.append("    end")
    o.append("    else begin : g_unsupported")
    o.append("        // DATA_W not generated: run scripts/gen_crc.py --widths ... to add it")
    o.append("        s2_crc32_unsupported_data_width u ();")
    o.append("    end")
    o.append("endgenerate")
    o.append("endmodule")
    o.append("")
    return "\n".join(o)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--widths", type=int, nargs="+", default=[32, 64, 128, 256, 512])
    ap.add_argument("--out", default="rtl/s2_crc32_gen.v")
    ap.add_argument("--no-selftest", action="store_true")
    a = ap.parse_args()
    if not a.no_selftest:
        selftest(a.widths)
    with open(a.out, "w") as f:
        f.write("`timescale 1ns/1ps\n")
        f.write("// Auto-generated parallel CRC-32. Widths: %s\n\n" % a.widths)
        for W in a.widths:
            f.write(emit_module(W))
            f.write("\n")
        f.write(emit_wrapper(a.widths))
    print("wrote", a.out)


if __name__ == "__main__":
    main()
