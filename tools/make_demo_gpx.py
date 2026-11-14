"""Pack the demo song's score.gpif into a Guitar Pro 6 container (.gpx) for the tests.

    python tools/make_demo_gpx.py <demo.gp> <out.gpx>

.gpx = "BCFZ" + uncompressed length + bit stream (literals and back references) that
expands to "BCFS" + a file system of 0x1000-byte sectors. This writer produces the same
structure Guitar Pro 6 does: a file entry per file with its sector list.
"""
import struct
import sys
import zipfile

SECTOR = 0x1000


def bcfs(files):
    """files: [(name, bytes)] -> BCFS payload (without the 'BCFS' header)"""
    sectors = [bytes(SECTOR)]  # sector 0: unused header sector
    for name, data in files:
        entry_index = len(sectors)
        sectors.append(None)  # placeholder for the file entry
        ptrs = []
        for k in range(0, max(len(data), 1), SECTOR):
            ptrs.append(len(sectors))
            sectors.append(data[k:k + SECTOR].ljust(SECTOR, b"\0"))
        entry = bytearray(SECTOR)
        struct.pack_into("<i", entry, 0, 2)
        entry[4:4 + len(name)] = name.encode()
        struct.pack_into("<i", entry, 0x8C, len(data))
        for i, p in enumerate(ptrs):
            struct.pack_into("<i", entry, 0x94 + 4 * i, p)
        sectors[entry_index] = bytes(entry)
    return b"".join(sectors)


class BitWriter:
    def __init__(self):
        self.out, self.cur, self.n = bytearray(), 0, 0

    def bit(self, b):
        self.cur = (self.cur << 1) | b
        self.n += 1
        if self.n == 8:
            self.out.append(self.cur)
            self.cur, self.n = 0, 0

    def bits(self, v, n):          # MSB first
        for i in range(n - 1, -1, -1):
            self.bit((v >> i) & 1)

    def bits_rev(self, v, n):      # LSB first
        for i in range(n):
            self.bit((v >> i) & 1)

    def done(self):
        while self.n:
            self.bit(0)
        return bytes(self.out)


def bcfz(raw, ws=12):
    """greedy LZ77 in the BCFZ bit format"""
    w = BitWriter()
    maxv = (1 << ws) - 1
    i, n = 0, len(raw)
    index = {}
    lit = bytearray()

    def flush():
        while lit:
            chunk = lit[:3]
            del lit[:3]
            w.bit(0)
            w.bits_rev(len(chunk), 2)
            for b in chunk:
                w.bits(b, 8)

    while i < n:
        best_len, best_off = 0, 0
        key = raw[i:i + 4]
        for j in reversed(index.get(key, [])[-16:]):
            off = i - j
            if off > maxv:
                break
            length = 0
            while length < maxv and length < off and i + length < n and raw[j + length] == raw[i + length]:
                length += 1
            if length > best_len:
                best_len, best_off = length, off
        if best_len >= 4:
            flush()
            w.bit(1)
            w.bits(ws, 4)
            w.bits_rev(best_off, ws)
            w.bits_rev(best_len, ws)
            for k in range(i, i + best_len):
                index.setdefault(raw[k:k + 4], []).append(k)
            i += best_len
        else:
            lit.append(raw[i])
            index.setdefault(key, []).append(i)
            i += 1
    flush()
    return b"BCFZ" + struct.pack("<i", len(raw)) + w.done()


def main(gp_path, out_path, compressed=True):
    gpif = zipfile.ZipFile(gp_path).read("Content/score.gpif")
    payload = bcfs([("misc.xml", b"<Misc>" + b"x" * 5000 + b"</Misc>"), ("score.gpif", gpif)])
    raw = b"BCFS" + payload
    with open(out_path, "wb") as f:
        f.write(bcfz(raw) if compressed else raw)
    return out_path


if __name__ == "__main__":
    print("wrote", main(sys.argv[1], sys.argv[2]))
