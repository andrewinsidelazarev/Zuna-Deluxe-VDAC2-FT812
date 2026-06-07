# Z80 Python emulation: errors and gaps

Date: 2026-05-14

## Blocking environment errors

1. `python.exe`, `python3.exe`, and `py.exe` in this shell resolve to `C:\Users\Администратор\AppData\Local\Microsoft\WindowsApps\*.exe` and fail with `Доступ к этому файлу из системы отсутствует`. `py -3.12` is the intended command, but in this shell it hits that broken WindowsApps stub.

2. The real launcher at `C:\Users\Администратор\AppData\Local\Programs\Python\Launcher\py.exe` starts, but reports `No installed Python found!`. A working interpreter exists at `C:\Users\Администратор\AppData\Local\Programs\Python\Python312\python.exe`; I used that full path for verification.

3. The existing `Source/OTHER/zuma_z80_simulator.py` depends on external package `z80` (kosarev/z80). The repository already contains a pure-Python Z80 core, so `Source/OTHER/zuma_full_z80_emulator.py` was added to avoid that dependency.

## Emulator limitations

1. FT812 is modeled as RAM/register/log storage, not as a rasterizer. CPU code and display-list writes can be inspected, but no final 640x480 frame is rendered from the FT812 command stream.

2. The bundled cburbridge Z80 core is slower and less complete than kosarev/z80. Its README explicitly lists missing undocumented opcodes and incomplete undocumented flags for `CPI`/`CPIR`.

3. Interrupt timing is simplified. The harness exposes `game_frame()` that calls update/render routines directly instead of running the infinite `MainLoop` and real FT812 `INT_SWAP` wait loops.

4. TS-Config paging is implemented for the 16K page registers used by this build. Other TS-Config video/DMA registers are logged or ignored unless they affect memory mapping.

5. Kempston mouse/keyboard inputs are synthetic. Defaults are neutral; tests that need aiming or shooting must set `InputState` explicitly.

## Project/code risks found during setup

1. `spgbld_vdac2.ini` and `Source/ASM/main.asm` disagree in comments around frog pages: code says `FROG_TOTAL_PAGES = FROG_PAGE_COUNT * 4`, and the current value is 8 pages. Some older comments still mention 7 pages.

2. `VDC_Init` reads `TrackData` through the current slot-2 mapping. The harness loads page `#06` and defaults slot 2 to `#06`, but any caller that changes page 2 before `VDC_Init` must restore it.

3. Full `Core.Initialize` uploads large assets through FT812 write helpers. For deterministic game-state tests, the harness uses `game_init()` and calls `Init_Core`, `VDC_Init`, `Frog_Init`, and `Bullet_Init` directly.

4. MainLoop has permanent waits on FT812 `REG_INT_FLAGS` and `REG_DLSWAP`. A blind CPU run from `Core.Start` can hang if those registers are not modeled exactly. Use `game_frame()` or call subroutines directly for automated tests.

5. The worktree is dirty and many tracked root-level files are marked deleted after relocation to `Source/` and `Graphics/`. I did not revert or normalize those unrelated changes.

## Added files

1. `Source/OTHER/zuma_full_z80_emulator.py` - autonomous pure-Python Z80 harness.
2. `Docs/z80_emulation_errors.md` - this error/limitation list.

## Intended commands

```powershell
cd "C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2"
& "C:\Users\Администратор\AppData\Local\Programs\Python\Python312\python.exe" Source\OTHER\zuma_full_z80_emulator.py --frames 5
& "C:\Users\Администратор\AppData\Local\Programs\Python\Python312\python.exe" Source\OTHER\zuma_full_z80_emulator.py --call Core.VDC_Init
```

If `py -3.12` works in your normal console, equivalent commands are:

```powershell
py -3.12 Source\OTHER\zuma_full_z80_emulator.py --frames 5
py -3.12 Source\OTHER\zuma_full_z80_emulator.py --call Core.VDC_Init
```

## Smoke-test results

1. `py_compile Source\OTHER\zuma_full_z80_emulator.py` - passed.
2. `--call Core.VDC_Init` - passed: `steps=904`, `hsa=0`, `hsub=0`, `len=0`, `balls=0`, `pages=00,05,06,08`.
3. `--frames 1` - passed: `hsa=0`, `hsub=12`, `len=1`, `balls=1`.
4. `--frames 5` - passed: `hsa=1`, `hsub=28`, `len=2`, `balls=2`.
