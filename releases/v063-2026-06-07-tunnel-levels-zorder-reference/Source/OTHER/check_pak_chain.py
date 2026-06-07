import struct, sys
img = sys.argv[1]
start = int(sys.argv[2]) if len(sys.argv) > 2 else 179837
f = open(img, 'rb')
def rd(lba):
    f.seek(lba * 512); return f.read(512)
d = rd(0)
reserved = struct.unpack_from('<H', d, 14)[0]
fats = d[16]
fatsz = struct.unpack_from('<I', d, 36)[0]
datastart = reserved + fats * fatsz
def fatnext(c):
    f.seek(reserved * 512 + c * 4)
    v = struct.unpack('<I', f.read(4))[0] & 0x0FFFFFFF
    return None if (v >= 0x0FFFFFF8 or v < 2) else v
def clba(c):
    return datastart + (c - 2)
print(f"datastart={datastart}  PAK chain from cluster {start}:")
c = start
for i in range(5):
    lba = clba(c)
    s = rd(lba)
    hexs = ' '.join('%02X' % b for b in s[:16])
    print(f"  logsec{i} clus={c} lba={lba}  first16={hexs}")
    if i == 1:
        print("    TOC entry[0]=", struct.unpack_from('<6H', s, 0))
        print("    TOC entry[1]=", struct.unpack_from('<6H', s, 20))
    nx = fatnext(c)
    if nx is None:
        print("  EOC after this cluster")
        break
    if nx != c + 1:
        print(f"  !! NON-CONTIGUOUS: next cluster {nx} != {c+1}")
    c = nx
