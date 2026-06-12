import struct, os

name = ''.join(chr(c) for c in [0x420,0x430,0x431,0x43E,0x442,0x430,0x2E,0x410,0x43D,0x434,0x440,0x435,0x439])
img = '\\\\tsclient\\D\\' + name + '\\unreal_x64\\wc.img'
print('img:', img, 'exists:', os.path.exists(img))
f = open(img, 'rb')
bpb = f.read(512)
bps = struct.unpack_from('<H', bpb, 11)[0]; spc = bpb[13]
rsvd = struct.unpack_from('<H', bpb, 14)[0]; nfat = bpb[16]
fatsz = struct.unpack_from('<I', bpb, 36)[0]; rootclus = struct.unpack_from('<I', bpb, 44)[0]
print(f'bps={bps} spc={spc} rsvd={rsvd} nfat={nfat} fatsz={fatsz} rootclus={rootclus}')
data_start = (rsvd + nfat * fatsz) * bps
fat_start = rsvd * bps

def clus_off(c): return data_start + (c - 2) * spc * bps

def next_clus(c):
    f.seek(fat_start + c * 4)
    return struct.unpack('<I', f.read(4))[0] & 0x0FFFFFFF

c = rootclus
found = None
for _ in range(64):
    f.seek(clus_off(c)); buf = f.read(spc * bps)
    for i in range(0, len(buf), 32):
        e = buf[i:i+32]
        if e[0] == 0: break
        if e[0] == 0xE5: continue
        if e[11] == 0x0F: continue
        nm = bytes(e[0:8]).decode('latin1').rstrip()
        ext = bytes(e[8:11]).decode('latin1').rstrip()
        if nm.upper().startswith('BOOT'):
            fc = (struct.unpack_from('<H', e, 20)[0] << 16) | struct.unpack_from('<H', e, 26)[0]
            sz = struct.unpack_from('<I', e, 28)[0]
            print(f'  ENTRY name={nm!r} ext={ext!r} firstclus={fc} size={sz}')
            if found is None: found = (fc, sz, nm, ext)
    nc = next_clus(c)
    if nc >= 0x0FFFFFF8 or nc == 0: break
    c = nc

if found:
    fc, sz, nm, ext = found
    f.seek(clus_off(fc)); hdr = f.read(32)
    print('first 32 bytes:', ' '.join('%02X' % b for b in hdr))
    print('HOBETA fields:')
    print('  name   =', repr(bytes(hdr[0:8]).decode('latin1')))
    print('  type   =', repr(chr(hdr[8])))
    print('  +9  word (start addr)  = %#06x (%d)' % (struct.unpack_from('<H', hdr, 9)[0],) * 2)
    print('  +11 word (len bytes)   = %d' % struct.unpack_from('<H', hdr, 11)[0])
    print('  +13 byte (sectors)     = %d' % hdr[13])
    print('  +14 byte               = %#04x' % hdr[14])
    print('  +15 word (crc?)        = %#06x' % struct.unpack_from('<H', hdr, 15)[0])
    print('  file size on disk      =', sz)
else:
    print('boot.* NOT FOUND in root')
f.close()
