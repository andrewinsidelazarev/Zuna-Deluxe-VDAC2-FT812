#!/usr/bin/env python3
"""
Full-game Z80 harness for the Zuma VDAC2 build.

This is intentionally self-contained: it uses the bundled pure-Python
cburbridge Z80 core from Source/OTHER/_z80_lib_cburbridge instead of the
external kosarev/z80 package used by zuma_z80_simulator.py.

What is emulated:
  * Z80 instruction execution with 64K address space.
  * TS-Config 16K page registers for slots 0..3.
  * SPG blocks from spgbld_vdac2.ini, including graphics/track pages.
  * Port reads/writes used by TS-Config paging, Kempston input, RTC, VDAC2 SPI.
  * FT812 RAM_G/RAM_DL/RAM_CMD storage enough to let game code run and log IO.

What is not rendered here:
  * A real FT812 rasterizer. Display-list commands are captured/logged, not
    converted to pixels. Use this harness for CPU/game-state debugging.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent.parent
Z80_LIB = HERE / "_z80_lib_cburbridge" / "src"
RETURN_MARKER = 0xFFFE
PAGE_SIZE = 0x4000
NUM_PAGES = 256
RAM_G_SIZE = 1024 * 1024

sys.path.insert(0, str(Z80_LIB))
from z80 import instructions, registers, util  # noqa: E402


def parse_num(text: str) -> int:
    text = text.strip()
    if text.startswith("#"):
        return int(text[1:], 16)
    if text.lower().startswith("0x"):
        return int(text[2:], 16)
    return int(text, 10)


def parse_sym(path: Path) -> Dict[str, int]:
    syms: Dict[str, int] = {}
    rx = re.compile(r"^\s*([\w.]+):\s+EQU\s+([#$0-9A-Fa-fx]+)\s*$")
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = rx.match(line)
            if m:
                syms[m.group(1)] = parse_num(m.group(2))
    return syms


@dataclass
class InputState:
    mouse_x: int = 0
    mouse_y: int = 0
    mouse_buttons: int = 0x03
    kempston: int = 0x00
    keyboard_rows: Dict[int, int] = field(default_factory=dict)
    rtc_seconds_bcd: int = 0x17


@dataclass
class FT812State:
    ram_g: bytearray = field(default_factory=lambda: bytearray(RAM_G_SIZE))
    ram_dl: bytearray = field(default_factory=lambda: bytearray(8192))
    ram_cmd: bytearray = field(default_factory=lambda: bytearray(4096))
    int_flags: int = 0x01
    dlswap: int = 0
    cmd_write_ptr: int = 0
    cmd_read_ptr: int = 0
    spi_addr: Optional[int] = None
    spi_mode: str = "idle"
    spi_phase: int = 0
    spi_read_dummy: bool = False


@dataclass
class TSConfigDMAState:
    src_l: int = 0
    src_h: int = 0
    src_x: int = 0
    dst_l: int = 0
    dst_h: int = 0
    dst_x: int = 0
    length: int = 0
    number: int = 0
    status: int = 0


class TSConfigMemory:
    def __init__(self) -> None:
        self.physical = bytearray(NUM_PAGES * PAGE_SIZE)
        self.pages = [0x00, 0x05, 0x06, 0x04]

    def map_addr(self, addr: int) -> int:
        addr &= 0xFFFF
        slot = addr >> 14
        return (self.pages[slot] * PAGE_SIZE) + (addr & 0x3FFF)

    def read(self, addr: int) -> int:
        return self.physical[self.map_addr(addr)]

    def write(self, addr: int, value: int) -> None:
        self.physical[self.map_addr(addr)] = value & 0xFF

    def read_block(self, addr: int, length: int) -> bytes:
        return bytes(self.read(addr + i) for i in range(length))

    def write_block_linear(self, addr: int, data: bytes) -> None:
        for i, b in enumerate(data):
            self.write(addr + i, b)

    def load_page_block(self, page: int, offset: int, data: bytes) -> None:
        start = page * PAGE_SIZE + offset
        # spgbld keeps writing a Block into following 16K pages when the file
        # does not fit its first page. The harness must mirror that layout for
        # multi-page compressed streams used by menu assets.
        end = min(start + len(data), len(self.physical))
        self.physical[start:end] = data[: end - start]


class ZumaFullZ80Emulator:
    def __init__(self, root: Path = PROJECT_ROOT, trace: bool = False) -> None:
        self.root = Path(root)
        self.sym = parse_sym(self.root / "Build" / "zuma.sym")
        self.mem = TSConfigMemory()
        self.input = InputState()
        self.ft = FT812State()
        self.dma = TSConfigDMAState()
        self.trace = trace
        self.ports_out: List[Tuple[int, int]] = []
        self.ports_in: List[Tuple[int, int]] = []
        self.errors: List[str] = []
        self.tstates = 0

        self.reg = registers.Registers()
        with contextlib.redirect_stdout(io.StringIO()):
            self.ins = instructions.InstructionSet(self.reg)

        self._load_spg_blocks()
        self.reg.SP = parse_num(self._ini_scalar("Stack", "0x40F2"))
        self.reg.PC = self.sym.get("Core.Start", 0x6000)

    def _ini_scalar(self, key: str, default: str) -> str:
        ini = self.root / "spgbld_vdac2.ini"
        rx = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$", re.I)
        with ini.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = rx.match(line)
                if m:
                    return m.group(1).strip()
        return default

    def _load_spg_blocks(self) -> None:
        ini = self.root / "spgbld_vdac2.ini"
        rx = re.compile(r"^\s*Block\s*=\s*([^,]+),\s*([^,]+),\s*(.+?)\s*$", re.I)
        with ini.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = rx.match(line)
                if not m:
                    continue
                offset = parse_num(m.group(1)) & 0x3FFF
                page = parse_num(m.group(2)) & 0xFF
                rel = m.group(3).strip().replace("/", os.sep)
                path = self.root / rel
                if not path.exists():
                    self.errors.append(f"missing block file: {rel}")
                    continue
                data = path.read_bytes()
                self.mem.load_page_block(page, offset, data)

    def get_byte(self, addr: int) -> int:
        return self.mem.read(addr)

    def set_byte(self, addr: int, value: int) -> None:
        self.mem.write(addr, value)

    def get_word(self, addr: int) -> int:
        return self.get_byte(addr) | (self.get_byte(addr + 1) << 8)

    def set_word(self, addr: int, value: int) -> None:
        self.set_byte(addr, value)
        self.set_byte(addr + 1, value >> 8)

    def get_memory(self, addr: int, length: int) -> bytes:
        return self.mem.read_block(addr, length)

    def step(self) -> int:
        pc0 = self.reg.PC
        # Ring buffer of recent PCs for retro-analysis
        rb = getattr(self, '_pc_ring', None)
        if rb is not None:
            rb.append(pc0)
            if len(rb) > 4096:
                rb.pop(0)
        # Watchpoint for SetPage0 function entry — anything calling here
        # silently overwrites slot 0 mapping via LD (#0410), A.
        if pc0 == getattr(self, '_pc_watch', None):
            sp = self.reg.SP
            stk = []
            for i in range(0, 16, 2):
                w = self.mem.read((sp + i) & 0xFFFF) | (self.mem.read((sp + i + 1) & 0xFFFF) << 8)
                stk.append(f'{w:04X}')
            print(f"  [watch] PC=#{pc0:04X} entered  SP=#{sp:04X} stk=[{','.join(stk)}]  A={self.reg.A:#04x}")
            if rb is not None:
                # Filter sequential ranges; show only non-sequential transitions
                print(f"  [ring] last {len(rb)} PCs (non-sequential transitions only):")
                transitions = []
                for i in range(1, len(rb)):
                    if rb[i] != ((rb[i-1] + 1) & 0xFFFF) and rb[i] != ((rb[i-1] + 2) & 0xFFFF) and rb[i] != ((rb[i-1] + 3) & 0xFFFF):
                        transitions.append((rb[i-1], rb[i]))
                for prev, cur in transitions[-30:]:
                    print(f"    #{prev:04X} -> #{cur:04X}")
        ins, args = False, ()
        try:
            while not ins:
                op = self.mem.read(self.reg.PC)
                ins, args = self.ins << op
                self.reg.PC = util.inc16(self.reg.PC)
        except Exception as exc:
            raise RuntimeError(f"decode failed at PC=#{pc0:04X}: {exc}") from exc

        reads = ins.get_read_list(args)
        data = [self._read_ref(ref) for ref in reads]
        writes = ins.execute(data, args)
        for ref, value in writes:
            self._write_ref(ref, value)
        self.tstates += getattr(ins, "tstates", 0)
        if self.trace:
            print(f"{pc0:04X}: {ins.assembler(args)}")
        return getattr(ins, "tstates", 0)

    def run_until_pc(self, pc: int, max_steps: int = 2_000_000) -> int:
        steps = 0
        while self.reg.PC != pc:
            if steps >= max_steps:
                raise TimeoutError(f"timeout at PC=#{self.reg.PC:04X}, target=#{pc:04X}")
            self.step()
            steps += 1
        return steps

    def call(self, addr: int, *, a: int = 0, b: int = 0, c: int = 0, d: int = 0,
             e: int = 0, h: int = 0, l: int = 0, max_steps: int = 2_000_000) -> int:
        self.reg.A = a & 0xFF
        self.reg.B = b & 0xFF
        self.reg.C = c & 0xFF
        self.reg.D = d & 0xFF
        self.reg.E = e & 0xFF
        self.reg.H = h & 0xFF
        self.reg.L = l & 0xFF
        sp = (self.reg.SP - 2) & 0xFFFF
        self.set_word(sp, RETURN_MARKER)
        self.reg.SP = sp
        self.reg.PC = addr & 0xFFFF
        return self.run_until_pc(RETURN_MARKER, max_steps=max_steps)

    def game_init(self) -> None:
        self.call(self.sym["Core.Init_Core"])
        self.call(self.sym["Core.VDC_Init"])
        self.call(self.sym["Core.Frog_Init"])
        self.call(self.sym["Core.Bullet_Init"])

    def game_frame(self) -> None:
        for name in (
            "Core.ZL_AimUpdate",
            "Core.ZL_SmoothMouse",
            "Core.Frog_Update",
            "Core.VDC_Update",
            "Core.Bullet_Update",
            "Core.Bullet_CheckCollision",
            "Core.ZL_DrawFrame",
        ):
            if name in self.sym:
                self.call(self.sym[name])
        fc = self.sym.get("Core.ZL_FrameCounter")
        if fc is not None:
            self.set_word(fc, (self.get_word(fc) + 1) & 0xFFFF)

    def vdc_state(self) -> Dict[str, object]:
        slots_len = self.get_byte(self.sym["Core.VDC_SlotsLen"])
        slots = list(self.get_memory(self.sym["Core.VDC_Slots"], slots_len))
        raw_offsets = self.get_memory(self.sym["Core.VDC_Offsets"], slots_len)
        offsets = [b - 256 if b & 0x80 else b for b in raw_offsets]
        return {
            "hsa": self.get_byte(self.sym["Core.VDC_HSA"]),
            "hsub": self.get_byte(self.sym["Core.VDC_HSub"]),
            "slots_len": slots_len,
            "balls_spawned": self.get_byte(self.sym["Core.VDC_BallsSpawned"]),
            "slots": slots,
            "offsets": offsets,
            "page_map": list(self.mem.pages),
            "tstates": self.tstates,
        }

    @staticmethod
    def format_slots(slots: Iterable[int]) -> str:
        out = []
        for v in slots:
            if v == 0xFE:
                out.append("S")
            elif v == 0xFD:
                out.append("C")
            elif v == 0xFF:
                out.append(".")
            else:
                out.append(str(v))
        return "".join(out)

    def _read_ref(self, ref: int) -> int:
        if ref >= 0x10000:
            value = self.in_port(ref & 0xFFFF)
            self.ports_in.append((ref & 0xFFFF, value))
            return value
        return self.mem.read(ref)

    def _write_ref(self, ref: int, value: int) -> None:
        value &= 0xFF
        if ref >= 0x10000:
            self.out_port(ref & 0xFFFF, value)
            self.ports_out.append((ref & 0xFFFF, value))
        else:
            # FMADDR_REGS hook: when FT_EN active (MAPPING_REGISTERS mode),
            # memory writes to #0410..#0413 mirror to PAGE0..PAGE3 ports.
            # Real HW: TSLib SetPage* macros expand to LD (FMADDR_REGS+HIGH PAGEn), value.
            # FMADDR_REGS = #0400, HIGH PAGEn = #10..#13.
            if 0x0410 <= ref <= 0x0413:
                slot = ref - 0x0410
                old = self.mem.pages[slot]
                self.mem.pages[slot] = value & 0xFF
                if old != value and getattr(self, '_paging_trace', False):
                    sp = self.reg.SP
                    stk = []
                    for i in range(0, 12, 2):
                        try:
                            w = self.mem.read((sp + i) & 0xFFFF) | (self.mem.read((sp + i + 1) & 0xFFFF) << 8)
                            stk.append(f'{w:04X}')
                        except Exception:
                            stk.append('????')
                    print(f"  [paging] PC=#{self.reg.PC:04X} SP=#{sp:04X} stk={','.join(stk)}  slot{slot}: {old:#04x} -> {value:#04x}")
                return
            self.mem.write(ref, value)

    def in_port(self, port: int) -> int:
        low = port & 0xFF
        high = (port >> 8) & 0xFF
        if low == 0xAF:
            if high == 0x27:
                return self.dma.status & 0xFF
            return 0x07 if high == 0x00 else 0x00
        if low == 0x57:
            return self._read_ft_spi()
        if port == 0xBFF7:
            return self.input.rtc_seconds_bcd
        if low == 0x1F:
            return self.input.kempston
        if port == 0xFADF:
            return self.input.mouse_buttons
        if port == 0xFBDF:
            return self.input.mouse_x & 0xFF
        if port == 0xFFDF:
            return self.input.mouse_y & 0xFF
        if low == 0xFE:
            return self.input.keyboard_rows.get((port >> 8) & 0xFF, 0xFF)
        return 0xFF

    def out_port(self, port: int, value: int) -> None:
        low = port & 0xFF
        high = (port >> 8) & 0xFF
        if low == 0xAF:
            self._write_tsconf_register(high, value)
        elif low in (0x57, 0x77):
            self._write_ft_spi(low, value)

    def _write_tsconf_register(self, reg: int, value: int) -> None:
        if reg == 0x10:
            self.mem.pages[0] = value & 0xFF
        elif reg == 0x11:
            self.mem.pages[1] = value & 0xFF
        elif reg == 0x12:
            self.mem.pages[2] = value & 0xFF
        elif reg == 0x13:
            self.mem.pages[3] = value & 0xFF
        elif reg == 0x1A:
            self.dma.src_l = value & 0xFF
        elif reg == 0x1B:
            self.dma.src_h = value & 0xFF
        elif reg == 0x1C:
            self.dma.src_x = value & 0xFF
        elif reg == 0x1D:
            self.dma.dst_l = value & 0xFF
        elif reg == 0x1E:
            self.dma.dst_h = value & 0xFF
        elif reg == 0x1F:
            self.dma.dst_x = value & 0xFF
        elif reg == 0x26:
            self.dma.length = value & 0xFF
        elif reg == 0x28:
            self.dma.number = value & 0xFF
        elif reg == 0x27:
            self._start_dma(value & 0xFF)

    def _start_dma(self, mode: int) -> None:
        self.dma.status = 0x80
        if mode == 0x82:
            self._dma_ram_spi()
        else:
            self.errors.append(f"unsupported DMA mode #{mode:02X}")
        self.dma.status = 0

    def _dma_ram_spi(self) -> None:
        if self.ft.spi_mode != "write" or self.ft.spi_phase < 3 or self.ft.spi_addr is None:
            self.errors.append("DMA_RAM_SPI started without active FT812 SPI write transaction")
            return
        src_off = ((self.dma.src_h << 8) | self.dma.src_l) & 0x3FFF
        src = ((self.dma.src_x & 0xFF) * PAGE_SIZE) + src_off
        words = (self.dma.number + 1) * (self.dma.length + 1)
        byte_count = words * 2
        end = min(src + byte_count, len(self.mem.physical))
        if end - src != byte_count:
            self.errors.append(f"DMA_RAM_SPI source overflow src=#{src:06X} bytes={byte_count}")
        for value in self.mem.physical[src:end]:
            addr = self.ft.spi_addr & 0x3FFFFF
            self._write_ft_addr(addr, value)
            self.ft.spi_addr = (addr + 1) & 0x3FFFFF

    def _write_ft_spi(self, low_port: int, value: int) -> None:
        # This keeps enough state for diagnostics. Actual TSLib write helpers
        # are also intercepted at the memory-copy level by normal Z80 code.
        if low_port == 0x77:
            self.ft.spi_phase = 0
            self.ft.spi_addr = 0
            self.ft.spi_mode = "idle"
            self.ft.spi_read_dummy = False
            return
        if self.ft.spi_addr is None:
            self.ft.spi_addr = 0
        if self.ft.spi_phase == 0:
            self.ft.spi_mode = "write" if value & 0x80 else "read"
            self.ft.spi_addr = value & 0x3F
            self.ft.spi_phase += 1
            return
        if self.ft.spi_phase < 3:
            self.ft.spi_addr = ((self.ft.spi_addr << 8) | value) & 0x3FFFFF
            self.ft.spi_phase += 1
            if self.ft.spi_phase == 3 and self.ft.spi_mode == "read":
                self.ft.spi_read_dummy = True
            return
        if self.ft.spi_mode != "write":
            return
        addr = self.ft.spi_addr & 0x3FFFFF
        self._write_ft_addr(addr, value)
        self.ft.spi_addr = (addr + 1) & 0x3FFFFF

    def _read_ft_spi(self) -> int:
        if self.ft.spi_phase < 3 or self.ft.spi_addr is None:
            return 0
        if self.ft.spi_read_dummy:
            self.ft.spi_read_dummy = False
            return 0
        addr = self.ft.spi_addr & 0x3FFFFF
        value = self._read_ft_addr(addr)
        self.ft.spi_addr = (addr + 1) & 0x3FFFFF
        return value

    def _read_ft_addr(self, addr: int) -> int:
        if addr == 0x302000:
            return 0x7C
        if addr == 0x302020:
            return 0
        if addr == 0x302054:
            return self.ft.dlswap & 0xFF
        if addr == 0x3020A8:
            return self.ft.int_flags & 0xFF
        if 0x000000 <= addr < RAM_G_SIZE:
            return self.ft.ram_g[addr]
        elif RAM_G_SIZE <= addr < 0x300000:
            # HW: FT81x декодирует только младшие 20 бит RAM_G — адрес >=1МБ
            # аливасится в низ RAM_G (а не читается нулём). Воспроизводим, иначе
            # переполнение RAM_G на хосте не ловится (см. WINEXP #100000).
            return self.ft.ram_g[addr & (RAM_G_SIZE - 1)]
        elif 0x300000 <= addr < 0x302000:
            return self.ft.ram_dl[addr - 0x300000]
        elif 0x308000 <= addr < 0x309000:
            return self.ft.ram_cmd[addr - 0x308000]
        return 0

    def _write_ft_addr(self, addr: int, value: int) -> None:
        value &= 0xFF
        if addr == 0x302054:
            self.ft.dlswap = 0
            return
        if addr == 0x3020A8:
            self.ft.int_flags &= ~value
            return
        if 0x000000 <= addr < RAM_G_SIZE:
            self.ft.ram_g[addr] = value
        elif RAM_G_SIZE <= addr < 0x300000:
            # HW: запись по адресу >=1МБ аливасится в низ RAM_G (только младшие
            # 20 бит декодируются) и ПОРТИТ его — раньше эмулятор молча отбрасывал
            # такую запись, поэтому баг WINEXP #100000 был не виден на хосте.
            self.ft.ram_g[addr & (RAM_G_SIZE - 1)] = value
        elif 0x300000 <= addr < 0x302000:
            self.ft.ram_dl[addr - 0x300000] = value
        elif 0x308000 <= addr < 0x309000:
            off = addr - 0x308000
            self.ft.ram_cmd[off] = value
            self.ft.cmd_write_ptr = (off + 1) & 0x0FFF


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(PROJECT_ROOT))
    ap.add_argument("--frames", type=int, default=0)
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--call", help="symbol name or hex address to call once")
    ns = ap.parse_args(argv)

    emu = ZumaFullZ80Emulator(Path(ns.root), trace=ns.trace)
    if emu.errors:
        print("load warnings:")
        for err in emu.errors:
            print("  -", err)

    if ns.call:
        addr = emu.sym[ns.call] if ns.call in emu.sym else parse_num(ns.call)
        steps = emu.call(addr)
        print(f"called #{addr:04X}, steps={steps}, pc=#{emu.reg.PC:04X}")
    else:
        emu.game_init()
        for _ in range(ns.frames):
            emu.game_frame()

    state = emu.vdc_state()
    print(
        f"hsa={state['hsa']} hsub={state['hsub']} len={state['slots_len']} "
        f"balls={state['balls_spawned']} tstates={state['tstates']}"
    )
    print("slots=" + ZumaFullZ80Emulator.format_slots(state["slots"])[:120])
    print("pages=" + ",".join(f"{p:02X}" for p in state["page_map"]))
    print(f"port_in={len(emu.ports_in)} port_out={len(emu.ports_out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
