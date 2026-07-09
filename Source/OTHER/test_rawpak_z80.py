# Run the REAL Z80 RawPak code (OpenRoot + PakReadToc) in the full emulator,
# hooking sd_read_sector to serve sectors from an injector-built FAT32 image.
# Reproduces the host TOC-read behaviour locally (no host cycle needed).
#
# Usage: python test_rawpak_z80.py [image]   (default Build/test_wc.img)
import sys, struct
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from zuma_full_z80_emulator import ZumaFullZ80Emulator, RETURN_MARKER  # noqa

ROOT = HERE.parents[1]

def trace_byte(sym, emu, name):
    addr = sym.get(name)
    return emu.get_byte(addr) if addr is not None else None

def trace_text(value):
    return f"#{value:02X}" if value is not None else "n/a"

def ix_of(reg):
    if hasattr(reg, 'IX'):
        return reg.IX & 0xFFFF
    return ((reg.IXH << 8) | reg.IXL) & 0xFFFF

def main():
    img_path = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "Build" / "test_wc.img")
    img = open(img_path, 'rb')
    emu = ZumaFullZ80Emulator()
    sym = emu.sym
    # The RawPak loader now lives in a slot-3 overlay (page #40). On HW the
    # resident trampolines map it; these tests call overlay internals directly,
    # so map page #40 into slot 3 up front. (Calls through the trampoline, e.g.
    # LoadGameplayLevelSpecificFromPack, set/restore PAGE3 themselves.)
    emu.mem.pages[3] = 0x40
    sd_read = sym["Core.sd_read_sector"]
    reads = []

    orig_step = emu.step
    def hooked_step():
        pc = emu.reg.PC
        if pc == sd_read:
            lba = (emu.reg.L | (emu.reg.H << 8)) | ((emu.reg.E | (emu.reg.D << 8)) << 16)
            ix = ix_of(emu.reg)
            img.seek(lba * 512)
            data = img.read(512)
            if len(data) < 512:
                data += b"\x00" * (512 - len(data))
            for i, b in enumerate(data):
                emu.set_byte((ix + i) & 0xFFFF, b)
            reads.append((lba, ix, tuple(emu.mem.pages)))
            # RET, CF=0 (success)
            sp = emu.reg.SP
            ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
            emu.reg.SP = (sp + 2) & 0xFFFF
            emu.reg.PC = ret
            emu.reg.F &= ~0x01
            return 0
        return orig_step()
    emu.step = hooked_step

    # 1) OpenRoot
    emu.call(sym["Core.RawPak_OpenRoot"])
    cf = emu.reg.F & 1
    fsc = struct.unpack("<I", emu.get_memory(sym["Core.RawPak_FileStartClus"], 4))[0]
    open_step = trace_byte(sym, emu, "Core.ZiFiTraceOpenStep")
    print(f"OpenRoot: CF={cf}  openStep={trace_text(open_step)}  FileStartClus={fsc}")
    print(f"  FatStart={struct.unpack('<I', emu.get_memory(sym['Core.RawPak_FatStart'],4))[0]}"
          f"  DataStart={struct.unpack('<I', emu.get_memory(sym['Core.RawPak_DataStart'],4))[0]}")
    if not cf:
        print("FAIL: OpenRoot did not find the PAK"); return 1

    def curclus():
        return struct.unpack("<I", emu.get_memory(sym["Core.RawPak_CurClus"], 4))[0]

    # 2) Targeted test of the B-clobber bug: Seek0 then SkipB(N) must advance
    #    CurClus by exactly N (before the fix it walked the whole chain to EOC).
    emu.call(sym["Core.RawPak_Seek0"])
    base = curclus()
    print(f"\nafter Seek0: CurClus={base} (FileStartClus)")
    # NB: the FAT-sector cache (RawPak_FatNext / RawPak_FatBufLba) means a short
    # SkipB within one FAT sector now does 0 SD reads, so the B-clobber fix is
    # checked by CurClus advancing by exactly N (not by the read count anymore).
    for n in (1, 3, 10):
        emu.call(sym["Core.RawPak_Seek0"])
        nb = len(reads)
        emu.call(sym["Core.RawPak_SkipB"], b=n)
        cc = curclus()
        exp = base + n
        ok = (cc == exp)
        print(f"  SkipB({n}): CurClus={cc} expect={exp}  reads={len(reads)-nb} (cached)  "
              + ("OK" if ok else "FAIL"))
        if not ok:
            print("FAIL: SkipB still wrong (B-clobber not fixed)"); return 1
    print("\nPASS: SkipB advances by exactly N (B-clobber fixed) -> LoadNon(1) now"
          " lands on the TOC sector instead of walking to EOC.")

    # 3) Run the FULL gameplay loader against the real FAT image, hooking only
    #    the hardware leaves (sd_init, sd_read_sector -> image; FT.WriteMem,
    #    ZiFi_Done -> no-op). Real RawPak + SkipSectors16 + StreamSection run.
    #    A ring buffer captures the PC trail so a wild-PC crash is pinpointed.
    wm_calls = []
    def hook_ret(cf=False):
        sp = emu.reg.SP
        ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
        emu.reg.SP = (sp + 2) & 0xFFFF
        emu.reg.PC = ret
        if cf: emu.reg.F |= 0x01
        else:  emu.reg.F &= ~0x01

    def ft_write_mem():
        dest = ((emu.reg.A & 0xFF) << 16) | ((emu.reg.D & 0xFF) << 8) | (emu.reg.E & 0xFF)
        src = ((emu.reg.H & 0xFF) << 8) | (emu.reg.L & 0xFF)
        size = ((emu.reg.B & 0xFF) << 8) | (emu.reg.C & 0xFF)
        wm_calls.append((emu.reg.A, emu.reg.D, emu.reg.E, emu.reg.B, emu.reg.C, src))
        if 0 <= dest < len(emu.ft.ram_g):
            end = min(dest + size, len(emu.ft.ram_g))
            data = bytes(emu.mem.read((src + i) & 0xFFFF) for i in range(end - dest))
            emu.ft.ram_g[dest:end] = data
        hook_ret(False)

    H = {
        sym["Core.sd_init"]: lambda: hook_ret(False),
        sym["Core.ZiFi_Done"]: lambda: hook_ret(False),
        sym["FT.WriteMem"]: ft_write_mem,
    }
    def sd_fill():
        lba = (emu.reg.L | (emu.reg.H << 8)) | ((emu.reg.E | (emu.reg.D << 8)) << 16)
        ix = ix_of(emu.reg)
        img.seek(lba * 512); data = img.read(512)
        if len(data) < 512: data += b"\x00" * (512 - len(data))
        for i, b in enumerate(data):
            emu.set_byte((ix + i) & 0xFFFF, b)
        hook_ret(False)
    H[sd_read] = sd_fill

    ring = []
    def hooked_step2():
        pc = emu.reg.PC
        ring.append((pc, emu.reg.SP, tuple(emu.mem.pages)))
        if len(ring) > 60: ring.pop(0)
        h = H.get(pc)
        if h:
            h(); return 0
        return orig_step()
    emu.step = hooked_step2

    emu.set_byte(sym["Core.CurrentLevel"], 1)
    print("\n--- full loader trace (LoadGameplayLevelSpecificFromPack, L2) ---")
    try:
        emu.call(sym["Core.LoadGameplayLevelSpecificFromPack"], max_steps=20_000_000)
        cf = emu.reg.F & 1
        step = trace_byte(sym, emu, "Core.ZiFiTraceStep")
        print(f"loader returned: CF={cf}  ZiFiTraceStep={trace_text(step)}  FT.WriteMem calls={len(wm_calls)}")
        if not cf or (step is not None and step != 0x06):
            print("FAIL: gameplay loader did not complete (overlay)"); return 1
        for i, w in enumerate(wm_calls[:8]):
            print(f"  WriteMem#{i}: ramg=#{w[0]:02X}{w[1]:02X}{w[2]:02X} count=#{w[3]:02X}{w[4]:02X} src=#{w[5]:04X}")
        return 0
    except Exception as exc:
        print(f"CRASH: {exc}")
        print("last 30 PC (addr, SP, pages):")
        for pc, sp, pg in ring[-30:]:
            print(f"  PC=#{pc:04X} SP=#{sp:04X} pages={[hex(p) for p in pg]}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
