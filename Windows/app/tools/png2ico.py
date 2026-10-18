#!/usr/bin/env python3
"""PNG → ICO converter (no dependencies).

Builds a multi-size Windows icon with classic BMP entries (the format
windows resource compilers and Explorer handle best):

    python3 png2ico.py out.ico 16.png 32.png 48.png 256.png
"""

import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG"
    pos = 8
    idat = b""
    w = h = bd = ct = None
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        chunk_type = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", chunk[:10])
        elif chunk_type == b"IDAT":
            idat += chunk
        elif chunk_type == b"IEND":
            break
    assert bd == 8 and ct in (2, 6), f"{path}: expected 8-bit RGB/RGBA, got depth={bd} type={ct}"
    raw = zlib.decompress(idat)
    bpp = 3 if ct == 2 else 4
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        filter_type = raw[p]
        p += 1
        line = bytearray(raw[p : p + stride])
        p += stride
        if filter_type == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                predictor = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + predictor) & 0xFF
        out += line
        prev = line

    rgba = bytearray()
    for i in range(0, len(out), bpp):
        r, g, b = out[i], out[i + 1], out[i + 2]
        a = out[i + 3] if bpp == 4 else 255
        rgba += bytes((r, g, b, a))
    return w, h, rgba


def bmp_entry(w, h, rgba):
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    body = bytearray()
    for y in range(h - 1, -1, -1):
        row = rgba[y * w * 4 : (y + 1) * w * 4]
        for x in range(w):
            r, g, b, a = row[x * 4 : x * 4 + 4]
            body += bytes((b, g, r, a))
    mask_row = ((w + 31) // 32) * 4
    body += bytes(mask_row * h)
    return header + bytes(body)


def main():
    out_path = sys.argv[1]
    entries = []
    for png in sys.argv[2:]:
        w, h, rgba = read_png(png)
        entries.append((w, h, bmp_entry(w, h, rgba)))
    data = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    images = b""
    for w, h, blob in entries:
        data += struct.pack(
            "<BBBBHHII",
            w if w < 256 else 0,
            h if h < 256 else 0,
            0,
            0,
            1,
            32,
            len(blob),
            offset,
        )
        offset += len(blob)
        images += blob
    open(out_path, "wb").write(data + images)
    print(f"{out_path}: {len(entries)} sizes, {offset} bytes")


if __name__ == "__main__":
    main()
