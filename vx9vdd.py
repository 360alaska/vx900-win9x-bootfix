#!/usr/bin/env python3
"""vx9vdd - patch a Windows 9x VDD so Windows boots and runs DOS windows on VIA VX900 boards.

usage:  python vx9vdd.py INPUT [OUTPUT]

INPUT   a stock VDD.VXD (from the Windows CD), or a VMM32.VXD from an installed
        Windows (the VDD is taken out of it).
OUTPUT  the patched driver, default VDD.VXD in the current folder. Copy it to
        C:\\WINDOWS\\SYSTEM\\VMM32\\VDD.VXD on the VX900 machine.

The four changes are found by their instruction patterns, not by address, so any
VDD build that carries the same code is handled (checked on Windows 95 OSR2,
98 SE and Me). If a pattern is missing or found twice, nothing is written.

Copyright (c) 2026 360ALASKA. MIT License.
"""
import re
import struct
import sys
import zlib


class Bits:
    def __init__(self, data):
        self.d, self.p = data, 0

    def get(self, n):
        v = 0
        for i in range(n):
            v |= ((self.d[self.p >> 3] >> (self.p & 7)) & 1) << i
            self.p += 1
        return v


def w4_chunk(buf, size):
    """One W4 chunk: the DoubleSpace 'DS' bit stream, least significant bit first."""
    bs, out = Bits(buf + b"\0" * 8), bytearray()
    while len(out) < size:
        code = bs.get(2)
        if code == 2:                       # literal 00..7F
            out.append(bs.get(7))
        elif code == 1:                     # literal 80..FF
            out.append(bs.get(7) | 0x80)
        else:
            if code == 0:                   # 6-bit offset
                off = bs.get(6)
                if off == 0:
                    break
            elif bs.get(1) == 0:            # 8-bit offset
                off = bs.get(8) + 64
            else:                           # 12-bit offset
                off = bs.get(12) + 320
                if off == 4415:             # sector marker
                    continue
            n = 0
            while bs.get(1) == 0:
                n += 1
            length = (1 << n) + bs.get(n) + 1
            for _ in range(length):
                out.append(out[-off])
    return bytes(out)


def vdd_from_vmm32(d):
    """Return a standalone VDD.VXD (MZ stub + LE) taken out of a VMM32.VXD."""
    ne = struct.unpack_from("<I", d, 0x3C)[0]
    sig = d[ne:ne + 2]
    if sig == b"W4":
        _, _, csize, nch = struct.unpack_from("<2sHHH", d, ne)
        offs = list(struct.unpack_from("<%dI" % nch, d, ne + 16)) + [len(d)]
        w3 = bytearray()
        for k in range(nch):
            buf = d[offs[k]:offs[k + 1]]
            w3 += buf[:csize] if len(buf) >= csize else w4_chunk(buf, csize)
        w3 = bytes(w3)
    elif sig == b"W3":
        w3 = d[ne:]
    else:
        raise SystemExit("not a VMM32.VXD: no W3 or W4 header")
    count = struct.unpack_from("<H", w3, 4)[0]
    ents = [struct.unpack_from("<8sII", w3, 16 + 16 * i) for i in range(count)]
    ents = [(n.decode("ascii").strip(), off) for n, off, _ in ents]
    if "VDD" not in dict(ents):
        raise SystemExit("this VMM32.VXD holds no VDD (the copy on the Windows 95 CD "
                         "holds only VMM; use VDD.VXD from the CD instead)")
    start = dict(ents)["VDD"]
    later = [off for _, off in ents if off > start]
    le = bytearray(w3[start - ne:(min(later) if later else len(w3) + ne) - ne])
    if le[:2] != b"LE":
        raise SystemExit("VDD entry is not an LE image")
    stub = 0x80
    pagesz, npages, lastpg = (struct.unpack_from("<I", le, o)[0] for o in (0x28, 0x14, 0x2C))
    datapages = struct.unpack_from("<I", le, 0x80)[0] - start
    le = le[:datapages + (npages - 1) * pagesz + lastpg]
    struct.pack_into("<I", le, 0x80, datapages + stub)   # data pages offset is from file start
    struct.pack_into("<II", le, 0x88, 0, 0)              # non-resident names: not carried over
    mz = bytearray(stub)
    mz[0:2] = b"MZ"
    struct.pack_into("<H", mz, 0x18, 0x40)
    struct.pack_into("<I", mz, 0x3C, stub)
    return bytes(mz) + bytes(le)


SITES = (
    ("sequencer read fallback",        rb"\x8a\x44\x39\x66\xeb.\x90"),
    ("sequencer write, non-owner VM",  rb"\x50\x80\xf9\x0f\x77.\x38\x44\x39\x66"),
    ("extended CRTC write, detached",  rb"\x80\xf9\x18\x76.\xfe\xca\x8a\xe0\x8a\xc1\x66\xef"),
    ("trapped-port table",             rb"\x20\x00\xc0\x03....\xc1\x03....\xc2\x03....\xc3\x03"),
)
# Extended sequencer read: take the value from the chip, keeping the chip's index.
#   cmp cl,0Fh / ja real / mov al,[edi+ecx+66h] / ret
#   real: dec edx / in al,dx / mov ch,al / mov al,cl / out dx,al / inc edx / in al,dx
#         xchg ch,al / dec edx / out dx,al / inc edx / mov al,ch / ret
READ_CAVE = bytes.fromhex("80f90f77058a440f66c34aec88c588c8ee42ec86e84aee4288e8c3")


