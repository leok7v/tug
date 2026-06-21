#!/usr/bin/env python3
# build-sparse.py — pack a sparse disk image into a compact manifest Boat can
# expand on first launch (iOS can't create an ext4 fs, so we ship a pre-seeded
# one; bundling the raw 32G sparse file would balloon to 32G once the .ipa is
# unpacked on device, so we ship only the allocated extents).
#
# Format (little-endian):
#   magic   "TUGSPRS1"            (8 bytes)
#   total   UInt64                full image size in bytes
#   repeated until EOF:
#     offset UInt64, length UInt64, data[length]
#
# Usage: build-sparse.py <disk.img> <out.sparse>
import os, sys, struct

src, dst = sys.argv[1], sys.argv[2]
size = os.path.getsize(src)
fd = os.open(src, os.O_RDONLY)
out = open(dst, "wb")
out.write(b"TUGSPRS1")
out.write(struct.pack("<Q", size))

data_bytes = 0
off = 0
while off < size:
    try:
        d = os.lseek(fd, off, os.SEEK_DATA)   # next allocated byte
    except OSError:
        break                                  # no more data -> trailing hole
    h = os.lseek(fd, d, os.SEEK_HOLE)          # end of this data extent
    length = h - d
    os.lseek(fd, d, os.SEEK_SET)
    out.write(struct.pack("<QQ", d, length))
    remaining = length
    while remaining > 0:
        chunk = os.read(fd, min(1 << 20, remaining))
        if not chunk:
            raise IOError("short read packing sparse image")
        out.write(chunk)
        remaining -= len(chunk)
    data_bytes += length
    off = h

os.close(fd)
out.close()
print(f"sparse: {dst}  total={size/1e9:.1f}GB data={data_bytes/1e6:.1f}MB "
      f"manifest={os.path.getsize(dst)/1e6:.1f}MB")
