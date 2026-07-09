# FT812 RAM_G map

Current reference: `Build/zuma.sym` + `Source/OTHER/audit_ramg_full.py`, checked on 2026-06-06.

FT812 RAM_G is exactly `#000000..#100000` (1 MiB). Addresses at or above `#100000`
alias back into low RAM_G on hardware, so they corrupt existing assets.

RAM_G is scene-profiled. Overlap between boot/menu/level-select/gameplay profiles is
normal because each scene reloads RAM_G. Overlap inside one active profile is a bug,
except the documented WIN overlay over balls.

## Boot loading profile

Shown while the main pak is being loaded.

| Range | Asset | Notes |
|---|---|---|
| `#000000..#03C000` | `BOOT_LOADING_BG_DXT_L4` | 640x480 pseudo-DXT L4 raw, 15 pages |
| `#03C000..#044000` | `BOOT_LOADING_BAR` | 395x37 ARGB4, 2 pages |
| `#044000..#06C000` | `BOOT_TS_ANIM` | 188x407 ARGB4 atlas, 10 pages |
| `#06C000..#070000` | `BOOT_SFX_AUTHORS` | Claude/Codex 48x48x2 ARGB4 atlas, 1 page; shown only while GS SFX load |

Max end: `#070000`.

## Main menu profile

Main menu uses 8bpp paletted graphics and its own RAM_G layout.

| Range | Asset |
|---|---|
| `#000000..#04B000` | `MENU_FG` |
| `#04B000..#065180` | `MENU_SKY` |
| `#065180..#0670C4` | `MENU_SUN` |
| `#0670C4..#071D08` | `MENU_GLOW` |
| `#071D08..#07CCC4` | Adventure button states |
| `#07CCC4..#087BD8` | Gauntlet button states |
| `#087BD8..#09446A` | Options button states |
| `#09446C..#09F40E` | More Games button states |
| `#09F410..#0ABA58` | Quit button states |
| `#0ABA60..#0ABC60` | `MENU_SKY_PAL` |
| `#0ABC60..#0ABE60` | `MENU_UI_PAL` |
| `#0AC000..#0ACB48` | `MENU_CURSOR` |

Max end: `#0ACB48`.

## Level select profile

Level select reuses the menu-style paletted layout. Preview/loading regions overlap
gameplay regions, but not while gameplay is active.

| Range | Asset | Notes |
|---|---|---|
| `#000000..#04B000` | `LS_BG` | level-select background |
| `#04B000..#082658` | `LS_SKY..LS_UI` | sky, sun, buttons, badges |
| `#084000..#08C000` | `LOADING_TEXT` | same RAM_G range later used by gameplay frame top |
| `#0ABA60..#0ABC60` | `LS_SKY_PAL` | shared menu palette address |
| `#0ABC60..#0ABE60` | `LS_UI_PAL` | shared menu palette address |
| `#0AC000..#0ACB48` | `LS_CURSOR` | shared menu cursor address |
| `#0B0000..#0B22AA` | Preview marker/frog/killzone | level preview sprites |
| `#0D4000..#0F4000` | `LS_PREVIEW_BG` | preview level background |

Max end: `#0F4000`.

## More Games profile

| Range | Asset |
|---|---|
| `#000000..#04B000` | `MORE_GAMES_BG` |
| `#0ABC60..#0ABE60` | `MORE_GAMES_PAL` |

Max end: `#0ABE60`.

## Gameplay profile after level load

This is the important steady-state map after a playable level has loaded.

| Range | Asset | Can be touched? |
|---|---|---|
| `#000000..#004000` | `TEXT_GAMEOVER` | No |
| `#004000..#00C000` | `FONT_LEVEL48` | No |
| `#00C000..#010000` | `SPARKLE` | No |
| `#010000..#02D4C0` | `BG_BITMAP` | No, current level background |
| `#02D500..#02D700` | `BG_PALETTE` | No, background palette |
| `#02D800..#030000` | `DIALOG_OK` | No |
| `#030000..#050000` | `FROG_ARGB4` | No, frog/plate/tongue/overlay |
| `#050000..#080000` | `BALLS_ARGB4` | No during gameplay |
| `#080000..#080200` | `BALLS_PALETTE` | No |
| `#080200..#080400` | `FRAME_PALETTE` | No |
| `#080400..#084000` | `TOP_MASK_A` | Reserved for active tunnel ARGB4 top-cover tiles |
| `#084000..#08C000` | `FRAME_TOP` | No |
| `#08C000..#090000` | `FRAME_BOT` | No |
| `#090000..#094000` | `FRAME_LEFT` | No |
| `#094000..#098000` | `FRAME_RIGHT` | No |
| `#098000..#0A0000` | `FONT_NATIVE` | No |
| `#0A0000..#0A4000` | `FONT_CANCUN10` | No |
| `#0A4000..#0AC000` | `FONT_CANCUN8` | No |
| `#0AC000..#0CC000` | `TOP_MASK_SWAP` / `DIALOG_FRAME` | swap-zone: tunnel top-cover in active gameplay, dialog frame in pause/dialog |
| `#0CC000..#0CC200` | `HUD_LIFE_FROG` | No |
| `#0CC200..#0CC400` | `HUD_PALETTE` | No |
| `#0CC400..#0CC600` | `DIALOG_PALETTE` | No |
| `#0CC800..#0CE400` | `HUD_MENU` | No |
| `#0CE400..#0CED60` | `HUD_PROGRESS` | No |
| `#0D0000..#0D4000` | `CURSOR` | No |
| `#0D4000..#0FC000` | `KZ+DESTROY` | No, killzone + destroy atlas |
| `#0FC000..#100000` | `TOP_MASK_B` | Reserved for active tunnel ARGB4 top-cover tiles |

