#!/usr/bin/env python3
# Fragmented-ZUMAMAIN.PAK test for the RawPak sector-run table and boot loader.
#
# The older fragmented-PAK harness covers ZUMALVL.PAK. This one targets the
# boot-split main pack because real SD cards can fragment it independently.
import re
import struct
import sys
import importlib.util
import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

spec = importlib.util.spec_from_file_location("inj", HERE / "inject_zuma_to_wc_img.py")
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)
Fat32Image, EOC = inj.Fat32Image, inj.EOC

from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator  # noqa

PAK_PATH = ["Games", "Zuma Deluxe VDAC2", "ZUMAMAIN.PAK"]
K_SEGMENTS = 8


def say(text: str) -> None:
    print(text, flush=True)


def fragment(img: Fat32Image, cluster_runs: bool = False) -> tuple[int, int, list[tuple[int, int]]]:
    dirc = img.root_cluster
    for name in PAK_PATH[:-1]:
        ent = img.find_entry(dirc, name)
        if ent is None:
            raise RuntimeError(f"not found: {name}")
        dirc = ent["cluster"]
    file_ent = img.find_entry(dirc, PAK_PATH[-1])
    if file_ent is None:
        raise RuntimeError(f"not found: {PAK_PATH[-1]}")
    start = file_ent["cluster"]
    size = file_ent["size"]

    chain = img.cluster_chain(start)
    content = img.read_chain(start)
    n = len(chain)
    img.free_chain(start)

    if cluster_runs:
        # Worst-case-ish FAT layout: logical file order jumps between individual
        # clusters, producing thousands of one-sector runs on 512-byte clusters.
        flat = chain[::2] + chain[1::2]
    else:
        seg_len = (n + K_SEGMENTS - 1) // K_SEGMENTS
        blocks = [chain[i:i + seg_len] for i in range(0, n, seg_len)]
        full_blocks = len(blocks) - 1
        perm = list(range(0, full_blocks, 2)) + list(range(1, full_blocks, 2))
        if blocks[-1]:
            perm.append(len(blocks) - 1)
        flat = [c for block_idx in perm for c in blocks[block_idx]]

    old = set(chain)
    for c in flat:
        if c not in old or img.get_fat(c) != 0:
            raise RuntimeError(f"target cluster {c} not free/from-old-chain")

    expected_runs: list[tuple[int, int]] = []
    for c in flat:
        if not expected_runs or c != expected_runs[-1][0] + expected_runs[-1][1]:
            expected_runs.append((c, 1))
        else:
            s, length = expected_runs[-1]
            expected_runs[-1] = (s, length + 1)

    cs = img.cluster_size
    for i, c in enumerate(flat):
        off = img.cluster_offset(c)
        img.data[off:off + cs] = content[i * cs:(i + 1) * cs]
        img.set_fat(c, EOC if i == n - 1 else flat[i + 1])

    new_start = flat[0]
    base = file_ent["index"] * 32
    img.write_dir_byte(dirc, base + 20, (new_start >> 16) & 0xFF)
    img.write_dir_byte(dirc, base + 21, (new_start >> 24) & 0xFF)
    img.write_dir_byte(dirc, base + 26, new_start & 0xFF)
    img.write_dir_byte(dirc, base + 27, (new_start >> 8) & 0xFF)

    if img.read_chain(new_start)[:size] != content[:size]:
        raise RuntimeError("relocation corrupted file content")
    return new_start, n, expected_runs


