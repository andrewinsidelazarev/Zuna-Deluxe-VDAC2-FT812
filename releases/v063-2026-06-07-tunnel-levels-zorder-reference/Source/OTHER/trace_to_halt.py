"""Run SPG from EntryPoint in zuma_full_z80_emulator, trace until HALT or
slot mapping disturbance matches the real host dump (slot 3 mapped to a
preview zlib page = #F1)."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator, PROJECT_ROOT

sim = ZumaFullZ80Emulator(PROJECT_ROOT, trace=False)
print(f"EntryPoint=#{sim.reg.PC:04X}, initial pages={[hex(p) for p in sim.mem.pages]}")
print()

# Hook: at every step, watch for HALT opcode about to execute, and watch slot
# mapping changes. Specifically: slot 3 leaving page #04 (main1) is the bug
# Codex described.
halt_pc = None
mapping_log: list[tuple[int, tuple[int, int, int, int]]] = []
last_pages = tuple(sim.mem.pages)
mapping_log.append((sim.reg.PC, last_pages))

MAX_STEPS = 5_000_000
step_no = 0
halts_skipped = 0
try:
    while step_no < MAX_STEPS:
        pc = sim.reg.PC
        op = sim.mem.read(pc)
        if op == 0x76:  # HALT
            # Detect Init_Int-style: HALT in slot 1 (Core code area) — skip
            # past it as if IRQ fired and INT_Handler did EI/RET.
            if 0x4000 <= pc <= 0x7FFF:
                halts_skipped += 1
                if halts_skipped <= 3:
                    print(f"step {step_no}: skip Init_Int-style HALT @ PC=#{pc:04X} slots={[hex(p) for p in sim.mem.pages]}")
                sim.reg.PC = (pc + 1) & 0xFFFF  # past HALT
                step_no += 1
                continue
            # Real halt — in slot 3 or 0 (zlib data territory)
            halt_pc = pc
            print(f"REAL HALT at PC=#{pc:04X} step={step_no}")
            print(f"  slots: {[hex(p) for p in sim.mem.pages]}")
            ctx_pre = bytes(sim.mem.read(pc - 16 + i) & 0xFF for i in range(16))
            ctx_post = bytes(sim.mem.read(pc + i) & 0xFF for i in range(16))
            print(f"  context PC-16: {ctx_pre.hex()}")
            print(f"  context PC..:  {ctx_post.hex()}")
            print(f"  SP=#{sim.reg.SP:04X}")
            # peek stack to see return chain
            sp = sim.reg.SP
            stk = []
            for i in range(0, 24, 2):
                w = sim.mem.read((sp + i) & 0xFFFF) | (sim.mem.read((sp + i + 1) & 0xFFFF) << 8)
                stk.append(f'#{w:04X}')
            print(f"  stack: {','.join(stk)}")
            break
        sim.step()
        step_no += 1
        cur_pages = tuple(sim.mem.pages)
        if cur_pages != last_pages:
            mapping_log.append((sim.reg.PC, cur_pages))
            last_pages = cur_pages
            if cur_pages[3] not in (0x04, 0x08):
                if len(mapping_log) < 60:
                    print(f"step {step_no}: PC=#{sim.reg.PC:04X} pages={[hex(p) for p in cur_pages]}")
    else:
        print(f"REACHED {MAX_STEPS} steps without REAL HALT. Last pages: {[hex(p) for p in last_pages]} PC=#{sim.reg.PC:04X}")
    print(f"Init_Int-style HALTs skipped: {halts_skipped}")
except Exception as exc:
    print(f"EXCEPTION at step {step_no} PC=#{sim.reg.PC:04X}: {exc}")
    import traceback
    traceback.print_exc()

print()
print(f"Total slot-mapping changes seen: {len(mapping_log)}")
print(f"Last 12 mapping changes:")
for pc, pages in mapping_log[-12:]:
    print(f"  PC=#{pc:04X}  slot0=#{pages[0]:02X} slot1=#{pages[1]:02X} slot2=#{pages[2]:02X} slot3=#{pages[3]:02X}")

# Look for canary at #5020
canary = sim.get_memory(0x5020, 32)
print()
print(f"@#5020: {canary.hex()}")
try:
    print(f"  ascii: {canary.decode('latin-1', errors='replace')!r}")
except Exception:
    pass
