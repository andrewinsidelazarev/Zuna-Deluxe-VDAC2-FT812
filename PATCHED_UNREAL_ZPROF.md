# Patched Unreal Z80 profiling

This note exists to avoid rediscovering the patched Unreal workflow.

## Fixed paths

- Project root: `C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2`
- Patched emulator runtime: `C:\Users\Администратор\Desktop\unreal_x64`
- Valid game shortcut: `C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2 (SPG direct).lnk`
- Patched Unreal source:
  `C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2\Backups\cleanup-2026-06-24\diagnostics\UnrealZ80ProfileL19\src`
- Profiler table source:
  `Backups\cleanup-2026-06-24\diagnostics\UnrealZ80ProfileL19\src\vars.cpp`
- MSBuild project:
  `Backups\cleanup-2026-06-24\diagnostics\UnrealZ80ProfileL19\src\Unreal2017.vcxproj`

## Hard rules

- Do not start `Unreal.exe` hidden.
- Do not start `Unreal.exe` in the background.
- If a visible emulator is needed, the user starts it.
- Before replacing `Unreal.exe`, check that no `Unreal.exe` process is running.
- Do not claim a process was stopped unless it was actually stopped by the agent.

## Current L19 profiling flow

1. Build the game first from the project root:

   ```powershell
   .\build.cmd
   ```

2. If code layout changed, update `zuma_profile_sections[]` in `vars.cpp` from current `Build\main.lst` and `Build\zuma.sym`.

   Important anchors for the current build at the time of this note:

   ```text
   Core.MainLoop.Loop = E8A9
   Core.ZL_AfterChains = F581
   Core.ZL_DrawFrogLayer = F526
   ZL_DrawFrogLayer.draw_frog = F537
   fade overlay call-site = F668
   ```

3. Build patched Unreal:

   ```powershell
   cmd /c 'set "PATH=%SystemRoot%\system32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0\;%ProgramFiles%\Git\cmd" & "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" "C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2\Backups\cleanup-2026-06-24\diagnostics\UnrealZ80ProfileL19\src\Unreal2017.vcxproj" /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v143 /p:PostBuildEventUseInBuild=false /m'
   ```

   The `cmd /c` wrapper avoids the broken duplicated `Path`/`PATH` PowerShell environment.

4. Copy the built exe:

   ```text
   from:
   Backups\cleanup-2026-06-24\diagnostics\UnrealZ80ProfileL19\src\bin\x64\Release\Unreal.exe

   to:
   C:\Users\Администратор\Desktop\unreal_x64\Unreal.exe
   ```

   Keep a timestamped backup of the previous runtime exe.

5. Create the profile request in the emulator runtime directory as ASCII without BOM:

   ```powershell
   [System.IO.File]::WriteAllBytes(
       'C:\Users\Администратор\Desktop\unreal_x64\zprof.req',
       [System.Text.Encoding]::ASCII.GetBytes('120 90')
   )
   ```

   This requests 120 frames with `min_slots=90`.

6. The user starts the emulator visibly and gets the game to L19.

7. Results appear in:

   ```text
   C:\Users\Администратор\Desktop\unreal_x64\zprof.txt
   C:\Users\Администратор\Desktop\unreal_x64\zprof.csv
   C:\Users\Администратор\Desktop\unreal_x64\zprof_draw.csv
   ```

## Validity checks

- `zprof.req` must be exactly ASCII bytes for `120 90`:

  ```text
  31-32-30-20-39-30
  ```

- A valid L19 report should show:

  ```text
  frames=120 target=120
  gate: CurrentLevel=18
  min_slots=90
  frame PC Core.MainLoop.Loop #E8A9
  ```

- If `min_slots=0`, the request file was parsed wrong or stale.
- If `frame PC` differs from the current `Core.MainLoop.Loop`, rebuild or update the profiler table.
- `zprof.req` is consumed once per emulator launch. If it was written after the profiler already checked it, restart must be a visible user launch.

## Do not use as current truth

Old helper request files like `zgo_l19.req`, `vmouse.req`, and old copied `zprof.req` files may be stale. Treat them as obsolete unless their contents were just verified.

## 2026-07-01 L12 debug launch

This is the exact visible launch sequence that was used when checking L12.

1. Rebuild the game from the project root:

   ```powershell
   cd 'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2'
   .\build.cmd
   ```

   Result: build passed, `Build\ZUMA_VD2.SPG` was written at `2026-07-01 12:11:19`.

2. Verify/copy the fresh SPG into the patched Unreal runtime:

   ```powershell
   Copy-Item -LiteralPath 'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2\Build\ZUMA_VD2.SPG' `
     -Destination 'C:\Users\Администратор\Desktop\unreal_x64\ZUMA_VD2.SPG' -Force
   ```

   Fresh SPG hash after copy:

   ```text
   SHA256 AB0A2B1C244736F272E7C8E407F8F7FBB55F9A586BB88A2758686A3F0AC49385
   ```

3. Update the runtime `wc.img` manually. `build_wc_img.cmd` timed out before reaching the image-update step, so the image was updated directly:

   ```powershell
   python Source\OTHER\inject_zuma_to_wc_img.py `
     --base-img 'C:\Users\Администратор\Desktop\unreal_x64\wc.img' `
     --out-img  'C:\Users\Администратор\Desktop\unreal_x64\wc.img'
   ```

   The injector reported `/Games/Zuma Deluxe VDAC2/` files written, including:

   ```text
   ZUMA_VD2.SPG 365056
   ZUMALVL.PAK 7139840
   ZUMAMAIN.PAK 3653632
   ZUMAAUD.PAK 802136
   ZUMASND.PAK 1215488
   ```

   After injection, `C:\Users\Администратор\Desktop\unreal_x64\wc.img` timestamp was `2026-07-01 12:13:30`.

4. Launch patched Unreal visibly from its runtime directory, with a relative SPG argument:

   ```powershell
   Start-Process -FilePath '.\Unreal.exe' `
     -ArgumentList 'ZUMA_VD2.SPG' `
     -WorkingDirectory 'C:\Users\Администратор\Desktop\unreal_x64'
   ```

   Process check after launch:

   ```text
   Unreal.exe started from C:\Users\Администратор\Desktop\unreal_x64\Unreal.exe
   ```

Important: do not pass the full SPG path to Unreal for this workflow. Use `WorkingDirectory = C:\Users\Администратор\Desktop\unreal_x64` and `ArgumentList = ZUMA_VD2.SPG`.
