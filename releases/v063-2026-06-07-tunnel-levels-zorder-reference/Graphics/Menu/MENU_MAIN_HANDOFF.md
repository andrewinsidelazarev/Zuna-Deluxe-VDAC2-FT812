# Zuma VDAC2 Main Menu Handoff

## Scope

Current work is only for the VDAC2 FT812 main menu screen:

- animated sky strip;
- alpha foreground canvas over the sky;
- sun and sun glow;
- five main-menu buttons with normal, hover, and pressed states.

Level select will use the same general approach later, but it is not converted in
this pass yet.

## Source References

HD atlas:

`C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-ref\content\images\menu.png`

Current HD atlas slice coordinates:

`C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-ref\src\zuma\ResourceStore.c`

Playable HD menu algorithm:

`C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-release-v010-ref\src\menu\MenuMgr.c`

The local `Zuma-Deluxe-HD-ref` checkout only contains the atlas mapping for menu
sprites. The actual old menu draw/update code was taken from the
`release-v0.1.0` branch cloned to `Zuma-Deluxe-HD-release-v010-ref`.

## Prepared Folders

HD slices:

`Graphics\Menu\Original HD`

Scaled source PNGs in VDAC2 screen space:

`Graphics\Menu\Original to 640-480`

FT812 converted menu assets:

`Graphics\Menu\Converted`

Converters:

- `Source\OTHER\slice_menu_hd.py`
- `Source\OTHER\scale_menu_hd_640.py`
- `Source\OTHER\make_menu_main_paletted.py`

## Geometry Rule

HD menu canvases are `1280x720` and are center-cropped to 4:3 before scaling:

```text
HD source canvas: 1280x720
4:3 crop rect:    x=160, y=0, w=960, h=720
VDAC2 target:     640x480
scale factor:     2/3
```

For HD screen placement coordinates:

```text
x_640 = (x_hd - 160) * 2 / 3
y_480 = y_hd * 2 / 3
w_640 = w_hd * 2 / 3
h_480 = h_hd * 2 / 3
```

Negative X is valid for cropped source placement. The sun/glow overlap the left
crop boundary.

## Main Menu Draw Order

The HD order is:

1. draw animated sky strip twice for horizontal wrap;
2. draw main foreground canvas over the sky;
3. draw buttons;
4. draw sun;
5. draw tinted sun glow;
6. draw text overlays.

For VDAC2, keep at least:

1. sky;
2. alpha foreground;
3. button states;
4. sun;
5. glow.

The foreground PNG must keep alpha. The sky must be visible through transparent
and semitransparent pixels in the top region of the foreground canvas.

## HD Sky Animation

From `Menu_Draw` in `release-v0.1.0`:

```c
static int skyPos = 0;
skyPos += SKY_SPD;       // SKY_SPD = 1
skyPos %= 1280;

draw_sky(x = skyPos,      y = 0);
draw_sky(x = skyPos-1279, y = 0);
draw_foreground();
```

HD sky source rect:

```text
x=0, y=720, w=1280, h=250
```

Prepared VDAC2 sky PNG:

`Original to 640-480\main_screen_sky_canvas_4x3.png`

Prepared converted FT812 sky bitmap:

`Converted\main_screen_sky_canvas_4x3.bin`

VDC2 sky output size is `640x167`.

Suggested exact-speed VDAC2 implementation:

- maintain sky X in fixed point;
- add `2/3` output pixel per HD-equivalent update;
- wrap at `640`;
- draw two copies of the 640 px sky strip:
  - first at `skyPos`;
  - second at `skyPos - 639` or equivalent overlap-safe wrapped value.

If frame cadence differs from HD, tune fixed-point step by observed real speed,
but keep the two-copy horizontal wrap algorithm.

## HD Sun And Glow

HD sun draw from `MenuMgr_Draw`:

```text
sun source atlas rect:  x=2563, y=315, w=130, h=138
sun HD dest rect:       x=158,  y=16,  w=130, h=138

glow source atlas rect: x=2563, y=0,   w=315, h=315
glow HD dest rect:      x=68,   y=-68, w=315, h=315
glow alpha mod:         152
glow color mod:         RGB(255,192,0)
```

VDAC2 placement after 4:3 center crop and scale:

```text
sun rect:  x=-1,  y=11,  w=87,  h=92
glow rect: x=-61, y=-45, w=210, h=210
```

Current converted assets:

- `Converted\main_sun.bin`
- `Converted\main_sun_light.bin`

Both share `Converted\main_menu_ui_palette_argb4.bin` with the foreground and
buttons.

## Main Buttons

HD uses top-left placement coordinates and a dead hit border of 16 HD pixels.
Scaled hit dead border is about 11 VDAC2 pixels.

| Button | VDAC2 rect x,y,w,h |
| --- | --- |
| Adventure | `453,63,163,92` |
| Gauntlet | `437,153,180,83` |
| Options | `420,236,199,86` |
| More Games | `393,301,118,127` |
| Quit | `495,313,120,141` |

Button PNG/bin names use:

```text
main_button_<name>_normal
main_button_<name>_hover
main_button_<name>_pressed
```

## FT812 Converted Format

Current main-menu conversion is PALETTED4444:

- sky is opaque `FT_PALETTED4444` with its own palette;
- foreground, sun, glow, and button states share an alpha-preserving
  `FT_PALETTED4444` UI palette;
- UI palette index 0 is transparent.

Palettes:

- `Converted\main_menu_sky_palette_argb4.bin`
- `Converted\main_menu_ui_palette_argb4.bin`

Primary storage compression for menu assets is zlib:

- raw `.bin` is the RAM_G payload;
- `.zlib` is the preferred packaged stream for FT812 `CMD_INFLATE`.
- FT812 does the zlib decompression in hardware; current main foreground uses
  five independent zlib streams because the current TSLib feeder path sends one
  compressed stream below 64K at a time.

Do not default back to ZX7 for the menu unless there is a specific loader reason.
For current main-menu data zlib is materially smaller than the old temporary
ZX7 outputs.

## Current Memory Snapshot

Read exact current values from:

`Converted\main_menu_assets.json`

At the time this handoff file was written:

```text
raw PALETTED4444 menu payload without RAM_G alignment: about 704 KB
zlib streams for those bitmap payloads:                about 297 KB
palettes:                                             1024 bytes
```

This is a menu-only RAM_G profile. Do not count these assets together with the
gameplay RAM_G profile. Main menu and gameplay should reload FT812 graphics
sets and share only program state such as input, chosen level, score/lives
parameters where relevant.

## Machine-Readable Metadata

Use this first:

`Converted\main_menu_assets.json`

It includes:

- asset sizes and zlib sizes;
- alpha bounding boxes;
- draw-order notes;
- HD sky algorithm;
- HD and VDAC2 sun/glow rectangles;
- VDAC2 main button rectangles.
