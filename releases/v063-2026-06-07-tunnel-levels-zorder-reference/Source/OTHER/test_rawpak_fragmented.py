# Fragmented-PAK test for the RawPak sector-run table.
#
# Builds an in-memory FAT32 image where ZUMALVL.PAK is split into several
# non-adjacent extents (runs), then runs the REAL Z80 RawPak against it and
# verifies:
#   1) RawPak_BuildRunTable discovers >1 run (fragmentation detected),
#   2) RawPak_ReadOneLogicalIX maps each logical sector to the right physical
#      LBA — i.e. sampled logical sectors read back byte-for-byte equal to the
#      original contiguous ZUMALVL.PAK (so the loader sees the same file).
#
# Usage: python test_rawpak_fragmented.py [base_image]   (default Build/test_wc.img)
import sys, struct, importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

# import Fat32Image from the injector (module name has dashes -> load by path)
spec = importlib.util.spec_from_file_location("inj", HERE / "inject_zuma_to_wc_img.py")
inj = importlib.util.module_from_spec(spec); spec.loader.exec_module(inj)
Fat32Image, EOC = inj.Fat32Image, inj.EOC

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa

PAK_PATH = ["Games", "Zuma Deluxe VDAC2", "ZUMALVL.PAK"]
K_SEGMENTS = 8


def fragment(img: Fat32Image) -> tuple[int, int, list[tuple[int, int]]]:
    """Relocate the PAK into K non-adjacent contiguous segments.
    Returns (new_start_cluster, n_clusters, [(seg_start, seg_len), ...])."""
    cluster = img.root_cluster
    ent = None
    for name in PAK_PATH:
        ent = img.find_entry(cluster, name)
        if ent is None:
            raise RuntimeError(f"not found: {name}")
        cluster = ent["cluster"]
        dir_cluster_of_ent = None  # remember dir for the file entry below
    # re-find the file entry together with its directory cluster
    dirc = img.root_cluster
    for name in PAK_PATH[:-1]:
        dirc = img.find_entry(dirc, name)["cluster"]
    file_ent = img.find_entry(dirc, PAK_PATH[-1])
    start = file_ent["cluster"]
    size = file_ent["size"]

    chain = img.cluster_chain(start)
    content = img.read_chain(start)                 # full clusters
    n = len(chain)

    img.free_chain(start)                           # release old clusters

    # Reuse exactly the freed FAT chain, but place logical segments into
    # permuted physical blocks. Earlier this test assumed the PAK occupied the
    # whole arithmetic range [start, start+n); current wc.img may have holes or
    # neighbours there. The actual FAT chain is the only safe source of clusters.
    seg_len = (n + K_SEGMENTS - 1) // K_SEGMENTS
    blocks = [chain[i:i + seg_len] for i in range(0, n, seg_len)]
    full_blocks = len(blocks) - 1
    perm = list(range(0, full_blocks, 2)) + list(range(1, full_blocks, 2))
    if blocks[-1]:
        perm.append(len(blocks) - 1)
    flat = [c for block_idx in perm for c in blocks[block_idx]]

    # sanity: all target clusters must come from the old chain and now be free
    old = set(chain)
    for c in flat:
        if c not in old or img.get_fat(c) != 0:
            raise RuntimeError(f"target cluster {c} not free/from-old-chain")

    expected_runs: list[tuple[int, int]] = []
    for c in flat:
        if not expected_runs or c != expected_runs[-1][0] + expected_runs[-1][1]:
            expected_runs.append((c, 1))
        else:
            s, L = expected_runs[-1]
            expected_runs[-1] = (s, L + 1)

    # write content + link the chain across segments (in logical order)
    assert len(flat) == n, (len(flat), n)
    cs = img.cluster_size
    for i, c in enumerate(flat):
        off = img.cluster_offset(c)
        img.data[off:off + cs] = content[i * cs:(i + 1) * cs]
        img.set_fat(c, EOC if i == n - 1 else flat[i + 1])

    # point the directory entry at the new start cluster
    new_start = flat[0]
    base = file_ent["index"] * 32
    img.write_dir_byte(dirc, base + 20, (new_start >> 16) & 0xFF)
    img.write_dir_byte(dirc, base + 21, (new_start >> 24) & 0xFF)
    img.write_dir_byte(dirc, base + 26, new_start & 0xFF)
    img.write_dir_byte(dirc, base + 27, (new_start >> 8) & 0xFF)

    # verify the logical content survived the relocation
    if img.read_chain(new_start)[:size] != content[:size]:
        raise RuntimeError("relocation corrupted file content")
    return new_start, n, expected_runs


