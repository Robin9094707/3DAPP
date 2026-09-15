"""Build the repository's geometric app icon using only Python's standard library."""
from pathlib import Path
import json
import math
import struct
import zlib

SIZE = 1024
pixels = bytearray(SIZE * SIZE * 3)
for y in range(SIZE):
    for x in range(SIZE):
        glow = max(0, 1 - math.hypot(x - 270, y - 200) / 1100)
        at = (y * SIZE + x) * 3
        pixels[at:at + 3] = bytes((int(7 + 13 * glow), int(15 + 32 * glow), int(28 + 39 * glow)))


def paint(x, y, color):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        at = (y * SIZE + x) * 3
        pixels[at:at + 3] = bytes(color)


def polygon(points, color):
    for y in range(max(0, min(p[1] for p in points)), min(SIZE, max(p[1] for p in points) + 1)):
        intersections = []
        for a, b in zip(points, points[1:] + points[:1]):
            if (a[1] <= y < b[1]) or (b[1] <= y < a[1]):
                intersections.append(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]))
        intersections.sort()
        for left, right in zip(intersections[::2], intersections[1::2]):
            for x in range(max(0, int(left)), min(SIZE, int(right) + 1)):
                paint(x, y, color)


def line(a, b, color, radius=6):
    steps = max(abs(a[0] - b[0]), abs(a[1] - b[1]), 1)
    for step in range(steps + 1):
        x = round(a[0] + (b[0] - a[0]) * step / steps)
        y = round(a[1] + (b[1] - a[1]) * step / steps)
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                if dx * dx + dy * dy <= radius * radius:
                    paint(x + dx, y + dy, color)


top, left, right = (512, 224), (242, 380), (782, 380)
center, bottom, low_left, low_right = (512, 540), (512, 805), (242, 650), (782, 650)
polygon([top, left, center, right], (54, 104, 128))
polygon([left, center, bottom, low_left], (24, 65, 80))
polygon([center, right, low_right, bottom], (28, 119, 115))
for a, b in [(top, left), (top, right), (left, center), (right, center), (left, low_left), (right, low_right), (center, bottom), (low_left, bottom), (low_right, bottom)]:
    line(a, b, (97, 244, 215), 6)
polygon([(565, 562), (698, 485), (698, 615), (565, 692)], (56, 176, 166))
for a, b in [((565, 562), (698, 485)), ((698, 485), (698, 615)), ((698, 615), (565, 692)), ((565, 692), (565, 562))]:
    line(a, b, (180, 255, 236), 3)
for a, b, c in [((175, 330), (175, 175), (330, 175)), ((694, 175), (849, 175), (849, 330)), ((175, 694), (175, 849), (330, 849)), ((694, 849), (849, 849), (849, 694))]:
    line(a, b, (217, 248, 250), 8)
    line(b, c, (217, 248, 250), 8)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


scanlines = b''.join(b'\0' + pixels[y * SIZE * 3:(y + 1) * SIZE * 3] for y in range(SIZE))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(scanlines, 9)) + chunk(b'IEND', b'')
root = Path(__file__).resolve().parents[1] / 'Spatial' / 'Assets.xcassets'
icon = root / 'AppIcon.appiconset'
icon.mkdir(parents=True, exist_ok=True)
(icon / 'AppIcon.png').write_bytes(png)
(root / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2))
(icon / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2))
print('Generated opaque 1024px AppIcon.png')
