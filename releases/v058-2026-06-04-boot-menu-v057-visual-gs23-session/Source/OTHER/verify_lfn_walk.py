# Verify the RawPak LFN directory-walk algorithm against a real FAT32 image,
# mirroring EXACTLY what Source/ASM/ts-dos.asm RawPak_FindInCurrentDir does:
#   - scan 32-byte dir entries, follow FAT chain (read_fat_next)
#   - accumulate LFN fragments (UTF-16 low byte) at (seq&0x1F - 1)*13, uppercased
#   - on the short entry, effective name = assembled LFN if any, else 8.3
#   - compare case-insensitively to the uppercased target
# Walks /Games/Zuma Deluxe VDAC2/ZUMALVL.PAK by LONG names.
#
# Usage: python verify_lfn_walk.py <path-to-wc.img>
import sys, struct

LFN_OFFS = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]

def up(s):  # uppercase ASCII like RawPak_Upcase
    return ''.join(chr(c - 0x20) if ord('a') <= c <= ord('z') else chr(c)
                   for c in (b if isinstance(b, int) else ord(b) for b in s)) if False else \
           ''.join((ch.upper() if 'a' <= ch <= 'z' else ch) for ch in s)

class Fat:
    def __init__(self, path):
        self.f = open(path, 'rb')
        d = self.rd(0)
        assert struct.unpack_from('<H', d, 11)[0] == 512, "bps != 512"
        self.spc = d[13]
        self.reserved = struct.unpack_from('<H', d, 14)[0]
        self.fats = d[16]
        self.fatsz = struct.unpack_from('<I', d, 36)[0]
        self.rootclus = struct.unpack_from('<I', d, 44)[0]
        self.fatstart = self.reserved
        self.datastart = self.reserved + self.fats * self.fatsz
        print(f"BPB: spc={self.spc} reserved={self.reserved} fats={self.fats} "
              f"fatsz={self.fatsz} root={self.rootclus} fatstart={self.fatstart} datastart={self.datastart}")

    def rd(self, lba):
        self.f.seek(lba * 512)
        b = self.f.read(512)
        return b + b'\x00' * (512 - len(b))

    def fat_next(self, c):  # mirrors RawPak_FatNext
        sec = self.fatstart + (c >> 7)
        d = self.rd(sec)
        off = (c & 127) * 4
        nxt = struct.unpack_from('<I', d, off)[0] & 0x0FFFFFFF
        if nxt >= 0x0FFFFFF8:
            return None
        if nxt < 2:
            return None
        return nxt

    def clus_lba(self, c):
        return self.datastart + (c - 2) * self.spc

    def eff_name(self, entries_lfn, short11):
        # short11 = 11 raw bytes; entries_lfn = assembled chars list or None
        if entries_lfn is not None:
            s = ''.join(entries_lfn)
            z = s.find('\x00')
            if z >= 0:
                s = s[:z]
            return up(s)
        name = short11[:8].decode('latin1').rstrip(' ')
        ext = short11[8:11].decode('latin1').rstrip(' ')
        eff = name + ('.' + ext if ext else '')
        return up(eff)

    def find(self, start_clus, target):
        """Return (found_cluster, attr) or (None, None). Mirrors RawPak_FindInCurrentDir."""
        tgt = up(target)
        c = start_clus
        lfn = {}     # seq-index -> 13 chars
        have_lfn = False
        while c is not None:
            d = self.rd(self.clus_lba(c))
            for i in range(0, 512, 32):
                e = d[i:i+32]
                b0 = e[0]
                if b0 == 0x00:
                    return None, None            # end of directory
                if b0 == 0xE5:
                    have_lfn = False; lfn = {}
                    continue
                attr = e[11]
                if attr == 0x0F:
                    seq = (e[0] & 0x1F) - 1
                    chars = ''.join(up(chr(e[o])) for o in LFN_OFFS)  # low byte, uppercased
                    lfn[seq] = chars
                    have_lfn = True
                    continue
                # short entry
                assembled = None
                if have_lfn:
                    assembled = [lfn.get(k, '\x00'*13) for k in range(max(lfn) + 1)]
                    assembled = list(''.join(assembled))
                eff = self.eff_name(assembled, e[0:11])
                if eff == tgt:
                    clus = (struct.unpack_from('<H', e, 20)[0] << 16) | struct.unpack_from('<H', e, 26)[0]
                    return clus, attr
                have_lfn = False; lfn = {}
            c = self.fat_next(c)
        return None, None

def main():
    img = sys.argv[1]
    fs = Fat(img)
    print(f"\nwalking /Games/Zuma Deluxe VDAC2/ZUMALVL.PAK by long names:")
    c, a = fs.find(fs.rootclus, "Games")
    print(f"  Games            -> cluster={c} attr={a if a is None else hex(a)}")
    if c is None: print("FAIL: Games not found"); return 1
    c, a = fs.find(c, "Zuma Deluxe VDAC2")
    print(f"  Zuma Deluxe VDAC2-> cluster={c} attr={a if a is None else hex(a)}")
    if c is None: print("FAIL: Zuma dir not found"); return 1
    c, a = fs.find(c, "ZUMALVL.PAK")
    print(f"  ZUMALVL.PAK      -> cluster={c} attr={a if a is None else hex(a)}")
    if c is None: print("FAIL: PAK not found"); return 1
    print(f"\nPASS: RawPak LFN walk resolves ZUMALVL.PAK at cluster {c}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
