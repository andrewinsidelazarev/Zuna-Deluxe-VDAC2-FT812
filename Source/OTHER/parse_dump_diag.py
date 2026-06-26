#!/usr/bin/env python3
# Parse a 64K Unreal RAM dump of the instrumented RawPak build.
# Assumes slot1 (#4000-#7FFF) = Core page5, so file offset == Z80 address.
# Usage: python parse_dump_diag.py [path-to-dump]   (default: ./111)
import sys, struct

A = {
    'BOOT_CANARY': 0x5044,
    'ZiFiTraceStep': 0x6215,
    'ZiFiTraceOpenStep': 0x621A,   # RawPak open granular step
    'ZiFiTraceDirsVisited': 0x621B,  # FindInCurrentDir call counter
    'RawPak_Spc': 0x6633,
    'RawPak_TargetName': 0x6639,   # 64-byte buffer (uppercased name searched)
    'RawPak_FoundAttr': 0x66BA,
    'RawPak_FoundClus': 0x66BB,    # 4 bytes
    'RawPak_FatStart': 0x66BF,
    'RawPak_DataStart': 0x66C3,
    'RawPak_RootClus': 0x66C7,
    'RawPak_FileStartClus': 0x66CB,
    'RawPak_CurClus': 0x66CF,
    'TraceDriverState': 0x69C2,    # +0 BPB(64B), +64 dir sector(96B)
    'CurrentLevel': 0x6DC4,
    'ZiFi_LevelTOC': 0x68DE,       # 20-byte loaded TOC entry
    'ZiFiTraceBgOff': 0x6216,
    'ZiFiTraceBgSize': 0x6218,
}

OPEN_STEP = {
    0x00: 'not entered', 0x20: 'entered OpenRoot', 0x21: 'BPB read OK (CMD17 returned)',
    0x22: 'BPB valid (512/spc=1)', 0x23: 'GAMES dir found', 0x24: 'ZUMA dir found',
    0x25: 'ZUMALVL.PAK found (OpenRoot OK)',
    0xA1: 'ERR: BPB CMD17 read failed', 0xA2: 'ERR: bytes/sector != 512',
    0xA3: 'ERR: sectors/cluster != 1', 0xA4: 'ERR: GAMES not found',
    0xA5: 'ERR: ZUMADE~1 not found', 0xA6: 'ERR: ZUMALVL.PAK not found',
}
GP_STEP = {
    0x00:'not started',0x01:'after Init',0x02:'after PakOpen',0x03:'after PakReadToc/validate',
    0x34:'SD phase: bg read into pages #07-#0E done',
    0x35:'SD phase: track read into page #06 done',
    0x04:'FT phase: bg uploaded to RAM_G',0x05:'(unused)',
    0x06:'FT phase: palette uploaded -> FULL SUCCESS',
    0xFF:'Init err',0xFE:'PakOpen err',0xFD:'PakReadToc err',
}

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else '111'
    d = open(path, 'rb').read()
    print(f'dump: {path}  ({len(d)} bytes)')
    def b(a): return d[a]
    def w(a): return struct.unpack_from('<H', d, a)[0]
    def dw(a): return struct.unpack_from('<I', d, a)[0]
    def asc(a, n): return ''.join(chr(x) if 32 <= x < 127 else '.' for x in d[a:a+n])

    can = asc(A['BOOT_CANARY'], 4)
    print(f"\nBOOT canary #5044 = {' '.join('%02X'%x for x in d[A['BOOT_CANARY']:A['BOOT_CANARY']+4])} = \"{can}\""
          + ('   <-- Core ran' if can == 'BOOT' else '   <-- MISSING: Core not in slot1 / boot hang'))

    gp = b(A['ZiFiTraceStep']); op = b(A['ZiFiTraceOpenStep']); wk = b(A['ZiFiTraceDirsVisited'])
    print(f"\nZiFiTraceStep   #6215 = #{gp:02X}  {GP_STEP.get(gp,'?')}")
    print(f"RawPak openStep #621A = #{op:02X}  {OPEN_STEP.get(op,'?')}")
    print(f"FindInDir calls #621B = {wk}  (1=root/GAMES, 2=GAMES/ZUMA, 3=ZUMA/PAK)")
    print(f"CurrentLevel    #6A2A = #{b(A['CurrentLevel']):02X}")
    print(f"RawPak_Spc            = {b(A['RawPak_Spc'])}")
    print(f"RawPak_TargetName     = \"{asc(A['RawPak_TargetName'],20)}\"  (name it was searching)")
    print(f"RawPak_FoundAttr      = #{b(A['RawPak_FoundAttr']):02X}")
    for nm in ('RawPak_FatStart','RawPak_DataStart','RawPak_RootClus',
               'RawPak_FileStartClus','RawPak_CurClus','RawPak_FoundClus'):
        print(f"{nm:21s} = {dw(A[nm])}")

    if 'ZiFi_LevelTOC' in A:
        t = A['ZiFi_LevelTOC']
        labels = ('bg_off','bg_size','pal_off','pal_size','track_off',
                  'track_size','title_off','title_size','prev_off','prev_size')
        print("\n--- ZiFi_LevelTOC (loaded entry for CurrentLevel) ---")
        print('  ' + '  '.join(f'{labels[i]}={w(t+i*2)}' for i in range(10)))
        print(f"  ZiFiTraceBgOff={w(A['ZiFiTraceBgOff'])}  ZiFiTraceBgSize={w(A['ZiFiTraceBgSize'])}")

    base = A['TraceDriverState']
    print("\n--- TraceDriverState+0: BPB sector 0 (what CMD17 returned) ---")
    print('  hex :', ' '.join('%02X'%x for x in d[base:base+32]))
    print('  asc :', asc(base, 32))
    print(f"  OEM           = {d[base+3:base+11]!r}")
    print(f"  bytes/sector  = {w(base+11)}")
    print(f"  sec/cluster   = {d[base+13]}")
    print(f"  reserved      = {w(base+14)}")
    print(f"  num FATs      = {d[base+16]}")
    print(f"  FATsz32       = {dw(base+36)}")
    print(f"  root cluster  = {dw(base+44)}")

    dbase = base + 64
    print("\n--- TraceDriverState+64: directory sector (last dir scanned) ---")
    print('  hex :', ' '.join('%02X'%x for x in d[dbase:dbase+32]))
    for i in range(3):
        e = dbase + i*32
        name = asc(e, 11); attr = d[e+11]
        clus = (w(e+20) << 16) | w(e+26); size = dw(e+28)
        first = d[e]
        tag = ' (free/empty)' if first == 0 else ' (deleted)' if first == 0xE5 else \
              ' (LFN)' if attr == 0x0F else ''
        print(f"  entry{i}: \"{name}\" attr=#{attr:02X} clus={clus} size={size}{tag}")

if __name__ == '__main__':
    main()