def parse_main_table() -> list[tuple[int, int]]:
    text = (ROOT / "Source" / "ASM" / "main_pak_table.inc").read_text(encoding="utf-8")
    vals: list[tuple[str, int]] = []
    for line in text.splitlines():
        m = re.search(r"\b(DEF[WB])\s+([#0-9A-Fa-fx]+)", line)
        if not m:
            continue
        raw = m.group(2)
        val = int(raw[1:], 16) if raw.startswith("#") else int(raw, 0)
        vals.append((m.group(1), val))
    out: list[tuple[int, int]] = []
    i = 0
    while i + 1 < len(vals):
        if vals[i][0] == "DEFB" and vals[i + 1][0] == "DEFW":
            out.append((vals[i][1], vals[i + 1][1]))
            if i + 2 < len(vals) and vals[i + 2][0] == "DEFW":
                i += 3
            else:
                i += 2
        else:
            i += 1
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("base_img", nargs="?", default=str(ROOT / "Build" / "test_wc.img"))
    ap.add_argument("--cluster-runs", action="store_true",
                    help="permute individual clusters to exceed RAWPAK_RUN_MAX")
    ns = ap.parse_args()
    base_img = ns.base_img
    pak_ref = (ROOT / "Build" / "ZUMAMAIN.PAK").read_bytes()
    table = parse_main_table()
    if not table:
        say("FAIL: could not parse main_pak_table.inc")
        return 1

    img = Fat32Image(Path(base_img))
    new_start, n, segs = fragment(img, cluster_runs=ns.cluster_runs)
    data = bytes(img.data)
    say(f"fragmented MAIN PAK: start_cluster={new_start} clusters={n} segments={len(segs)}")
    for i, (s, length) in enumerate(segs):
        if i == 16 and len(segs) > 32:
            say(f"  ... {len(segs) - 32} segments omitted ...")
            continue
        if len(segs) > 32 and 16 <= i < len(segs) - 16:
            continue
        say(f"  seg[{i}]: clusters {s}..{s + length - 1} ({length})")

    emu = ZumaFullZ80Emulator()
    sym = emu.sym
    emu.mem.pages[3] = 0x40
    sd_read = sym["Core.sd_read_sector"]

    def ix_of() -> int:
        return (emu.reg.IX & 0xFFFF) if hasattr(emu.reg, "IX") else ((emu.reg.IXH << 8) | emu.reg.IXL) & 0xFFFF

    def hook_ret(cf: bool = False) -> None:
        sp = emu.reg.SP
        ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
        emu.reg.SP = (sp + 2) & 0xFFFF
        emu.reg.PC = ret
        emu.reg.F = (emu.reg.F | 1) if cf else (emu.reg.F & ~1)

    orig = emu.step

    def hooked():
        if emu.reg.PC == sd_read:
            lba = (emu.reg.L | (emu.reg.H << 8)) | ((emu.reg.E | (emu.reg.D << 8)) << 16)
            ix = ix_of()
            chunk = data[lba * 512:lba * 512 + 512]
            chunk += b"\x00" * (512 - len(chunk))
            for off, b in enumerate(chunk):
                emu.set_byte((ix + off) & 0xFFFF, b)
            hook_ret(False)
            return 0
        return orig()

    emu.step = hooked
    emu.call(sym["Core.ZiFi_MainPakOpen"], max_steps=8_000_000)
    if not (emu.reg.F & 1):
        say("FAIL: ZiFi_MainPakOpen CF=0")
        return 1
    rc = emu.get_byte(sym["Core.RawPak_RunCount"])
    expected_rc = 0 if ns.cluster_runs else len(segs)
    say(f"ZiFi_MainPakOpen CF=1  RunCount={rc}  (expect {expected_rc})")
    if rc != expected_rc:
        say(f"FAIL: RunCount {rc} != expected {expected_rc}")
        return 1

    total_sec = len(pak_ref) // 512
    samples = sorted(set([0, 1, 31, 32, 33, 255, 256, total_sec // 2, total_sec - 2, total_sec - 1]))
    bad = 0
    for n_sec in samples:
        emu.set_word(sym["Core.RawPak_LogCur"], n_sec)
        if hasattr(emu.reg, "IX"):
            emu.reg.IX = 0x8000
        else:
            emu.reg.IXH, emu.reg.IXL = 0x80, 0x00
        emu.call(sym["Core.RawPak_ReadOneLogicalIX"], max_steps=2_000_000)
        got = bytes(emu.get_memory(0x8000, 512))
        exp = pak_ref[n_sec * 512:n_sec * 512 + 512]
        ok = got == exp
        bad += 0 if ok else 1
        say(f"  logical sec {n_sec:5d}: {'OK' if ok else 'MISMATCH'}")
    if bad:
        say(f"FAIL: {bad} sampled sectors mismatched")
        return 1

    say("running OVL_LoadMainPack...")
    emu = ZumaFullZ80Emulator()
    sym = emu.sym
    emu.mem.pages[3] = 0x40
    sd_read = sym["Core.sd_read_sector"]
    orig = emu.step
    hooks = {}
    for name in [
        "Core.sd_init",
        "Core.ZiFi_Done",
        "Core.BootProgressSetA",
        "Core.BootProgressInc",
        "Core.BootProgressIncNoDraw",
        "Core.BootLoadingTick",
        "Core.BootLoadingTickSafe",
    ]:
        if name in sym:
            hooks[sym[name]] = lambda: hook_ret(False)

    def hooked_full():
        if emu.reg.PC == sym["Core.RawPak_ReadOneLogicalIX"]:
            cur = emu.get_word(sym["Core.RawPak_LogCur"])
            if cur >= total_sec:
                left = emu.get_byte(sym.get("Core.MainPakPagesLeft", 0)) if "Core.MainPakPagesLeft" in sym else -1
                target = emu.get_byte(sym.get("Core.MainPakTargetPage", 0)) if "Core.MainPakTargetPage" in sym else -1
                say(f"watch: ReadOneLogicalIX with logcur={cur} total={total_sec} pages_left={left} target=#{target:02X}")
        h = hooks.get(emu.reg.PC)
        if h:
            h()
            return 0
        if emu.reg.PC == sd_read:
            lba = (emu.reg.L | (emu.reg.H << 8)) | ((emu.reg.E | (emu.reg.D << 8)) << 16)
            ix = ix_of()
            chunk = data[lba * 512:lba * 512 + 512]
            chunk += b"\x00" * (512 - len(chunk))
            for off, b in enumerate(chunk):
                emu.set_byte((ix + off) & 0xFFFF, b)
            hook_ret(False)
            return 0
        return orig()

    emu.step = hooked_full
    emu.call(sym["Core.OVL_LoadMainPack"], max_steps=25_000_000)
    if not (emu.reg.F & 1):
        left = emu.get_byte(sym.get("Core.MainPakPagesLeft", 0)) if "Core.MainPakPagesLeft" in sym else -1
        target = emu.get_byte(sym.get("Core.MainPakTargetPage", 0)) if "Core.MainPakTargetPage" in sym else -1
        logcur = emu.get_word(sym["Core.RawPak_LogCur"]) if "Core.RawPak_LogCur" in sym else -1
        rc2 = emu.get_byte(sym["Core.RawPak_RunCount"]) if "Core.RawPak_RunCount" in sym else -1
        say(f"diag: pages_left={left} target_page=#{target:02X} logcur={logcur} run_count={rc2}")
        say("FAIL: OVL_LoadMainPack CF=0")
        return 1

    final_pages: dict[int, int] = {}
    duplicate_writes = 0
    for page, sector in table:
        if page in final_pages:
            duplicate_writes += 1
        final_pages[page] = sector

    mismatches = []
    for page, sector in final_pages.items():
        off = sector * 512
        exp = pak_ref[off:off + PAGE_SIZE]
        got = bytes(emu.mem.physical[page * PAGE_SIZE:(page + 1) * PAGE_SIZE])
        if got != exp:
            mismatches.append((page, sector))
            if len(mismatches) >= 8:
                break
    say(f"OVL_LoadMainPack CF=1  checked_pages={len(final_pages)} "
        f"duplicate_writes={duplicate_writes} mismatches={len(mismatches)}")
    if mismatches:
        for page, sector in mismatches:
            say(f"  MISMATCH page=#{page:02X} sector={sector}")
        return 1

    say("\nPASS: fragmented ZUMAMAIN.PAK loads byte-for-byte correctly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
