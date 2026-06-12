#!/usr/bin/env python3
"""Trace-first full-stack harness for the VDAC2 Zuma build.

This is not a pixel renderer. Its job is to run the current SPG layout with one
coherent model for Z80 paging, FT812 asset transfer, and ZiFi pack reads, then
produce a useful crash report instead of another manual dump autopsy.
"""
from __future__ import annotations

import argparse
import collections
import re
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import PAGE_SIZE, PROJECT_ROOT, RETURN_MARKER, ZumaFullZ80Emulator, parse_num  # noqa: E402


def hx(value: int, width: int = 4) -> str:
    return f"#{value:0{width}X}"


def asc(data: bytes) -> str:
    return "".join(chr(x) if 32 <= x < 127 else "." for x in data)


def u16(data: bytes, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def ret_from_hook(emu: ZumaFullZ80Emulator, carry: bool = False) -> None:
    sp = emu.reg.SP
    ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
    emu.reg.SP = (sp + 2) & 0xFFFF
    emu.reg.PC = ret
    if carry:
        emu.reg.F |= 0x01
    else:
        emu.reg.F &= ~0x01


@dataclass(frozen=True)
class BlockInfo:
    page: int
    offset: int
    path: Path
    line: int


class PageCatalog:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.blocks: list[BlockInfo] = []
        self.by_page: dict[int, list[BlockInfo]] = {}
        rx = re.compile(r"Block\s*=\s*#([0-9A-Fa-f]+)\s*,\s*#([0-9A-Fa-f]{2})\s*,\s*(.+)$")
        for lineno, line in enumerate((root / "spgbld_vdac2.ini").read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = rx.search(line)
            if not m:
                continue
            off = int(m.group(1), 16) & 0x3FFF
            page = int(m.group(2), 16)
            path = root / m.group(3).strip()
            info = BlockInfo(page=page, offset=off, path=path, line=lineno)
            self.blocks.append(info)
            data_len = path.stat().st_size if path.exists() else 0
            first_phys = page * PAGE_SIZE + off
            last_phys = first_phys + max(0, data_len - 1)
            for pg in range(first_phys // PAGE_SIZE, last_phys // PAGE_SIZE + 1):
                self.by_page.setdefault(pg & 0xFF, []).append(info)

    def describe_page(self, page: int) -> str:
        rows = self.by_page.get(page & 0xFF, [])
        if not rows:
            return f"page {hx(page, 2)}: no spgbld owner"
        parts = []
        for r in rows[:3]:
            rel = r.path.relative_to(self.root) if r.path.exists() or str(r.path).startswith(str(self.root)) else r.path
            parts.append(f"line {r.line} {rel}")
        suffix = "" if len(rows) <= 3 else f" (+{len(rows)-3} more)"
        return f"page {hx(page, 2)}: " + "; ".join(str(p) for p in parts) + suffix

    def identify_slot_prefix(self, emu: ZumaFullZ80Emulator, addr: int, limit: int = 256) -> str:
        best: tuple[int, BlockInfo | None] = (0, None)
        for info in self.blocks:
            if not info.path.exists():
                continue
            data = info.path.read_bytes()
            page_off = addr & 0x3FFF
            file_off = page_off - info.offset
            if file_off < 0 or file_off >= len(data):
                continue
            n = min(limit, len(data) - file_off)
            same = 0
            for i in range(n):
                if emu.mem.read(addr + i) != data[file_off + i]:
                    break
                same += 1
            if same > best[0]:
                best = (same, info)
        if best[1] is None or best[0] < 8:
            return "no prefix match"
        rel = best[1].path.relative_to(self.root)
        return f"{best[0]}/{limit} bytes match {rel} (declared page {hx(best[1].page, 2)}, line {best[1].line})"

    def audit_loaded_blocks(self, emu: ZumaFullZ80Emulator) -> list[str]:
        issues: list[str] = []
        for info in self.blocks:
            if not info.path.exists():
                issues.append(f"missing block file: {info.path}")
                continue
            data = info.path.read_bytes()
            phys = info.page * PAGE_SIZE + info.offset
            actual = bytes(emu.mem.physical[phys : phys + len(data)])
            if actual != data:
                issues.append(
                    f"mismatch page {hx(info.page,2)} off {hx(info.offset)} "
                    f"line {info.line}: {info.path.relative_to(self.root)}"
                )
        return issues


class FakeZiFiDevice:
    def __init__(self, pak_path: Path) -> None:
        self.pak = pak_path.read_bytes() if pak_path.exists() else b""
        self.pos_sector = 0
        self.opened = bool(self.pak)

    def seek0(self) -> None:
        self.pos_sector = 0

    def skip(self, sectors: int) -> None:
        self.pos_sector += sectors

    def load512(self, sectors: int) -> bytes:
        start = self.pos_sector * 512
        size = sectors * 512
        data = self.pak[start : start + size]
        if len(data) < size:
            data += bytes(size - len(data))
        self.pos_sector += sectors
        return data


class FullStackTrace:
    def __init__(self, root: Path, *, irq_mode: str = "none", shadow_ft812: bool = False, real_inflate: bool = False) -> None:
        self.root = root
        self.emu = ZumaFullZ80Emulator(root)
        self.shadow_regs = None
        if shadow_ft812:
            from shadow_ft812 import attach_shadow

            self.shadow_regs = attach_shadow(self.emu)
        self.sym = self.emu.sym
        self.catalog = PageCatalog(root)
        self.zifi = FakeZiFiDevice(root / "Build" / "ZUMALVL.PAK")
        self.raw_img = root / "Build" / "test_wc.img"
        self.irq_mode = irq_mode
        self.real_inflate = real_inflate
        self.step_no = 0
        self.events: collections.deque[str] = collections.deque(maxlen=512)
        self.pcs: collections.deque[tuple[int, int, tuple[int, int, int, int]]] = collections.deque(maxlen=4096)
        self.last_pages = tuple(self.emu.mem.pages)
        self.in_inflate = False
        self.inflate_calls: list[tuple[int, int, int, int, int]] = []
        self.zifi_calls: list[str] = []
        self._install_hooks()

    def event(self, text: str) -> None:
        self.events.append(f"{self.step_no:09d} PC={hx(self.emu.reg.PC)} {text}")

    def _install_hooks(self) -> None:
        self.orig_step = self.emu.step

        def hooked_step() -> int:
            pc = self.emu.reg.PC
            self.pcs.append((self.step_no, pc, tuple(self.emu.mem.pages)))
            if self._hook_pc(pc):
                self.step_no += 1
                self._after_step_pages()
                return 0
            op = self.emu.mem.read(pc)
            if op == 0x76:
                raise RuntimeError(f"HALT opcode about to execute at {hx(pc)}")
            t = self.orig_step()
            self.step_no += 1
            self._after_step_pages()
            return t

        self.emu.step = hooked_step

    def _ix(self) -> int:
        reg = self.emu.reg
        if hasattr(reg, "IX"):
            return reg.IX & 0xFFFF
        return ((reg.IXH << 8) | reg.IXL) & 0xFFFF

    def _after_step_pages(self) -> None:
        cur = tuple(self.emu.mem.pages)
        if cur != self.last_pages:
            self.event("MMU " + " ".join(f"s{i}:{hx(a,2)}->{hx(b,2)}" for i, (a, b) in enumerate(zip(self.last_pages, cur)) if a != b))
            self.last_pages = cur
        if self.irq_mode == "inflate-slot3" and self.in_inflate and self.emu.mem.pages[3] != 0x04:
            self.event("IRQ_PROBE while PAGE3 is non-code")
            # Model the failure mode we care about: an interrupt/main1 fetch while
            # slot 3 still contains a source stream. Report immediately.
            raise RuntimeError(f"IRQ probe saw PAGE3={hx(self.emu.mem.pages[3], 2)} during Inflate")
        if self.irq_mode == "inflate-slot3" and self.real_inflate:
            inflate = self.sym.get("FT.Coprocessor.Inflate", 0x1474)
            # Current TSLib Inflate body is compact; this catches the real
            # body after SetPage3_A, not just the shortcut hook.
            if inflate <= self.emu.reg.PC <= inflate + 0x80 and self.emu.mem.pages[3] != 0x04:
                self.event("IRQ_PROBE in real Inflate while PAGE3 is non-code")
                raise RuntimeError(f"IRQ probe saw PAGE3={hx(self.emu.mem.pages[3], 2)} at PC={hx(self.emu.reg.PC)}")

    def _hook_pc(self, pc: int) -> bool:
        zifi_simple = {
            "Core.ZiFi_Init",
            "Core.ZiFi_Done",
            "Core.ZiFi_Enter",
            "Core.ZiFi_Leave",
        }
        for name in zifi_simple:
            if pc == self.sym.get(name):
                self._hook_zifi_ok(name)
                return True
        if pc == self.sym.get("Core.ZiFi_PakOpen"):
            self._hook_zifi_pak_open("Core.ZiFi_PakOpen")
            return True
        if pc == self.sym.get("Core.ZiFi_Seek0"):
            self._hook_zifi_seek0("Core.ZiFi_Seek0")
            return True
        if pc == self.sym.get("Core.ZiFi_SkipSectors16"):
            self._hook_zifi_skip("Core.ZiFi_SkipSectors16")
            return True
        if pc == self.sym.get("Core.ZiFi_PakReadToc"):
            self._hook_zifi_pak_read_toc("Core.ZiFi_PakReadToc")
            return True
        if pc == self.sym.get("Core.ZiFi_Load512"):
            self._hook_zifi_load512("Core.ZiFi_Load512")
            return True
        if pc == self.sym.get("Core.RawPak_ReadOneLogicalIX"):
            self._hook_rawpak_read_one_logical_ix()
            return True
        if pc == self.sym.get("Core.sd_init"):
            self._hook_sd_init()
            return True
        if pc == self.sym.get("Core.sd_read_sector"):
            self._hook_sd_read_sector()
            return True
        if pc == self.sym.get("FT.Coprocessor.Inflate"):
            if not self.real_inflate:
                self._hook_inflate()
                return True
            self.event(f"ENTER real INFLATE pages={tuple(self.emu.mem.pages)}")
            return False
        if self.real_inflate:
            for name in ("FT.Coprocessor.WaitFlush", "FT.Coprocessor.IsFault", "FT.Coprocessor.Wait"):
                if pc == self.sym.get(name):
                    self.event(f"{name} -> OK")
                    ret_from_hook(self.emu, carry=False)
                    return True
            if pc == self.sym.get("FT.Coprocessor.Write32"):
                self._hook_copro_write32()
                return True
        if self.real_inflate and pc == self.sym.get("FT.Coprocessor.Write"):
            self._hook_copro_write()
            return True
        if pc == self.sym.get("FT.WriteMem"):
            self._hook_write_mem()
            return True
        return False

    def _hook_inflate(self) -> None:
        dest = (self.emu.reg.A << 16) | (self.emu.reg.D << 8) | self.emu.reg.E
        size_lo = (self.emu.reg.B << 8) | self.emu.reg.C
        size_hi = self.emu.reg["B_"]
        size_hint = ((size_hi << 16) | size_lo) & 0xFFFFFF
        src_page = self.emu.reg["A_"]
        src_off = (self.emu.reg.H << 8) | self.emu.reg.L
        entry_pages = tuple(self.emu.mem.pages)
        self.event(f"INFLATE src={hx(src_page,2)}:{hx(src_off)} dest={hx(dest,6)} size_hint={size_hint} entry_pages={entry_pages}")

        self.in_inflate = True
        old_page3 = self.emu.mem.pages[3]
        try:
            # Expose source page like TSLib does, so IRQ probes and page traces
            # see the dangerous window.
            self.emu.mem.pages[3] = src_page & 0xFF
            self._after_step_pages()
            phys = (src_page & 0xFF) * PAGE_SIZE + (src_off & 0x3FFF)
            raw = bytes(self.emu.mem.physical[phys : phys + 256_000])
            dec = zlib.decompress(raw)
            end = min(dest + len(dec), len(self.emu.ft.ram_g))
            if 0 <= dest < len(self.emu.ft.ram_g):
                self.emu.ft.ram_g[dest:end] = dec[: end - dest]
            self.inflate_calls.append((src_page, src_off, dest, len(dec), old_page3))
        finally:
            self.emu.mem.pages[3] = 0x04
            self.in_inflate = False
            self._after_step_pages()
        ret_from_hook(self.emu, carry=False)

    def _hook_write_mem(self) -> None:
        # TSLib convention used in this project: A:DE = FT dest, HL = CPU source,
        # BC = length. This is enough for bg/font raw uploads.
        dest = (self.emu.reg.A << 16) | (self.emu.reg.D << 8) | self.emu.reg.E
        src = (self.emu.reg.H << 8) | self.emu.reg.L
        size = (self.emu.reg.B << 8) | self.emu.reg.C
        self.event(f"WRITEMEM src={hx(src)} dest={hx(dest,6)} size={size} pages={tuple(self.emu.mem.pages)}")
        if 0 <= dest < len(self.emu.ft.ram_g):
            data = bytes(self.emu.mem.read((src + i) & 0xFFFF) for i in range(size))
            end = min(dest + size, len(self.emu.ft.ram_g))
            self.emu.ft.ram_g[dest:end] = data[: end - dest]
        ret_from_hook(self.emu, carry=False)

    def _hook_copro_write(self) -> None:
        # Used by real TSLib Inflate. It streams BC bytes from HL (normally
        # #C000 with PAGE3 set to source page) into FT RAM_CMD. For CPU/MMU
        # diagnosis we do not need exact FIFO timing; we do need to keep the
        # source reads and page state real.
        src = (self.emu.reg.H << 8) | self.emu.reg.L
        size = (self.emu.reg.B << 8) | self.emu.reg.C
        self.event(f"COPRO_WRITE src={hx(src)} size={size} pages={tuple(self.emu.mem.pages)}")
        _ = bytes(self.emu.mem.read((src + i) & 0xFFFF) for i in range(size))
        # Return with CF=0 as successful FIFO write.
        ret_from_hook(self.emu, carry=False)

    def _hook_copro_write32(self) -> None:
        value = (self.emu.reg.H << 24) | (self.emu.reg.L << 16) | (self.emu.reg.D << 8) | self.emu.reg.E
        self.event(f"COPRO_WRITE32 value={hx(value,8)}")
        ret_from_hook(self.emu, carry=False)

    def _hook_zifi_ok(self, name: str) -> None:
        # Model the real ZiFi.asm slot-0 page behaviour, otherwise the harness
        # leaves PAGE0 on the driver page and any later CALL into a TSLib slot-0
        # routine (UnpackAndUploadPage, FT.*) NOP-slides into the driver page.
        # Real ZiFi_Init maps slot0=#0F (driver); real ZiFi_Done restores #00.
        if name == "Core.ZiFi_Init":
            self.emu.mem.pages[0] = 0x0F
        elif name == "Core.ZiFi_Done":
            self.emu.mem.pages[0] = 0x00
        self.zifi_calls.append(name)
        self.event(f"{name} -> CF=1 pages={tuple(self.emu.mem.pages)}")
        ret_from_hook(self.emu, carry=True)

    def _hook_sd_init(self) -> None:
        sd_blkt = self.sym.get("Core.sd_blkt")
        if sd_blkt is not None:
            self.emu.mem.write(sd_blkt, 0)
        self.event("sd_init -> CF=0")
        ret_from_hook(self.emu, carry=False)

    def _hook_sd_read_sector(self) -> None:
        lba = (self.emu.reg.L | (self.emu.reg.H << 8)) | ((self.emu.reg.E | (self.emu.reg.D << 8)) << 16)
        ix = self._ix()
        data = b""
        if self.raw_img.exists():
            with self.raw_img.open("rb") as f:
                f.seek(lba * 512)
                data = f.read(512)
        if len(data) < 512:
            data += bytes(512 - len(data))
        for i, value in enumerate(data):
            self.emu.mem.write((ix + i) & 0xFFFF, value)
        self.event(f"sd_read_sector lba={lba} -> {hx(ix)}")
        ret_from_hook(self.emu, carry=False)

    def _hook_zifi_pak_open(self, name: str) -> None:
        self.zifi_calls.append(name)
        ok = self.zifi.opened
        self.event(f"{name} -> {'CF=1' if ok else 'CF=0'}")
        ret_from_hook(self.emu, carry=ok)

    def _hook_zifi_seek0(self, name: str) -> None:
        self.zifi.seek0()
        self.zifi_calls.append(name)
        self.event(f"{name}")
        ret_from_hook(self.emu, carry=True)

    def _hook_zifi_skip(self, name: str) -> None:
        sectors = (self.emu.reg.H << 8) | self.emu.reg.L
        self.zifi.skip(sectors)
        self.zifi_calls.append(f"{name}({sectors})")
        self.event(f"{name} sectors={sectors} pos={self.zifi.pos_sector}")
        ret_from_hook(self.emu, carry=True)

    def _hook_zifi_pak_read_toc(self, name: str) -> None:
        level = self.emu.reg.A & 0xFF
        self.zifi.seek0()
        self.zifi.skip(1)
        toc = self.zifi.load512(1)
        entry = toc[level * 20 : level * 20 + 20]
        if len(entry) < 20 or entry[:2] == b"\xFF\xFF":
            self.event(f"{name} level={level} -> CF=0")
            ret_from_hook(self.emu, carry=False)
            return
        toc_addr = self.sym["Core.ZiFi_LevelTOC"]
        for i, b in enumerate(entry):
            self.emu.mem.write(toc_addr + i, b)
        self.zifi_calls.append(f"{name}(level={level})")
        self.event(f"{name} level={level} -> CF=1 toc={entry.hex(' ')}")
        ret_from_hook(self.emu, carry=True)

    def _hook_zifi_load512(self, name: str) -> None:
        # WC TS-DOS LOAD512 convention (verified vs WC load_ini reading zifi.ini):
        #   C = destination PAGE, HL = offset within page, B = 512-byte blocks.
        # Writes B*512 bytes from the file chain to physical (page C : offset HL),
        # auto-advancing the page when offset crosses #4000. Model it that way.
        sectors = self.emu.reg.B or 1
        page = self.emu.reg.C
        off = ((self.emu.reg.H << 8) | self.emu.reg.L) & 0x3FFF
        data = self.zifi.load512(sectors)
        phys = ((page & 0xFF) * PAGE_SIZE) + off
        end = min(phys + len(data), len(self.emu.mem.physical))
        self.emu.mem.physical[phys:end] = data[: end - phys]
        self.zifi_calls.append(f"{name}({sectors}, page={hx(page,2)}:{hx(off)})")
        self.event(f"{name} sectors={sectors} -> page={hx(page,2)}:{hx(off)} pos={self.zifi.pos_sector}")
        ret_from_hook(self.emu, carry=True)

    def _hook_rawpak_read_one_logical_ix(self) -> None:
        log_addr = self.sym["Core.RawPak_LogCur"]
        sector = self.emu.mem.read(log_addr) | (self.emu.mem.read(log_addr + 1) << 8)
        ix = self._ix()
        start = sector * 512
        data = self.zifi.pak[start : start + 512]
        if len(data) < 512:
            data += bytes(512 - len(data))
        for i, value in enumerate(data):
            self.emu.mem.write((ix + i) & 0xFFFF, value)
        next_sector = (sector + 1) & 0xFFFF
        self.emu.mem.write(log_addr, next_sector & 0xFF)
        self.emu.mem.write(log_addr + 1, next_sector >> 8)
        self.zifi_calls.append(f"Core.RawPak_ReadOneLogicalIX(sec={sector}, ix={hx(ix)})")
        self.event(f"RawPak_ReadOneLogicalIX sector={sector} -> IX={hx(ix)}")
        ret_from_hook(self.emu, carry=True)

    def call(self, sym_name: str, max_steps: int = 10_000_000) -> None:
        addr = self.sym[sym_name]
        sp = (self.emu.reg.SP - 2) & 0xFFFF
        self.emu.set_word(sp, RETURN_MARKER)
        self.emu.reg.SP = sp
        self.emu.reg.PC = addr
        self.event(f"CALL {sym_name} {hx(addr)}")
        while self.emu.reg.PC != RETURN_MARKER:
            if self.step_no >= max_steps:
                raise TimeoutError(f"timeout in {sym_name} at PC={hx(self.emu.reg.PC)}")
            self.emu.step()
        self.event(f"RET {sym_name}")

    def run_entry(self, max_steps: int) -> None:
        self.event(f"ENTRY {hx(self.emu.reg.PC)}")
        while self.step_no < max_steps:
            self.emu.step()
        raise TimeoutError(f"entry run reached {max_steps} steps at PC={hx(self.emu.reg.PC)}")

    def report(self, exc: BaseException | None = None) -> None:
        emu = self.emu
        print()
        print("=== FULL STACK TRACE REPORT ===")
        if exc:
            print(f"STOP: {type(exc).__name__}: {exc}")
        print(f"steps={self.step_no} pc={hx(emu.reg.PC)} sp={hx(emu.reg.SP)} pages=" + ",".join(hx(p, 2) for p in emu.mem.pages))
        print(f"A={hx(emu.reg.A,2)} F={hx(emu.reg.F,2)} BC={hx((emu.reg.B<<8)|emu.reg.C)} DE={hx((emu.reg.D<<8)|emu.reg.E)} HL={hx((emu.reg.H<<8)|emu.reg.L)}")
        for slot, base in enumerate((0x0000, 0x4000, 0x8000, 0xC000)):
            print(f"slot{slot} {hx(base)} page={hx(emu.mem.pages[slot],2)}  {self.catalog.describe_page(emu.mem.pages[slot])}")
            print(f"  visible: {self.catalog.identify_slot_prefix(emu, base)}")
            print(f"  bytes:   {bytes(emu.mem.read(base+i) for i in range(16)).hex(' ')}")
        print()
        print("Recent events:")
        for line in list(self.events)[-80:]:
            print("  " + line)
        print()
        print("Recent PC transitions:")
        for step, pc, pages in list(self.pcs)[-40:]:
            print(f"  {step:09d} pc={hx(pc)} pages=" + ",".join(hx(p, 2) for p in pages))
        print()
        print("Inflate calls:")
        for src_page, src_off, dest, dec_len, old_p3 in self.inflate_calls[-32:]:
            print(f"  src={hx(src_page,2)}:{hx(src_off)} dest={hx(dest,6)} dec={dec_len} old_page3={hx(old_p3,2)}")
        print("ZiFi calls:")
        for line in self.zifi_calls[-32:]:
            print("  " + line)
        for name in ("Core.ZiFi_GpDbgStep", "Core.CurrentLevel", "Core.CurrentDifficulty", "Core.FadeAlpha", "Core.ZiFi_BgDstPage"):
            addr = self.sym.get(name)
            if addr is not None:
                print(f"{name}@{hx(addr)}={hx(emu.mem.read(addr),2)}")
        toc = self.sym.get("Core.ZiFi_LevelTOC")
        if toc is not None:
            data = bytes(emu.mem.read(toc+i) for i in range(20))
            print(f"ZiFi_LevelTOC={data.hex(' ')}")
            if any(data):
                vals = struct.unpack("<10H", data)
                print(f"  toc words={vals}")
        if self.shadow_regs is not None:
            try:
                from shadow_ft812 import REG_CMD_READ, REG_CMD_WRITE, REG_DLSWAP, REG_FRAMES, REG_INT_FLAGS

                regs = self.shadow_regs
                print("Shadow FT812:")
                print(
                    f"  frames={regs._get32(REG_FRAMES)} dlswap={regs._get32(REG_DLSWAP)} "
                    f"int_flags={regs._get32(REG_INT_FLAGS):02X} "
                    f"cmd_read={regs._get32(REG_CMD_READ):04X} cmd_write={regs._get32(REG_CMD_WRITE):04X} "
                    f"swaps={regs.swap_count}"
                )
            except Exception as exc:
                print(f"Shadow FT812 report failed: {exc}")

    def audit_spg_layout(self) -> int:
        print("=== SPG LAYOUT AUDIT ===")
        print(f"entry PC={hx(self.emu.reg.PC)}  SP={hx(self.emu.reg.SP)}")
        print("pages=" + ",".join(hx(p, 2) for p in self.emu.mem.pages))
        for slot, base in enumerate((0x0000, 0x4000, 0x8000, 0xC000)):
            print(f"slot{slot} {hx(base)} page={hx(self.emu.mem.pages[slot],2)}  {self.catalog.describe_page(self.emu.mem.pages[slot])}")
            print(f"  {self.catalog.identify_slot_prefix(self.emu, base)}")
        issues = self.catalog.audit_loaded_blocks(self.emu)
        print(f"blocks={len(self.catalog.blocks)} checked")
        if issues:
            print("FAIL:")
            for issue in issues[:20]:
                print(f"  {issue}")
            if len(issues) > 20:
                print(f"  ... +{len(issues)-20} more")
            return 1
        print("PASS: all spgbld_vdac2.ini blocks match emulator physical pages")
        return 0

    def rawpak_boundary_test(self) -> int:
        print("=== RAWPAK 16K BOUNDARY TEST ===")
        self.call("Core.RawPak_OpenRoot", 2_000_000)
        if not (self.emu.reg.F & 1):
            print(f"FAIL: RawPak_OpenRoot CF=0 openStep={hx(self.emu.mem.read(self.sym['Core.ZiFi_DbgGamesA']),2)}")
            return 1
        self.call("Core.RawPak_Seek0", 100_000)
        self.emu.reg.B = 4
        self.emu.reg.C = 0x20
        self.emu.reg.H = 0x3E
        self.emu.reg.L = 0x00
        self.call("Core.RawPak_ReadSectors", 1_000_000)
        if self.emu.reg.F & 1:
            print("FAIL: RawPak_ReadSectors returned CF=1")
            return 1
        got = (
            bytes(self.emu.mem.physical[0x20 * PAGE_SIZE + 0x3E00 : 0x20 * PAGE_SIZE + 0x4000])
            + bytes(self.emu.mem.physical[0x21 * PAGE_SIZE : 0x21 * PAGE_SIZE + 0x0600])
        )
        want = (self.root / "Build" / "ZUMALVL.PAK").read_bytes()[: 4 * 512]
        if got != want:
            diff = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), -1)
            print(f"FAIL: boundary data mismatch at {hx(diff,4)} got={hx(got[diff],2)} want={hx(want[diff],2)}")
            return 1
        dst_page = self.emu.mem.read(self.sym["Core.RawPak_DstPage"])
        dst_off = self.emu.get_word(self.sym["Core.RawPak_DstOff"])
        print(f"PASS: 4 sectors crossed #3E00 -> page #21, final dst={hx(dst_page,2)}:{hx(dst_off)}")
        return 0


def diagnose_dump(root: Path, dump_path: Path) -> int:
    sym = ZumaFullZ80Emulator(root).sym
    data = dump_path.read_bytes()
    if len(data) != 65536:
        print(f"FAIL: dump must be 65536 bytes, got {len(data)}")
        return 1

    def sb(name: str, default: int | None = None) -> int:
        if name in sym:
            return data[sym[name]]
        if default is None:
            raise KeyError(name)
        return data[default]

    def sw(name: str) -> int:
        return u16(data, sym[name])

    def sdw(name: str) -> int:
        return u32(data, sym[name])

    print("=== DUMP DIAGNOSE ===")
    print(f"dump={dump_path} bytes={len(data)}")
    boot_addr = sym.get("BOOT_CANARY_ADDR", 0x5044)
    boot = data[boot_addr : boot_addr + 4]
    print(f"BOOT canary @{hx(boot_addr)} = {boot.hex(' ')} \"{asc(boot)}\"")
    if boot != b"BOOT":
        print("verdict: Core.Start did not run, or page #05 is not visible in slot1 in this dump")
    else:
        print("verdict: Core.Start ran")

    core_path = root / "Build" / "Core.bin"
    if core_path.exists():
        core = core_path.read_bytes()
        for base in (0x4000, 0x5000, 0x5C00):
            n = min(len(core), len(data) - base)
            same_prefix = 0
            while same_prefix < n and data[base + same_prefix] == core[same_prefix]:
                same_prefix += 1
            print(f"Core.bin prefix at {hx(base)}: {same_prefix}/{min(n, 64)} first bytes")

    for name in ("Core.ZiFi_GpDbgStep", "Core.ZiFi_DbgGamesA", "Core.ZiFi_DbgGamesFound", "Core.CurrentLevel"):
        if name in sym:
            print(f"{name}@{hx(sym[name])}={hx(sb(name),2)}")
    for name in ("Core.RawPak_Spc", "Core.RawPak_FatStart", "Core.RawPak_DataStart", "Core.RawPak_RootClus",
                 "Core.RawPak_FileStartClus", "Core.RawPak_CurClus", "Core.RawPak_PakLba", "Core.RawPak_LogCur"):
        if name in sym:
            if name.endswith(("Spc",)):
                print(f"{name}@{hx(sym[name])}={sb(name)}")
            elif name.endswith(("LogCur",)):
                print(f"{name}@{hx(sym[name])}={sw(name)}")
            else:
                print(f"{name}@{hx(sym[name])}={sdw(name)}")

    base = sym.get("Core.Dbg_DriverState")
    if base is not None and base + 96 <= len(data):
        bpb = data[base : base + 64]
        print("Dbg_DriverState BPB:")
        print(f"  hex={bpb[:32].hex(' ')}")
        print(f"  asc={asc(bpb[:32])}")
        print(f"  bps={u16(data, base+11)} spc={data[base+13]} reserved={u16(data, base+14)} fats={data[base+16]} "
              f"fatsz={u32(data, base+36)} root={u32(data, base+44)}")
        dbase = base + 64
        print("Dbg_DriverState dir entries:")
        for idx in range(3):
            e = dbase + idx * 32
            print(f"  {idx}: name=\"{asc(data[e:e+11])}\" attr={hx(data[e+11],2)} "
                  f"clus={((u16(data,e+20)<<16)|u16(data,e+26))} size={u32(data,e+28)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(PROJECT_ROOT))
    ap.add_argument(
        "--scenario",
        choices=[
            "entry",
            "levelselect-load",
            "preview-l18",
            "gameplay-load",
            "spg-audit",
            "rawpak-boundary",
            "dump-diagnose",
        ],
        default="levelselect-load",
    )
    ap.add_argument("--dump", default="111", help="64K RAM dump for --scenario dump-diagnose")
    ap.add_argument("--irq-mode", choices=["none", "inflate-slot3"], default="none")
    ap.add_argument("--shadow-ft812", action="store_true")
    ap.add_argument("--real-inflate", action="store_true", help="execute TSLib Inflate body; only hook lower Write calls")
    ap.add_argument("--max-steps", type=int, default=10_000_000)
    ns = ap.parse_args()

    root = Path(ns.root)
    if ns.scenario == "dump-diagnose":
        return diagnose_dump(root, Path(ns.dump))

    fs = FullStackTrace(root, irq_mode=ns.irq_mode, shadow_ft812=ns.shadow_ft812, real_inflate=ns.real_inflate)
    try:
        if ns.scenario == "spg-audit":
            return fs.audit_spg_layout()
        elif ns.scenario == "rawpak-boundary":
            return fs.rawpak_boundary_test()
        elif ns.scenario == "entry":
            fs.run_entry(ns.max_steps)
        elif ns.scenario == "levelselect-load":
            fs.call("Core.Init_Core", ns.max_steps)
            fs.call("Core.LoadLevelSelectAssets", ns.max_steps)
        elif ns.scenario == "preview-l18":
            fs.call("Core.Init_Core", ns.max_steps)
            fs.emu.set_byte(fs.sym["Core.CurrentLevel"], 17)
            fs.call("Core.LoadLevelSelectPreviewAssets", ns.max_steps)
        elif ns.scenario == "gameplay-load":
            fs.call("Core.Init_Core", ns.max_steps)
            fs.emu.set_byte(fs.sym["Core.CurrentLevel"], 1)
            fs.call("Core.LoadGameplayAssets", ns.max_steps)
        fs.report(None)
        return 0
    except BaseException as exc:
        fs.report(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
