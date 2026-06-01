# v056 boot-gs-sfx-hwverified baseline

Date: 2026-06-01

Reference point after hardware/user confirmation that boot music and SFX work with the small boot SPG + external `ZUMAMAIN.PAK` loader.

Included state:
- Small boot SPG loads boot artwork, starts GS menu music during boot, then loads SFX and `ZUMAMAIN.PAK`.
- `ZUMAAUD.PAK` music cache path fixed: page-sector counter is preserved while reading RawPak sectors.
- SFX loading no longer depends on the unreliable `GS_RamPages >= 128` gate.
- SFX stream gives FT812 time slices between sectors: loading animation/progress can update while GS SFX are loading.
- Boot progress screen uses HD-ref canvas/progress bar, ZX Evolution animation, black-as-alpha frames, and FT812 drop shadow.
- ZX Evolution animation starts later and advances more slowly.
- Main menu does not restart music on first entry after boot; music is restarted only after gameplay has stopped it.
- Current working image was injected into `wc.img` and verified with `check_host_wc_img.py`.

Root release artifacts:
- `v056-2026-06-01-boot-gs-sfx-hwverified-baseline.spg`
- `v056-2026-06-01-boot-gs-sfx-hwverified-baseline.zumaaud.pak`
- `v056-2026-06-01-boot-gs-sfx-hwverified-baseline.zumamain.pak`
- `v056-2026-06-01-boot-gs-sfx-hwverified-baseline.zumasnd.pak`

Source snapshot:
- `Source/`
- `Build/`
- `Graphics/Load Screen/`
- `Graphics/Converted/BootLoading/`
- build configs and `Чат.txt`
