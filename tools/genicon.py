#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成阅读器 App 图标（纯标准库，无需 Pillow）。

用法: python3 tools/genicon.py <App.app 目录>
"""
import os
import struct
import sys
import zlib


def write_png(path, w, h, pixel):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes(pixel(x, y))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(blob)


def lerp(a, b, t):
    return a + (b - a) * t


def in_rrect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    if x < x0 + r and y < y0 + r:
        return (x - (x0 + r)) ** 2 + (y - (y0 + r)) ** 2 <= r * r
    if x > x1 - r and y < y0 + r:
        return (x - (x1 - r)) ** 2 + (y - (y0 + r)) ** 2 <= r * r
    if x < x0 + r and y > y1 - r:
        return (x - (x0 + r)) ** 2 + (y - (y1 - r)) ** 2 <= r * r
    if x > x1 - r and y > y1 - r:
        return (x - (x1 - r)) ** 2 + (y - (y1 - r)) ** 2 <= r * r
    return True


def make_icon(size):
    """深紫渐变底 + 白色书页 + 三条文字线 + 红色书签带"""
    page = (0.22 * size, 0.18 * size, 0.78 * size, 0.82 * size, 0.05 * size)
    lines = [(0.31 * size, 0.32 * size, 0.69 * size, 0.365 * size),
             (0.31 * size, 0.44 * size, 0.69 * size, 0.485 * size),
             (0.31 * size, 0.56 * size, 0.60 * size, 0.605 * size)]
    ribbon = (0.60 * size, 0.18 * size, 0.72 * size, 0.52 * size)

    def pixel(x, y):
        t = (x + y) / (2.0 * size)
        r = lerp(0.36, 0.20, t)
        g = lerp(0.22, 0.34, t)
        b = lerp(0.72, 0.92, t)
        if in_rrect(x, y, *page):
            r, g, b = 1.0, 1.0, 1.0
            for (x0, y0, x1, y1) in lines:
                if x0 <= x <= x1 and y0 <= y <= y1:
                    r, g, b = (0.45, 0.42, 0.70)
                    break
            if ribbon[0] <= x <= ribbon[2] and ribbon[1] <= y <= ribbon[3]:
                # 书签带底部做一个 V 形缺口
                tip = ribbon[3]
                if y > tip - 0.10 * size:
                    half = ribbon[2] - ribbon[0]
                    d = abs(x - (ribbon[0] + half / 2.0))
                    if d > (y - (tip - 0.10 * size)) * (half / 2.0) / (0.10 * size):
                        r, g, b = 1.0, 1.0, 1.0
                    else:
                        r, g, b = (0.90, 0.26, 0.32)
                else:
                    r, g, b = (0.90, 0.26, 0.32)
        return int(r * 255), int(g * 255), int(b * 255), 255

    return pixel


def main():
    if len(sys.argv) < 2:
        print("用法: python3 genicon.py <App.app 目录>", file=sys.stderr)
        return 1
    appdir = sys.argv[1]
    os.makedirs(appdir, exist_ok=True)
    for name, size in (("Icon60x60@2x.png", 120),
                       ("Icon60x60@3x.png", 180),
                       ("Icon1024.png", 1024)):
        write_png(os.path.join(appdir, name), size, size, make_icon(size))
        print("  生成图标 %s (%dx%d)" % (name, size, size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
