# Codex compare: VDAC2 vs working Zuma

Date: 2026-05-14

Scope: comparison against `C:\Users\Администратор\Desktop\Zuma Deluxe` without
patching VDAC2 game ASM.

## Findings

1. `VDC_SlotT` in VDAC2 clamps `HSA - i < 0` to zero.

   Repro through the full Z80 harness:

   ```text
   setup: HSA=0 HSub=0 slot i=1 offset=0
   VDAC2 VDC_SlotT: 0x0000 (0)
   VDAC2 VDC_SlotPos: CF=0 X=524 Y=-40
   ```

   In the working non-VDAC2 source, `BcsPreClassify` explicitly treats
   `HSA-i < 0` as `PRESERVE` instead of drawing/colliding the ball at the start
   of the track.  VDAC2 instead exposes this slot as `TrackData[0]`.

   Likely effect: a tail/cascade/rollback ball that is logically before the
   start of the chain can be rendered and used by bullet collision as if it were
   at the spawn point.  This is a strong candidate for false/stuck balls near
   the start of the track.

2. VDAC2 is missing the working build's game-over absorption state machine.

   Present in working project and absent from `Source/ASM/VDC.asm`:

   ```text
   GameState
   CheckHeadAtKillzone
   MoveChainAbsorb
   AbsorbHead
   ```

   In the working version, when the head reaches the killzone, the chain enters
   an absorbing state and removes the head ball while preserving continuity.
   VDAC2 currently only clamps/handles movement at track cap in normal chain
   logic.  This is a second likely source of cap/end-of-track artifacts.

3. Bullet collision depends on `VDC_SlotPos`.

   `Bullet_CheckCollision` iterates chain slots and calls `VDC_SlotPos`.  Because
   finding 1 makes `VDC_SlotPos` return `CF=0` for a ball that should be skipped,
   collision/hemisphere insertion can target a logically off-start ball.

## Diagnostic script

Added:

```text
Source/OTHER/compare_vdac2_vs_working.py
```

Run:

```text
C:\Users\Администратор\AppData\Local\Programs\Python\Python312\python.exe Source/OTHER/compare_vdac2_vs_working.py
```

Note: in this shell `py -3.12` still fails because the launcher/PATH resolves to
a broken WindowsApps/Python launcher setup, so the direct Python 3.12 executable
was used.
