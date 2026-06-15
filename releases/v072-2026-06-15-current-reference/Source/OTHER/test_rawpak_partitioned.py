# MBR-partitioned-image test for RawPak (matches a real card's layout, unlike the
# superfloppy wc.img). Builds: [MBR @ LBA0] + [pad] + [the superfloppy FAT32 at
# LBA P], with an MBR partition entry (type 0x0C) pointing at P. Then runs the
# real Z80 RawPak and verifies it:
#   * scans the MBR, takes part_lba = P,
#   * offsets FatStart/DataStart by P,
#   * finds ZUMALVL.PAK and reads it correctly through the partition offset.
# (The harness hooks sd_read_sector above the sd_blkt layer, so block-vs-byte
#  addressing itself is not modelled here — only the partition arithmetic.)
import sys, struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa

PART_LBA = 2048           # partition starts here (typical)
SECTOR = 512


def build_partitioned(superfloppy: bytes) -> bytes:
    mbr = bytearray(512)
    # one partition entry at offset 446: boot=0, type=0x0C (FAT32 LBA), start LBA=PART_LBA
    e = 446
    mbr[e + 0] = 0x00
    mbr[e + 4] = 0x0C
    struct.pack_into("<I", mbr, e + 8, PART_LBA)
    struct.pack_into("<I", mbr, e + 12, len(superfloppy) // SECTOR)
    mbr[510] = 0x55
    mbr[511] = 0xAA
    pad = b"\x00" * ((PART_LBA - 1) * SECTOR)
    return bytes(mbr) + pad + superfloppy


def main() -> int:
    sf = (ROOT / "Build" / "test_wc.img").read_bytes()
    pak_ref = (ROOT / "Build" / "ZUMALVL.PAK").read_bytes()
    img = build_partitioned(sf)
    print(f"partitioned image: part_lba={PART_LBA}, total {len(img)//SECTOR} sectors")

    emu = ZumaFullZ80Emulator(); sym = emu.sym
    emu.mem.pages[3] = 0x40
    sd_read = sym["Core.sd_read_sector"]

    def ix_of():
        return (emu.reg.IX & 0xFFFF) if hasattr(emu.reg, "IX") else ((emu.reg.IXH << 8) | emu.reg.IXL) & 0xFFFF

    orig = emu.step
    def hooked():
        if emu.reg.PC == sd_read:
            lba = (emu.reg.L | (emu.reg.H << 8)) | ((emu.reg.E | (emu.reg.D << 8)) << 16)
            ix = ix_of()
            chunk = img[lba * SECTOR: lba * SECTOR + SECTOR]
            chunk += b"\x00" * (SECTOR - len(chunk))
            for i, b in enumerate(chunk):
                emu.set_byte((ix + i) & 0xFFFF, b)
            sp = emu.reg.SP
            ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
            emu.reg.SP = (sp + 2) & 0xFFFF; emu.reg.PC = ret; emu.reg.F &= ~1
            return 0
        return orig()
    emu.step = hooked

    emu.call(sym["Core.RawPak_OpenRoot"], max_steps=8_000_000)
    if not (emu.reg.F & 1):
        print(f"FAIL: OpenRoot CF=0 (step #{emu.get_byte(sym['Core.ZiFi_DbgGamesA']):02X})"); return 1
    part = struct.unpack("<I", emu.get_memory(sym["Core.RawPak_PartLba"], 4))[0]
    fatstart = struct.unpack("<I", emu.get_memory(sym["Core.RawPak_FatStart"], 4))[0]
    datastart = struct.unpack("<I", emu.get_memory(sym["Core.RawPak_DataStart"], 4))[0]
    fsc = struct.unpack("<I", emu.get_memory(sym["Core.RawPak_FileStartClus"], 4))[0]
    print(f"OpenRoot CF=1  part_lba={part} (expect {PART_LBA})  FatStart={fatstart}  DataStart={datastart}  PakClus={fsc}")
    if part != PART_LBA:
        print(f"FAIL: part_lba {part} != {PART_LBA}"); return 1
    # FatStart/DataStart must be the superfloppy values shifted by PART_LBA:
    # superfloppy FatStart=32, DataStart=3234 (from the contiguous test).
    if fatstart != PART_LBA + 32:
        print(f"FAIL: FatStart {fatstart} != {PART_LBA + 32}"); return 1
    if datastart != PART_LBA + 3234:
        print(f"FAIL: DataStart {datastart} != {PART_LBA + 3234}"); return 1

    # read sampled logical sectors and compare to the original PAK
    def set_ix(v):
        if hasattr(emu.reg, "IX"):
            emu.reg.IX = v & 0xFFFF
        else:
            emu.reg.IXH, emu.reg.IXL = (v >> 8) & 0xFF, v & 0xFF
    total = len(pak_ref) // SECTOR
    bad = 0
    for n in sorted(set([0, 1, 256, total // 2, total - 1])):
        emu.set_byte(sym["Core.RawPak_LogCur"], n & 0xFF)
        emu.set_byte(sym["Core.RawPak_LogCur"] + 1, (n >> 8) & 0xFF)
        set_ix(0x8000)
        emu.call(sym["Core.RawPak_ReadOneLogicalIX"], max_steps=2_000_000)
        got = bytes(emu.get_memory(0x8000, SECTOR))
        exp = pak_ref[n * SECTOR: n * SECTOR + SECTOR]; exp += b"\x00" * (SECTOR - len(exp))
        ok = got == exp
        if not ok: bad += 1
        print(f"  logical sec {n:5d}: {'OK' if ok else 'MISMATCH'}")
    if bad:
        print(f"FAIL: {bad} sectors mismatched (partition offset wrong)"); return 1

    print("\nPASS: MBR-partitioned read works (part_lba offset applied correctly).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
