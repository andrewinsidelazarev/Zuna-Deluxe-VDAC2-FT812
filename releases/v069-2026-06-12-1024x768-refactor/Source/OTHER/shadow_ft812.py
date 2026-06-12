#!/usr/bin/env python3
"""Shadow FT812 — L2 регистры + L3 Display List interpreter.

НЕ растеризует. Цель: дать harness'у возможность увидеть «что игра собиралась
нарисовать», без эмуляции пикселей.

L2 — FT812Registers:
  * Перманентное хранилище 4KB region 0x302000..0x302FFF
  * Корректный read/write для REG_ID/FRAMES/CLOCK/INT_FLAGS/DLSWAP/CMD_READ/CMD_WRITE
  * tick_frame(ram_dl): инкремент REG_FRAMES, snapshot DL если был DLSWAP

L3 — DL interpreter:
  * parse_dl_op(word, offset) → DLOp
  * disasm_dl(ram_dl) → List[DLOp] (parse до DISPLAY)
  * format_dl(ops) → human-readable trace

Адреса регистров проверены с TSLib/Include/FT/81x Const.inc.

Использование:
    from shadow_ft812 import attach_shadow
    regs = attach_shadow(emu)
    emu.game_init(); emu.game_frame(); ...
    regs.tick_frame(emu.ft.ram_dl)
    if regs.last_dl_snapshot:
        print(format_dl(disasm_dl(regs.last_dl_snapshot)))
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

# =============================================================================
# Memory map (FT81x)
# =============================================================================
RAM_G_BASE   = 0x000000;  RAM_G_SIZE   = 1024 * 1024
RAM_DL_BASE  = 0x300000;  RAM_DL_SIZE  = 0x2000        # 8 KB
REG_BASE     = 0x302000;  REG_SIZE     = 0x1000        # 4 KB
RAM_CMD_BASE = 0x308000;  RAM_CMD_SIZE = 0x1000        # 4 KB

# =============================================================================
# Registers (subset relevant to Zuma + TSLib, addresses verified)
# =============================================================================
REG_ID            = 0x302000
REG_FRAMES        = 0x302004
REG_CLOCK         = 0x302008
REG_FREQUENCY     = 0x30200C
REG_CPURESET      = 0x302020
REG_HCYCLE        = 0x30202C
REG_HOFFSET       = 0x302030
REG_HSIZE         = 0x302034
REG_VCYCLE        = 0x302040
REG_VOFFSET       = 0x302044
REG_VSIZE         = 0x302048
REG_DLSWAP        = 0x302054
REG_ROTATE        = 0x302058
REG_PCLK_POL      = 0x30206C
REG_PCLK          = 0x302070
REG_INT_FLAGS     = 0x3020A8
REG_INT_EN        = 0x3020AC
REG_INT_MASK      = 0x3020B0
REG_PWM_DUTY      = 0x3020D4
REG_CMD_READ      = 0x3020F8
REG_CMD_WRITE     = 0x3020FC
REG_CMD_DL        = 0x302100

# REG_DLSWAP values
DLSWAP_DONE  = 0
DLSWAP_LINE  = 1
DLSWAP_FRAME = 2

# REG_INT_FLAGS bits
INT_SWAP         = 0x01
INT_TOUCH        = 0x02
INT_TAG          = 0x04
INT_SOUND        = 0x08
INT_PLAYBACK     = 0x10
INT_CMDEMPTY     = 0x20
INT_CMDFLAG      = 0x40
INT_CONVCOMPLETE = 0x80

# =============================================================================
# DL opcodes (top 6 bits of 32-bit word, bits 31:30 = 00 for these)
# =============================================================================
DL_DISPLAY            = 0x00
DL_BITMAP_SOURCE      = 0x01
DL_CLEAR_COLOR_RGB    = 0x02
DL_TAG                = 0x03
DL_COLOR_RGB          = 0x04
DL_BITMAP_HANDLE      = 0x05
DL_CELL               = 0x06
DL_BITMAP_LAYOUT      = 0x07
DL_BITMAP_SIZE        = 0x08
DL_ALPHA_FUNC         = 0x09
DL_STENCIL_FUNC       = 0x0A
DL_BLEND_FUNC         = 0x0B
DL_STENCIL_OP         = 0x0C
DL_POINT_SIZE         = 0x0D
DL_LINE_WIDTH         = 0x0E
DL_CLEAR_COLOR_A      = 0x0F
DL_COLOR_A            = 0x10
DL_CLEAR_STENCIL      = 0x11
DL_CLEAR_TAG          = 0x12
DL_STENCIL_MASK       = 0x13
DL_TAG_MASK           = 0x14
DL_BITMAP_TRANSFORM_A = 0x15
DL_BITMAP_TRANSFORM_B = 0x16
DL_BITMAP_TRANSFORM_C = 0x17
DL_BITMAP_TRANSFORM_D = 0x18
DL_BITMAP_TRANSFORM_E = 0x19
DL_BITMAP_TRANSFORM_F = 0x1A
DL_SCISSOR_XY         = 0x1B
DL_SCISSOR_SIZE       = 0x1C
DL_CALL               = 0x1D
DL_JUMP               = 0x1E
DL_BEGIN              = 0x1F
DL_COLOR_MASK         = 0x20
DL_END                = 0x21
DL_SAVE_CONTEXT       = 0x22
DL_RESTORE_CONTEXT    = 0x23
DL_RETURN             = 0x24
DL_MACRO              = 0x25
DL_CLEAR              = 0x26
DL_VERTEX_FORMAT      = 0x27
DL_BITMAP_LAYOUT_H    = 0x28
DL_BITMAP_SIZE_H      = 0x29
DL_PALETTE_SOURCE     = 0x2A
DL_VERTEX_TRANSLATE_X = 0x2B
DL_VERTEX_TRANSLATE_Y = 0x2C
DL_NOP                = 0x2D

PRIM_NAMES = {
    1: "BITMAPS", 2: "POINTS", 3: "LINES", 4: "LINE_STRIP",
    5: "EDGE_STRIP_R", 6: "EDGE_STRIP_L", 7: "EDGE_STRIP_A",
    8: "EDGE_STRIP_B", 9: "RECTS",
}

FMT_NAMES = {
    0: "ARGB1555", 1: "L1", 2: "L4", 3: "L8", 4: "RGB332",
    5: "ARGB2", 6: "ARGB4", 7: "RGB565", 8: "PALETTED",
    9: "TEXT8X8", 10: "TEXTVGA", 11: "BARGRAPH",
    14: "PALETTED565", 15: "PALETTED4444", 16: "PALETTED8", 17: "L2",
}

BLEND_NAMES = {0: "ZERO", 1: "ONE", 2: "SRC_ALPHA", 3: "DST_ALPHA",
               4: "ONE_MINUS_SRC_ALPHA", 5: "ONE_MINUS_DST_ALPHA"}
TEST_NAMES = {0: "NEVER", 1: "LESS", 2: "LEQUAL", 3: "GREATER",
              4: "GEQUAL", 5: "EQUAL", 6: "NOTEQUAL", 7: "ALWAYS"}


@dataclass
class DLOp:
    offset: int       # byte offset in RAM_DL
    word: int         # raw 32-bit word
    name: str
    fields: Dict[str, Any] = field(default_factory=dict)

    def __str__(self) -> str:
        if not self.fields:
            return f"  {self.offset:04X}: {self.name}"
        parts = ", ".join(f"{k}={v}" for k, v in self.fields.items())
        return f"  {self.offset:04X}: {self.name}({parts})"


def _sx(value: int, bits: int) -> int:
    """Sign-extend value of `bits` width."""
    mask = 1 << (bits - 1)
    return (value & ((1 << bits) - 1)) - ((value & mask) << 1)


def parse_dl_op(word: int, offset: int = 0) -> DLOp:
    """Decode one 32-bit DL command word at given RAM_DL byte offset."""
    op = (word >> 24) & 0xFF
    top2 = op & 0xC0

    if top2 == 0x40:  # VERTEX2F (01xxxxxx)
        x = _sx((word >> 15) & 0x7FFF, 15)
        y = _sx(word & 0x7FFF, 15)
        return DLOp(offset, word, "VERTEX2F",
                    {"x": x, "y": y, "px": f"({x/16:.1f},{y/16:.1f})"})

    if top2 == 0x80 or top2 == 0xC0:  # VERTEX2II (1xxxxxxx — bit31=1)
        x      = (word >> 21) & 0x1FF
        y      = (word >> 12) & 0x1FF
        handle = (word >> 7)  & 0x1F
        cell   = word & 0x7F
        return DLOp(offset, word, "VERTEX2II",
                    {"x": x, "y": y, "handle": handle, "cell": cell})

    # Standard 6-bit opcodes (bits 31:30 = 00, bits 29:24 = opcode)
    if op == DL_DISPLAY:
        return DLOp(offset, word, "DISPLAY")
    if op == DL_CLEAR:
        c = word & 1; s = (word >> 1) & 1; t = (word >> 2) & 1
        return DLOp(offset, word, "CLEAR", {"c": c, "s": s, "t": t})
    if op == DL_CLEAR_COLOR_RGB:
        return DLOp(offset, word, "CLEAR_COLOR_RGB",
                    {"r": (word >> 16) & 0xFF, "g": (word >> 8) & 0xFF, "b": word & 0xFF})
    if op == DL_CLEAR_COLOR_A:
        return DLOp(offset, word, "CLEAR_COLOR_A", {"a": word & 0xFF})
    if op == DL_COLOR_RGB:
        return DLOp(offset, word, "COLOR_RGB",
                    {"r": (word >> 16) & 0xFF, "g": (word >> 8) & 0xFF, "b": word & 0xFF})
    if op == DL_COLOR_A:
        return DLOp(offset, word, "COLOR_A", {"a": word & 0xFF})
    if op == DL_BEGIN:
        p = word & 0x0F
        return DLOp(offset, word, "BEGIN", {"prim": PRIM_NAMES.get(p, str(p))})
    if op == DL_END:
        return DLOp(offset, word, "END")
    if op == DL_BITMAP_SOURCE:
        return DLOp(offset, word, "BITMAP_SOURCE", {"addr": f"#{word & 0x3FFFFF:06X}"})
    if op == DL_BITMAP_HANDLE:
        return DLOp(offset, word, "BITMAP_HANDLE", {"handle": word & 0x1F})
    if op == DL_CELL:
        return DLOp(offset, word, "CELL", {"cell": word & 0x7F})
    if op == DL_BITMAP_LAYOUT:
        fmt = (word >> 19) & 0x1F
        stride = (word >> 9) & 0x3FF
        height = word & 0x1FF
        return DLOp(offset, word, "BITMAP_LAYOUT",
                    {"fmt": FMT_NAMES.get(fmt, str(fmt)),
                     "stride": stride, "height": height})
    if op == DL_BITMAP_LAYOUT_H:
        return DLOp(offset, word, "BITMAP_LAYOUT_H",
                    {"stride_h": (word >> 2) & 3, "height_h": word & 3})
    if op == DL_BITMAP_SIZE:
        return DLOp(offset, word, "BITMAP_SIZE",
                    {"filter": (word >> 20) & 1,
                     "wrap_x": (word >> 19) & 1, "wrap_y": (word >> 18) & 1,
                     "w": (word >> 9) & 0x1FF, "h": word & 0x1FF})
    if op == DL_BITMAP_SIZE_H:
        return DLOp(offset, word, "BITMAP_SIZE_H",
                    {"w_h": (word >> 2) & 3, "h_h": word & 3})
    if DL_BITMAP_TRANSFORM_A <= op <= DL_BITMAP_TRANSFORM_F:
        idx = op - DL_BITMAP_TRANSFORM_A
        letter = "ABCDEF"[idx]
        # A,B,D,E = 17-bit signed; C,F = 24-bit signed
        if letter in "ABDE":
            v = _sx(word & 0x1FFFF, 17)
        else:
            v = _sx(word & 0xFFFFFF, 24)
        return DLOp(offset, word, f"BITMAP_TRANSFORM_{letter}", {"v": v})
    if op == DL_BLEND_FUNC:
        s = (word >> 3) & 7; d = word & 7
        return DLOp(offset, word, "BLEND_FUNC",
                    {"src": BLEND_NAMES.get(s, str(s)),
                     "dst": BLEND_NAMES.get(d, str(d))})
    if op == DL_ALPHA_FUNC:
        f = (word >> 8) & 7
        return DLOp(offset, word, "ALPHA_FUNC",
                    {"func": TEST_NAMES.get(f, str(f)), "ref": word & 0xFF})
    if op == DL_POINT_SIZE:
        return DLOp(offset, word, "POINT_SIZE", {"size": word & 0x1FFF})
    if op == DL_LINE_WIDTH:
        return DLOp(offset, word, "LINE_WIDTH", {"width": word & 0xFFF})
    if op == DL_SCISSOR_XY:
        return DLOp(offset, word, "SCISSOR_XY",
                    {"x": (word >> 11) & 0x7FF, "y": word & 0x7FF})
    if op == DL_SCISSOR_SIZE:
        return DLOp(offset, word, "SCISSOR_SIZE",
                    {"w": (word >> 12) & 0xFFF, "h": word & 0xFFF})
    if op == DL_SAVE_CONTEXT:
        return DLOp(offset, word, "SAVE_CONTEXT")
    if op == DL_RESTORE_CONTEXT:
        return DLOp(offset, word, "RESTORE_CONTEXT")
    if op == DL_VERTEX_FORMAT:
        return DLOp(offset, word, "VERTEX_FORMAT", {"frac": word & 7})
    if op == DL_VERTEX_TRANSLATE_X:
        return DLOp(offset, word, "VERTEX_TRANSLATE_X",
                    {"x": _sx(word & 0x1FFFF, 17)})
    if op == DL_VERTEX_TRANSLATE_Y:
        return DLOp(offset, word, "VERTEX_TRANSLATE_Y",
                    {"y": _sx(word & 0x1FFFF, 17)})
    if op == DL_CALL:
        return DLOp(offset, word, "CALL", {"addr": f"#{word & 0xFFFF:04X}"})
    if op == DL_JUMP:
        return DLOp(offset, word, "JUMP", {"addr": f"#{word & 0xFFFF:04X}"})
    if op == DL_RETURN:
        return DLOp(offset, word, "RETURN")
    if op == DL_MACRO:
        return DLOp(offset, word, "MACRO", {"m": word & 1})
    if op == DL_TAG:
        return DLOp(offset, word, "TAG", {"s": word & 0xFF})
    if op == DL_TAG_MASK:
        return DLOp(offset, word, "TAG_MASK", {"mask": word & 1})
    if op == DL_STENCIL_FUNC:
        return DLOp(offset, word, "STENCIL_FUNC",
                    {"func": TEST_NAMES.get((word >> 16) & 7, str((word >> 16) & 7)),
                     "ref": (word >> 8) & 0xFF, "mask": word & 0xFF})
    if op == DL_STENCIL_OP:
        return DLOp(offset, word, "STENCIL_OP",
                    {"sfail": (word >> 3) & 7, "spass": word & 7})
    if op == DL_STENCIL_MASK:
        return DLOp(offset, word, "STENCIL_MASK", {"mask": word & 0xFF})
    if op == DL_CLEAR_STENCIL:
        return DLOp(offset, word, "CLEAR_STENCIL", {"s": word & 0xFF})
    if op == DL_CLEAR_TAG:
        return DLOp(offset, word, "CLEAR_TAG", {"t": word & 0xFF})
    if op == DL_COLOR_MASK:
        return DLOp(offset, word, "COLOR_MASK",
                    {"r": (word >> 3) & 1, "g": (word >> 2) & 1,
                     "b": (word >> 1) & 1, "a": word & 1})
    if op == DL_PALETTE_SOURCE:
        return DLOp(offset, word, "PALETTE_SOURCE", {"addr": f"#{word & 0x3FFFFF:06X}"})
    if op == DL_NOP:
        return DLOp(offset, word, "NOP")
    return DLOp(offset, word, f"UNKNOWN_0x{op:02X}")


def disasm_dl(ram_dl: bytes, max_ops: int = 2048,
              stop_at_display: bool = True) -> List[DLOp]:
    """Parse DL byte buffer into list of DLOps. Stop on DISPLAY or max_ops."""
    ops: List[DLOp] = []
    n = min(len(ram_dl) // 4, max_ops)
    for i in range(n):
        off = i * 4
        word = (ram_dl[off] | (ram_dl[off + 1] << 8)
                | (ram_dl[off + 2] << 16) | (ram_dl[off + 3] << 24))
        op = parse_dl_op(word, off)
        ops.append(op)
        if stop_at_display and op.name == "DISPLAY":
            break
    return ops


def format_dl(ops: List[DLOp]) -> str:
    return "\n".join(str(op) for op in ops)


def summarize_dl(ops: List[DLOp]) -> str:
    """One-line per-opcode count summary."""
    counts: Dict[str, int] = {}
    for op in ops:
        counts[op.name] = counts.get(op.name, 0) + 1
    parts = [f"{k}={v}" for k, v in sorted(counts.items(), key=lambda x: -x[1])]
    return f"DL {len(ops)} ops: " + ", ".join(parts)


# =============================================================================
# FT812Registers — L2 register storage with correct read/write semantics
# =============================================================================
class FT812Registers:
    """Persistent storage 0x302000..0x302FFF + correct r/w for key regs."""

    def __init__(self) -> None:
        self.bytes = bytearray(REG_SIZE)
        self._set32(REG_ID, 0x0000007C)
        self._set32(REG_FREQUENCY, 60_000_000)
        self._set32(REG_INT_FLAGS, INT_SWAP)   # default: poll loops pass on first read
        self._set32(REG_INT_MASK, 0xFF)
        self._set32(REG_DLSWAP, DLSWAP_DONE)
        # 640x480 timings (typical TS-Conf VDAC2 config)
        self._set32(REG_HCYCLE, 800);  self._set32(REG_HOFFSET, 16);  self._set32(REG_HSIZE, 640)
        self._set32(REG_VCYCLE, 525);  self._set32(REG_VOFFSET, 12);  self._set32(REG_VSIZE, 480)
        self._set32(REG_PCLK, 2);      self._set32(REG_PCLK_POL, 0)

        self.swap_pending: bool = False
        self.last_dl_snapshot: Optional[bytes] = None
        self.swap_count: int = 0
        self.dlswap_writes: int = 0
        self.int_flags_reads: int = 0

    def _set32(self, reg_addr: int, value: int) -> None:
        off = reg_addr - REG_BASE
        for i in range(4):
            self.bytes[off + i] = (value >> (i * 8)) & 0xFF

    def _get32(self, reg_addr: int) -> int:
        off = reg_addr - REG_BASE
        return (self.bytes[off] | (self.bytes[off + 1] << 8)
                | (self.bytes[off + 2] << 16) | (self.bytes[off + 3] << 24))

    def read_byte(self, addr: int) -> int:
        off = addr - REG_BASE
        if not (0 <= off < REG_SIZE):
            return 0
        b = self.bytes[off]
        if addr == REG_INT_FLAGS:
            self.int_flags_reads += 1
            self._set32(REG_INT_FLAGS, 0)
        return b

    def write_byte(self, addr: int, value: int) -> None:
        off = addr - REG_BASE
        if not (0 <= off < REG_SIZE):
            return
        if addr == REG_ID:
            return   # read-only
        self.bytes[off] = value & 0xFF
        if addr == REG_DLSWAP:
            mode = self._get32(REG_DLSWAP) & 3
            if mode in (DLSWAP_LINE, DLSWAP_FRAME):
                self.swap_pending = True
                self.dlswap_writes += 1
                self._set32(REG_INT_FLAGS, self._get32(REG_INT_FLAGS) | INT_SWAP)
        # REG_CMD_WRITE poke → emulate co-pro «обработал всё» немедленно:
        if addr in (REG_CMD_WRITE, REG_CMD_WRITE + 1, REG_CMD_WRITE + 2, REG_CMD_WRITE + 3):
            self._set32(REG_CMD_READ, self._get32(REG_CMD_WRITE))

    def tick_frame(self, ram_dl: bytes) -> None:
        """Call externally per frame: process pending swap, bump FRAMES/CLOCK,
        re-arm INT_SWAP so the next swap-poll passes."""
        if self.swap_pending:
            self.last_dl_snapshot = bytes(ram_dl[:RAM_DL_SIZE])
            self.swap_count += 1
            self.swap_pending = False
            self._set32(REG_DLSWAP, DLSWAP_DONE)
        self._set32(REG_FRAMES, (self._get32(REG_FRAMES) + 1) & 0xFFFFFFFF)
        self._set32(REG_CLOCK, (self._get32(REG_CLOCK) + 420_000) & 0xFFFFFFFF)
        self._set32(REG_INT_FLAGS, self._get32(REG_INT_FLAGS) | INT_SWAP)


# =============================================================================
# attach_shadow — monkey-patch existing emulator to use FT812Registers
# =============================================================================
def attach_shadow(emu) -> FT812Registers:
    """Replace emu._read_ft_addr / _write_ft_addr with FT812Registers-backed
    versions for the 0x302000..0x302FFF range. Other ranges (RAM_G, RAM_DL,
    RAM_CMD) continue through emu.ft.ram_*.

    Snapshots emu.ft.ram_dl into regs.last_dl_snapshot at the moment of
    REG_DLSWAP write."""
    regs = FT812Registers()
    emu.shadow_regs = regs

    orig_read = emu._read_ft_addr
    orig_write = emu._write_ft_addr

    def new_read(addr: int) -> int:
        if REG_BASE <= addr < REG_BASE + REG_SIZE:
            return regs.read_byte(addr)
        return orig_read(addr)

    def new_write(addr: int, value: int) -> None:
        if REG_BASE <= addr < REG_BASE + REG_SIZE:
            was_pending = regs.swap_pending
            regs.write_byte(addr, value)
            if regs.swap_pending and not was_pending:
                regs.last_dl_snapshot = bytes(emu.ft.ram_dl[:RAM_DL_SIZE])
                regs.swap_count += 1
            return
        orig_write(addr, value)

    emu._read_ft_addr = new_read
    emu._write_ft_addr = new_write
    return regs


# =============================================================================
# Smoke test
# =============================================================================
if __name__ == "__main__":
    # Synthetic DL: clear + bitmap + display
    samples = [
        0x02FFFFFF,           # CLEAR_COLOR_RGB(255,255,255)
        0x26000007,           # CLEAR(c=1,s=1,t=1)
        0x05000002,           # BITMAP_HANDLE(2)
        0x1F000001,           # BEGIN(BITMAPS)
        0x80000000 | (100 << 21) | (50 << 12) | (2 << 7) | 5,  # VERTEX2II(100,50,h=2,c=5)
        0x40000000 | (256 << 15) | 128,  # VERTEX2F(256,128)
        0x21000000,           # END
        0x00000000,           # DISPLAY
    ]
    buf = bytearray()
    for w in samples:
        buf.extend(w.to_bytes(4, "little"))
    ops = disasm_dl(bytes(buf))
    print(format_dl(ops))
    print()
    print(summarize_dl(ops))
