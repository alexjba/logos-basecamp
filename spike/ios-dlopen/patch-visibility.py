#!/usr/bin/env python3
"""Clear N_PEXT on every private-external symbol of every object in a Mach-O
static archive, writing a new archive.

Why: logos-nix's static Qt is configured with `reduce_exports` and, being a
static build, Q_*_EXPORT expands to nothing, so Qt's whole API is compiled with
-fvisibility=hidden ("private external" in nm -m). An app linking such archives
exports NONE of Qt; a dlopen'd framework can then never resolve Qt upward.

This is the spike's stand-in for rebuilding Qt with -DFEATURE_reduce_exports=OFF:
it flips the visibility bit in the object files so ld64 treats them as ordinary
globals. Output is used ONLY by the spike host link.

usage: patch-visibility.py <in.a> <out.a>
"""
import os
import struct
import subprocess
import sys
import tempfile

MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB = 0x2
N_PEXT = 0x10
N_EXT = 0x01


def patch_object(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        return 0, "not MH_MAGIC_64 (0x%08x)" % magic
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    symoff = nsyms = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SYMTAB:
            symoff, nsyms = struct.unpack_from("<II", data, off + 8)
            break
        off += cmdsize
    if symoff is None:
        return 0, "no LC_SYMTAB"
    flipped = 0
    for i in range(nsyms):
        o = symoff + i * 16
        n_type = data[o + 4]
        if (n_type & N_EXT) and (n_type & N_PEXT):
            data[o + 4] = n_type & ~N_PEXT
            flipped += 1
    with open(path, "wb") as f:
        f.write(data)
    return flipped, None


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with tempfile.TemporaryDirectory() as tmp:
        names = subprocess.run(["ar", "t", src], check=True, capture_output=True, text=True).stdout.split()
        if len(names) != len(set(names)):
            dups = sorted({n for n in names if names.count(n) > 1})
            sys.exit("duplicate member names in %s: %s" % (src, dups))
        subprocess.run(["ar", "x", os.path.abspath(src)], cwd=tmp, check=True)
        total = 0
        skipped = []
        for n in names:
            flipped, err = patch_object(os.path.join(tmp, n))
            if err:
                skipped.append((n, err))
            total += flipped
        objs = [os.path.join(tmp, n) for n in names]
        subprocess.run(["libtool", "-static", "-no_warning_for_no_symbols", "-o", os.path.abspath(dst)] + objs,
                       check=True)
        print("%s -> %s: %d symbols made external, %d objects skipped" % (src, dst, total, len(skipped)))
        for n, err in skipped[:10]:
            print("  skipped %s: %s" % (n, err))


if __name__ == "__main__":
    main()