Max end: `#100000`. There is no general free RAM_G in gameplay.

`#0AC000..#0CC000` is a state-dependent swap-zone, not normal free memory:

| State | Contents |
|---|---|
| active tunnel gameplay | optional ARGB4 tunnel top-cover tiles |
| pause/dialog | `DIALOG_FRAME`, loaded lazily |

In pause/dialog the renderer skips balls with `TRACKF_TUNNEL` and does not draw tunnel top-cover. The player sees the pause UI, while missing tunnel balls read as being behind the tunnel.

Small alignment holes exist, but should not be treated as allocation space:

| Range | Size | Reason |
|---|---:|---|
| `#02D4C0..#02D500` | 64 bytes | alignment between background bitmap and palette |
| `#02D700..#02D800` | 256 bytes | alignment before dialog OK |
| `#0CC600..#0CC800` | 512 bytes | alignment before HUD menu |
| `#0CED60..#0D0000` | 4768 bytes | alignment before cursor page |

## WIN state

WIN state is gameplay plus one intentional overlay:

| Range | Asset | Notes |
|---|---|---|
| `#050000..#064000` | `WINEXP_ATLAS` | Uploaded over `BALLS_ARGB4`; valid only after balls are no longer needed |

Do not use this overlap in normal gameplay. It is only valid for the win transition.

## Tunnel top-cover windows

Current tunnel top-cover windows:

| Range | Purpose |
|---|---|
| `#080400..#084000` | top-cover tile window A, 15 KiB |
| `#0AC000..#0CC000` | top-cover tile swap window / dialog frame, 128 KiB |
| `#0FC000..#100000` | top-cover tile window B, 16 KiB |

These windows are reserved even on non-tunnel levels because the renderer and upload
tables assume they are available when a tunnel level is active. They are also
fragment-sensitive: a single large color component may fail to fit even when the
total byte budget looks sufficient. Current storage uses small ARGB4 tiles.

## What must not be touched

- `#010000..#02D4C0` and `#02D500..#02D700`: current level background and palette.
- `#030000..#050000`: frog/plate/tongue/overlay.
- `#050000..#080000`: balls atlas, except WIN-only replacement by `WINEXP_ATLAS`.
- `#080000..#080400`: ball and frame palettes.
- `#084000..#098000`: frame strips.
- `#098000..#0AC000`: custom font atlases.
- `#0AC000..#0CC000`: swap-zone. Active gameplay may use it for tunnel top-cover; pause/dialog reloads `DIALOG_FRAME` here.
- `#0CC000..#0CC600`: HUD/dialog palettes/assets.
- `#0D0000..#0D4000`: cursor.
- `#0D4000..#0FC000`: killzone + destroy atlas.
- `#080400..#084000`, `#0AC000..#0CC000`, and `#0FC000..#100000`: tunnel top-cover tile windows in active gameplay.

FT812 ROM font glyph data is not stored in RAM_G. It is built into the chip and
cannot be freed or repurposed as video memory.

Important: bitmap handles `16..31` are still reserved for FT812 ROM fonts by
default. Do not reuse these handles for RAM_G sprites. We already hit this bug:
`ZL_WINEXP_HANDLE` was `26`, the same handle used by `CMD_NUMBER`/debug clock font
26. The win-explosion code changed `BITMAP_SOURCE(26)` to the explosion atlas at
`#050000`, and the clock then read digits from that atlas instead of ROM font 26.
Current fix: `ZL_WINEXP_HANDLE EQU 9`, outside the ROM-font handle range.

The custom project fonts listed above are separate RAM_G assets and must be treated
as live gameplay allocations.

## Verification command

Run this after RAM_G layout changes:

```powershell
python Source\OTHER\audit_ramg_full.py
```

Expected final line for a valid layout:

```text
OK: все профили влезают в 1МБ, живых перекрытий нет.
```
