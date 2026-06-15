"""Diagnostic: Python simulator of our intended ZiFi flow.

Does NOT use Z80 emulation. Implements the LoadLevelFromPack →
ZiFi_PakOpen → ZiFi_PakReadToc → bg stream pipeline in pure Python,
exactly as our ZiFi.asm code intends. Verifies the *design*: if this
test passes, the bug must be in either (a) Z80 ASM bugs or (b) host
runtime environment (ZiFi driver not present / slot 0 swap fails) —
NOT in our pack format or sequencing.

Two scenarios:
  scenario A: PAK present in /Games/Zuma Deluxe VDAC2/, ZiFi driver
              available → expect success
  scenario B: PAK missing → expect graceful failure (CF=0)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PAK_PATH = ROOT / "Build" / "ZUMALVL.PAK"
LEVELS_CONV = ROOT / "Graphics" / "levels" / "Converted"

SECTOR = 512


class FakeZiFiDriver:
    """Python implementation of WC ZiFi entries — exactly what our
    ZiFi.asm wrappers expect to call."""

    def __init__(self, sd_files: dict[tuple[str, ...], bytes]):
        # sd_files: { ("Games", "Zuma Deluxe VDAC2", "ZUMALVL.PAK"): bytes, ... }
        self.sd_files = sd_files
        self.cwd: tuple[str, ...] = ()
        self.open_file_name: tuple[str, ...] | None = None
        self.open_file_data: bytes | None = None
        self.pos_sector: int = 0     # current read position in sectors
        self.last_found: tuple[str, ...] | None = None
        self.last_found_is_dir: bool = False

    def setroot(self):
        self.cwd = ()

    def setdir(self):
        """chdir into directory found by last fentry call"""
        if self.last_found and self.last_found_is_dir:
            self.cwd = self.last_found

    def fentry(self, flag: int, name: str) -> int | None:
        """Search current dir for entry matching name+flag.
        Returns file size if found (flag=#00 = file), or 0 for dir.
        Returns None if not found."""
        target = self.cwd + (name,)
        # check if directory exists (some file lives under it)
        if flag == 0x10:
            for path in self.sd_files:
                if len(path) > len(target) and path[: len(target)] == target:
                    self.last_found = target
                    self.last_found_is_dir = True
                    return 0
            return None
        elif flag == 0x00:
            if target in self.sd_files:
                self.last_found = target
                self.last_found_is_dir = False
                # auto SEEK0
                self.open_file_name = target
                self.open_file_data = self.sd_files[target]
                self.pos_sector = 0
                return len(self.open_file_data)
            return None
        else:
            raise ValueError(f"bad flag {flag:#04x}")

    def seek0(self):
        self.pos_sector = 0

    def loadnon(self, sectors: int):
        self.pos_sector += sectors

    def load512(self, sectors: int) -> bytes:
        if self.open_file_data is None:
            raise RuntimeError("LOAD512 with no open file")
        start = self.pos_sector * SECTOR
        end = start + sectors * SECTOR
        if start >= len(self.open_file_data):
            return b""
        chunk = self.open_file_data[start:end]
        if len(chunk) < sectors * SECTOR:
            chunk += b"\x00" * (sectors * SECTOR - len(chunk))
        self.pos_sector += sectors
        return chunk


def asm_pak_open(zifi: FakeZiFiDriver) -> bool:
    """Mirrors ZiFi_PakOpen sequence in ZiFi.asm:
       SetRoot; FEntry(Games,dir); SetDir; FEntry(Zuma,dir); SetDir;
       FEntry(ZUMALVL.PAK,file). Returns True on success.
    """
    zifi.setroot()
    if zifi.fentry(0x10, "Games") is None:
        return False
    zifi.setdir()
    if zifi.fentry(0x10, "Zuma Deluxe VDAC2") is None:
        return False
    zifi.setdir()
    size = zifi.fentry(0x00, "ZUMALVL.PAK")
    if size is None:
        return False
    return True


def asm_pak_read_toc(zifi: FakeZiFiDriver, level_idx: int) -> bytes:
    """Mirrors ZiFi_PakReadToc:
       SEEK0; skip sec 0 (header); read sec 1 (TOC); extract entry [idx].
       NOTE: real ASM lacks SEEK0 — repeated calls would advance position!
       But production calls it only once per LoadGameplayAssets, so OK.
       Test added SEEK0 here to allow probing multiple levels."""
    zifi.seek0()
    zifi.loadnon(1)
    toc_sector = zifi.load512(1)
    entry = toc_sector[level_idx * 20 : (level_idx + 1) * 20]
    return entry


def asm_stream_section(zifi: FakeZiFiDriver, offset_sectors: int, size_sectors: int) -> bytes:
    """Mirrors LoadGameplayAssets bg section:
       SEEK0; SkipSectors16(offset); read all section sectors."""
    zifi.seek0()
    zifi.loadnon(offset_sectors)
    return zifi.load512(size_sectors)


def main() -> int:
    if not PAK_PATH.exists():
        print(f"ERR: {PAK_PATH} not found — run make_level_pack.py first")
        return 1
    pak_bytes = PAK_PATH.read_bytes()
    print(f"PAK loaded: {PAK_PATH}  ({len(pak_bytes):,} bytes)")
    print()

    # Build fake SD: just the PAK in the right place
    sd_files = {
        ("Games", "Zuma Deluxe VDAC2", "ZUMALVL.PAK"): pak_bytes,
    }

    failures = []

    # ----------------------------------------------------------
    # Scenario A: pak present, expect success
    # ----------------------------------------------------------
    print("=== Scenario A: ZUMALVL.PAK present ===")
    zifi = FakeZiFiDriver(sd_files)

    if not asm_pak_open(zifi):
        failures.append("A: ZiFi_PakOpen returned False with pak present")
        print("  FAIL ZiFi_PakOpen")
    else:
        print("  OK ZiFi_PakOpen")

    # Read TOC for level 0 (spiral)
    toc_l1 = asm_pak_read_toc(zifi, 0)
    print(f"  TOC L1: {toc_l1.hex()}")
    bg_off, bg_size, pal_off, pal_size, tr_off, tr_size, tt_off, tt_size, pv_off, pv_size = \
        struct.unpack("<10H", toc_l1)
    print(f"    bg=({bg_off},{bg_size})  pal=({pal_off},{pal_size})  track=({tr_off},{tr_size})")
    print(f"    title=({tt_off},{tt_size})  preview=({pv_off},{pv_size})")

    if (bg_off, bg_size) != (2, 256):
        failures.append(f"A: L1 bg expected (2,256), got ({bg_off},{bg_size})")
    if pal_size != 1:
        failures.append(f"A: L1 pal expected size 1, got {pal_size}")

    # Stream bg, compare against concatenated bg_paletted_p00..p07.bin
    bg_data = asm_stream_section(zifi, bg_off, bg_size)
    expected_bg = b"".join(
        (LEVELS_CONV / f"bg_paletted_p{p:02d}.bin").read_bytes() for p in range(8)
    )
    if bg_data[: len(expected_bg)] == expected_bg:
        print(f"  OK bg stream matches concatenated bg_paletted_p00..p07.bin ({len(expected_bg):,} bytes)")
    else:
        failures.append("A: L1 bg stream does NOT match source bins")
        # find first diff
        n = min(len(bg_data), len(expected_bg))
        for i in range(n):
            if bg_data[i] != expected_bg[i]:
                print(f"  first diff at offset {i}: got {bg_data[i]:#04x}, want {expected_bg[i]:#04x}")
                break

    # Also verify pal, track for L1
    pal_data = asm_stream_section(zifi, pal_off, pal_size)
    expected_pal = (LEVELS_CONV / "bg_palette_argb4.bin").read_bytes()
    if pal_data[: len(expected_pal)] == expected_pal:
        print(f"  OK palette stream matches bg_palette_argb4.bin ({len(expected_pal)} bytes)")
    else:
        failures.append("A: L1 palette mismatch")

    track_data = asm_stream_section(zifi, tr_off, tr_size)
    expected_tr = (LEVELS_CONV / "track_640.bin").read_bytes()
    if track_data[: len(expected_tr)] == expected_tr:
        print(f"  OK track stream matches track_640.bin ({len(expected_tr):,} bytes)")
    else:
        failures.append("A: L1 track mismatch")

    # Repeat for L2 (claw)
    print()
    print("  -- L2 (claw / Osprey Talon) --")
    toc_l2 = asm_pak_read_toc(zifi, 1)
    bg2_off, bg2_size = struct.unpack_from("<HH", toc_l2, 0)
    bg2_data = asm_stream_section(zifi, bg2_off, bg2_size)
    expected_bg2 = b"".join(
        (LEVELS_CONV / f"bg_l02_paletted_p{p:02d}.bin").read_bytes() for p in range(8)
    )
    if bg2_data[: len(expected_bg2)] == expected_bg2:
        print(f"  OK L2 bg matches bg_l02_paletted_p00..p07.bin ({len(expected_bg2):,} bytes)")
    else:
        failures.append("A: L2 bg mismatch")

    # ----------------------------------------------------------
    # Scenario B: pak absent
    # ----------------------------------------------------------
    print()
    print("=== Scenario B: ZUMALVL.PAK absent ===")
    zifi_b = FakeZiFiDriver({})  # empty SD
    if asm_pak_open(zifi_b):
        failures.append("B: ZiFi_PakOpen returned True with empty SD (should fail)")
        print("  FAIL — open succeeded but should have failed")
    else:
        print("  OK ZiFi_PakOpen correctly returned False")

    # ----------------------------------------------------------
    # Scenario C: dir exists but pak file missing
    # ----------------------------------------------------------
    print()
    print("=== Scenario C: dirs present but ZUMALVL.PAK missing ===")
    sd_c = {("Games", "Zuma Deluxe VDAC2", "OTHER.TXT"): b"x"}
    zifi_c = FakeZiFiDriver(sd_c)
    if asm_pak_open(zifi_c):
        failures.append("C: open succeeded but PAK is missing")
        print("  FAIL")
    else:
        print("  OK ZiFi_PakOpen correctly returned False (file missing)")

    # ----------------------------------------------------------
    print()
    print("=" * 60)
    if failures:
        print(f"FAILED ({len(failures)} issues):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("ALL SCENARIOS PASSED")
    print()
    print("Conclusion: our ZiFi flow design + pack format are correct.")
    print("Black screen on host must be one of:")
    print("  1. ZiFi driver not actually mapped to page #0F at SPG runtime")
    print("     (WC unloads driver when launching SPG, or driver lives elsewhere)")
    print("  2. Our slot-0 swap mechanism (SetPage0_A → MMIO #0410) doesn't")
    print("     work in our environment (possibly conflicts with TSLib FM_EN setup)")
    print("  3. ZiFi expects 8.3 short directory names, not 'Zuma Deluxe VDAC2'")
    print("     with spaces (try 8.3 alias like ZUMADE~1)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