def main() -> int:
    base_img = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "Build" / "test_wc.img")
    pak_ref = (ROOT / "Build" / "ZUMALVL.PAK").read_bytes()

    img = Fat32Image(Path(base_img))
    new_start, n, segs = fragment(img)
    data = bytes(img.data)                          # fragmented image bytes (in memory)
    print(f"fragmented PAK: start_cluster={new_start} clusters={n} segments={len(segs)}")
    for i, (s, L) in enumerate(segs):
        print(f"  seg[{i}]: clusters {s}..{s+L-1} ({L})")

    emu = ZumaFullZ80Emulator(); sym = emu.sym
    emu.mem.pages[3] = 0x40          # map loader overlay (page #40) into slot 3
    sd_read = sym["Core.sd_read_sector"]

    def ix_of():
        return (emu.reg.IX & 0xFFFF) if hasattr(emu.reg, "IX") else ((emu.reg.IXH << 8) | emu.reg.IXL) & 0xFFFF

    orig = emu.step
    def hooked():
        if emu.reg.PC == sd_read:
            lba = (emu.reg.L | (emu.reg.H << 8)) | ((emu.reg.E | (emu.reg.D << 8)) << 16)
            ix = ix_of()
            chunk = data[lba * 512: lba * 512 + 512]
            chunk += b"\x00" * (512 - len(chunk))
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
    rc = emu.get_byte(sym["Core.RawPak_RunCount"])
    print(f"OpenRoot CF=1  RunCount={rc}  (expect {len(segs)})")
    rt = sym["Core.RawPak_RunTable"]
    for i in range(rc):
        lba = struct.unpack("<I", emu.get_memory(rt + i * 6, 4))[0]
        ln = struct.unpack("<H", emu.get_memory(rt + i * 6 + 4, 2))[0]
        print(f"  run[{i}]: LBA={lba} len={ln}")
    if rc != len(segs):
        print(f"FAIL: RunCount {rc} != segments {len(segs)}"); return 1

    # read sampled logical sectors and compare to the original contiguous PAK
    STAGE = 0x03
    total_sec = len(pak_ref) // 512
    samples = sorted(set([0, 1, 2, 33, 100, 256, 257, total_sec // 2,
                          total_sec - 2, total_sec - 1]))
    def set_ix(v):
        if hasattr(emu.reg, "IX"):
            emu.reg.IX = v & 0xFFFF
        else:
            emu.reg.IXH, emu.reg.IXL = (v >> 8) & 0xFF, v & 0xFF

    bad = 0
    for n_sec in samples:
        # RawPak_LogCur = n_sec ; IX = 0x8000 (slot-2 staging view, page #03 after OpenRoot)
        emu.set_byte(sym["Core.RawPak_LogCur"], n_sec & 0xFF)
        emu.set_byte(sym["Core.RawPak_LogCur"] + 1, (n_sec >> 8) & 0xFF)
        set_ix(0x8000)
        emu.call(sym["Core.RawPak_ReadOneLogicalIX"], max_steps=2_000_000)
        got = bytes(emu.get_memory(0x8000, 512))
        exp = pak_ref[n_sec * 512: n_sec * 512 + 512]
        exp += b"\x00" * (512 - len(exp))
        ok = got == exp
        if not ok:
            bad += 1
        print(f"  logical sec {n_sec:5d}: {'OK' if ok else 'MISMATCH'}")
    if bad:
        print(f"FAIL: {bad} sampled sectors mismatched"); return 1

    # End-to-end: run the full gameplay loader against the fragmented image.
    def hook_ret(cf=False):
        sp = emu.reg.SP
        ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
        emu.reg.SP = (sp + 2) & 0xFFFF; emu.reg.PC = ret
        emu.reg.F = (emu.reg.F | 1) if cf else (emu.reg.F & ~1)
    wm = [0]
    H = {sym["Core.sd_init"]: lambda: hook_ret(False),
         sym["Core.ZiFi_Done"]: lambda: hook_ret(False),
         sym["FT.WriteMem"]: lambda: (wm.__setitem__(0, wm[0] + 1), hook_ret(False))}
    def hooked2():
        h = H.get(emu.reg.PC)
        if emu.reg.PC == sd_read:
            return hooked()
        if h:
            h(); return 0
        return orig()
    emu.step = hooked2
    emu.set_byte(sym["Core.CurrentLevel"], 1)        # L2
    emu.call(sym["Core.LoadGameplayLevelSpecificFromPack"], max_steps=20_000_000)
    cf = emu.reg.F & 1
    emu.mem.pages[3] = 0x40          # trampoline restored PAGE3=#04; remap overlay to read its diag var
    step = emu.get_byte(sym["Core.ZiFi_GpDbgStep"])
    print(f"\nfull gameplay loader on fragmented PAK: CF={cf} GpDbgStep=#{step:02X} FT.WriteMem={wm[0]}")
    if not cf or step != 0x06:
        print("FAIL: gameplay loader did not complete on fragmented PAK"); return 1

    print("\nPASS: fragmented PAK reads correctly (run table maps logical->physical).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