def patch_vdd(d):
    d = bytearray(d)
    ne = struct.unpack_from("<I", d, 0x3C)[0]
    if d[:2] != b"MZ" or d[ne:ne + 2] != b"LE":
        raise SystemExit("not a VxD file (no MZ/LE header)")
    if READ_CAVE in d:
        raise SystemExit("this VDD is already patched")
    hdr = lambda o: struct.unpack_from("<I", d, ne + o)[0]
    pagesz, objtab, nobj, datapages = hdr(0x28), ne + hdr(0x40), hdr(0x44), hdr(0x80)
    found = {}
    for name, pat in SITES:
        hits = [m.start() for m in re.finditer(pat, bytes(d), re.S)]
        if len(hits) != 1:
            raise SystemExit("cannot patch: '%s' found %d times (need exactly 1). "
                             "This VDD build is not supported." % (name, len(hits)))
        found[name] = hits[0]
        print("  %-32s at file offset %05X" % (name, hits[0]))
    rd, wr, cr, pt = (found[n] for n, _ in SITES)
    if d[pt + 2 + 6 * 31:pt + 4 + 6 * 31] != b"\xdf\x03":
        raise SystemExit("cannot patch: port table does not end at 3DF")
    for oi in range(nobj):
        vsize, _, _, pidx, pcnt, _ = struct.unpack_from("<6I", d, objtab + 24 * oi)
        fbase = datapages + (pidx - 1) * pagesz
        if fbase <= rd < fbase + vsize:
            break
    else:
        raise SystemExit("cannot patch: code object not found")
    if not fbase <= wr < fbase + vsize:
        raise SystemExit("cannot patch: read and write code are in different objects")
    c1 = (vsize + 15) & ~15
    c2 = (c1 + len(READ_CAVE) + 15) & ~15
    rdo, wro = rd - fbase, wr - fbase
    cont = wro + 6
    drop = cont + struct.unpack_from("<b", d, wr + 5)[0]
    rel = lambda frm, to: struct.pack("<i", to - (frm + 4))
    # Sequencer write from a VM that does not own the hardware:
    #   cmp cl,5Dh / je timer / cmp cl,0Fh / ja drop / jmp original / drop: jmp discard
    #   timer: write index 5D to the chip, keeping the chip's index, then leave as 'discard'
    cave2 = bytearray(bytes.fromhex("80f95d740f80f90f7705"))
    cave2 += b"\xE9" + rel(c2 + len(cave2) + 1, cont)
    cave2 += b"\xE9" + rel(c2 + len(cave2) + 1, drop)
    cave2 += bytes.fromhex("88c54aec5088c8ee4288e8ee4a58ee42")
    cave2 += b"\xE9" + rel(c2 + len(cave2) + 1, drop)
    end = c2 + len(cave2)
    if end > pcnt * pagesz or fbase + end > len(d) or any(d[fbase + vsize:fbase + end + 4]):
        raise SystemExit("cannot patch: no blank room after the code object")
    d[fbase + c1:fbase + c1 + len(READ_CAVE)] = READ_CAVE
    d[fbase + c2:fbase + end] = cave2
    d[rd:rd + 7] = b"\xE9" + rel(rdo + 1, c1) + b"\x90\x90"
    d[wr + 1:wr + 6] = b"\xE9" + rel(wro + 2, c2)
    d[cr + 3] = 0xEB                                  # jbe -> jmp: hold back extended CRTC writes
    d[pt + 2 + 18:pt + 4 + 18] = b"\xdf\x03"          # slot of port 3C3 now holds 3DF
    d[pt:pt + 2] = b"\x1f\x00"                        # 31 ports: 3C3 is no longer trapped
    struct.pack_into("<I", d, objtab + 24 * oi, end)
    return bytes(d)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    src = open(argv[1], "rb").read()
    out = argv[2] if len(argv) > 2 else "VDD.VXD"
    print("input  %s  %d bytes  CRC32 %08X" % (argv[1], len(src), zlib.crc32(src)))
    ne = struct.unpack_from("<I", src, 0x3C)[0] if src[:2] == b"MZ" and len(src) > 0x40 else 0
    if src[ne:ne + 2] in (b"W3", b"W4"):
        print("  VMM32.VXD: taking the VDD out of it")
        src = vdd_from_vmm32(src)
    patched = patch_vdd(src)
    open(out, "wb").write(patched)
    print("output %s  %d bytes  CRC32 %08X" % (out, len(patched), zlib.crc32(patched)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
