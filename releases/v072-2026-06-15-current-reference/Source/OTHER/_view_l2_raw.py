"""Визуализировать 549556_l2.bin как (c0 160×120 RGB565) | (c1 160×120 RGB565) | (L2 mask 640×480)."""
import struct, os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'Converted')
TEMP_DIR = PROJECT_ROOT
with open(os.path.join(CONVERTED, '549556_l2.bin'), 'rb') as f:
    data = f.read()

def rgb565_to_img(buf, w, h):
    im = Image.new('RGB', (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            v = struct.unpack('<H', buf[(y*w+x)*2 : (y*w+x)*2 + 2])[0]
            r = ((v >> 11) & 0x1F) << 3
            g = ((v >> 5) & 0x3F) << 2
            b = (v & 0x1F) << 3
            px[x, y] = (r, g, b)
    return im

def l2_to_img(buf, w, h, alpha_table=(0, 255, 85, 170)):
    im = Image.new('L', (w, h))
    px = im.load()
    stride = w // 4
    for y in range(h):
        for x in range(w):
            byte = buf[y*stride + (x>>2)]
            sel = (byte >> ((3 - (x & 3)) * 2)) & 3
            px[x, y] = alpha_table[sel]
    return im

c0 = data[0:38400]
c1 = data[38400:76800]
l2 = data[76800:153600]

rgb565_to_img(c0, 160, 120).save(os.path.join(TEMP_DIR, '_real_c0.png'))
rgb565_to_img(c1, 160, 120).save(os.path.join(TEMP_DIR, '_real_c1.png'))
l2_to_img(l2, 640, 480).save(os.path.join(TEMP_DIR, '_real_l2_msb.png'))
l2_to_img(l2, 640, 480, alpha_table=(0, 85, 170, 255)).save(os.path.join(TEMP_DIR, '_real_l2_linear.png'))
print('saved _real_c0.png _real_c1.png _real_l2_msb.png _real_l2_linear.png')
