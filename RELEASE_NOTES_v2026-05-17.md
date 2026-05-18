# Zuma Deluxe VDAC2/FT812 — Release 2026-05-17 (kill-zone smooth absorb)

**Tested on real hardware**: ZX-Evolution + VDAC2 (FT812 chip). **No frame tearing** at 640×480 @ 74Hz.

## What's in this build

### Kill-zone Game Over polish
- **Smooth absorb** — chain balls visually slide INTO the kill-zone instead of discrete cell jumps. Uses HSub-based chain advance (mirrors the fast-spawn motion pattern) — 8 sub-pixel steps per tick, 32 steps per cell, alpha fade synced to HSub progress.
- **COLOR_A per-sprite alpha fade** — head ball dissolves smoothly (255→7) over each 4-tick cycle. Implemented inside the bucket render loop, applied only to slot[0] during state=absorb.
- **Skull animation atlas** — 12 frames cropped from Zuma Deluxe HD `gameobjects.png` (ANIM_SKULL, x=629 y=132, 132×132 cells), uniformly scaled to 64×64 ARGB4 around source-center (66,66). Animation runs through frames 2..10 as chain approaches and 11 during absorb.
- **Per-level kill-zone coordinates** — `KZ_DEFAULT_X/Y` constants instead of derived from `TrackData[N-1]`. For Spiral of Doom level 1: (211, 217), aligned with bg-baked golden sun art.
- **Skip overlay in idle** — bg already contains the closed-mouth skull, overlay drawn only during animation (KzFrame ≥ 2). Saves ~10 DL bytes/frame.

### Frog randomizer
- **Color exclusion when chain has ≥3 active colors** — next-ball randomizer forbidden from repeating current ball color. At <3 colors, exclusion disabled (would force alternation).

### Fixed bugs
- **`Cell` + `Vertex2f` register corruption** — `FT.Coprocessor.Cell` uses BC/DE to emit opcode, so coords must be loaded AFTER the Cell call, not before. This silent bug was rendering the kill-zone skull at random screen positions for ~month.

### Performance notes
- **Bucket-grouped tangent rotation**: 32 buckets (11.25° step). 16 buckets tried — visible jitter on fast head ball during kill-zone approach → reverted to 32.
- **Core code size**: 8064 bytes (page 5 slot 1, 128 bytes spare under 8 KB limit).
- **HighLander parallel render** — Z80 builds next DL while FT812 renders current frame; sync via INT_SWAP.

## Optimization techniques applied (from `Docs/zuma_balls_optimization_guide.md`)

| Technique | Applied |
|---|---|
| Atlas layout (color × spin phase) | ✅ 4×16 ARGB4 32×32 |
| Bucket-grouped tangent rotation | ✅ 32 buckets |
| Group-then-emit render pattern | ✅ |
| Parallel build/render (HighLander pattern) | ✅ |
| LOD spin phases by distance | ❌ Not needed yet at 85 balls |
| Frustum culling on chain | ❌ All chain balls within 640×480 |
| 8 angle groups (45°) | ❌ Too jittery; 32 chosen |
| Burst mode SPI | ⚠️ Via TSLib FT_CMD_BUF batching |

## Memory map
- bg DXT1_L4 (compressed background): RAM_G `#010000`, 15 pages
- chain ball atlas: RAM_G `#050000`, 12 pages (4 colors × 16 phases ARGB4)
- frog body/plate/tongue/overlay (HD-composition): RAM_G `#09C000`..`#0B4000`
- kill-zone skull atlas (12 frames): RAM_G `#080000`, 6 pages

## Repository structure
```
Source/ASM/         — Z80 assembler (main, MainLoop, VDC, Frog, Bullet, Init_Video)
Source/OTHER/       — Python tools (asset generators, Z80 simulators, harness tests)
Graphics/Original/  — source PNGs
Graphics/Converted/ — RAM_G binaries + spgbld pages
Docs/               — uchebnik (textbook), FT812 datasheets, guides
releases/baseline_2026-05-17_killzone_smooth_absorb/ — this version's snapshot
zuma_vdac2.spg      — built ROM (load in Unreal x64 or write to ZX-Evo)
```

## Build & run
```bash
sjasmplus Source/ASM/main.asm --syntax=ab --lst=main.lst --sym=zuma.sym
spgbld -b spgbld_vdac2.ini zuma_vdac2.spg
# Run in Unreal x64 emulator OR flash to ZX-Evo CF card
```

## Tests (Python harness, except VDAC2 unified CLI)
```bash
PYTHONIOENCODING=utf-8 python Source/OTHER/test_match3_stuck.py    # PASS
PYTHONIOENCODING=utf-8 python Source/OTHER/test_tail_fix_verify.py # PASS (0/86 mismatches)
PYTHONIOENCODING=utf-8 python Source/OTHER/vdc_test_runner.py      # PASS (Match-3 STOP + CASCADE)
```

## Учебник
Added **Глава 23** to `Docs/uchebnik_tsconf_vdac2.md` — "Render-loop optimizations and DL-emit pitfalls": bucket-grouped tangent rotation, per-sprite COLOR_A fade, Cell/Vertex2f register corruption, bg-baked overlay skip, HSub-based smooth motion.

---

**Hardware test**: confirmed by user 2026-05-17 — no tearing on real ZX-Evo + VDAC2.
