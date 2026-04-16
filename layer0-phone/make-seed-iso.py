#!/usr/bin/env python3
"""Minimal ISO 9660 builder for cloud-init NoCloud seed images.

Creates a valid ISO 9660 volume labelled 'CIDATA' that contains
user-data and meta-data at the filesystem root.  The image is
recognised by cloud-init's NoCloud datasource on all major distros.

Usage:
    python3 make-seed-iso.py OUTPUT.iso SEED_DIR

SEED_DIR must contain the files  user-data  and  meta-data.
"""

import os
import struct
import sys
import time

SECTOR = 2048  # ISO 9660 logical block size


# ── helpers ───────────────────────────────────────────────────────────────────

def _both16(n):
    """Return n as a both-endian 16-bit integer (4 bytes)."""
    return struct.pack('<H', n) + struct.pack('>H', n)


def _both32(n):
    """Return n as a both-endian 32-bit integer (8 bytes)."""
    return struct.pack('<I', n) + struct.pack('>I', n)


def _dir_ts():
    """7-byte directory-record timestamp (local time)."""
    t = time.localtime()
    return struct.pack('7B',
                       t.tm_year - 1900, t.tm_mon, t.tm_mday,
                       t.tm_hour, t.tm_min, t.tm_sec, 0)


def _dir_record(name, lba, size, is_dir=False):
    """Build a single ISO 9660 directory record.

    *name* is either a raw bytes identifier (b'\\x00' for '.', b'\\x01'
    for '..') or an ASCII string such as 'USER-DATA;1'.
    """
    raw = name if isinstance(name, bytes) else name.encode('ascii')
    nlen = len(raw)
    base = 33 + nlen
    rlen = base if base % 2 == 0 else base + 1  # total length must be even
    flags = 0x02 if is_dir else 0x00
    rec = bytearray()
    rec += struct.pack('BB', rlen, 0)   # record length, extended-attr length
    rec += _both32(lba)                 # location of extent
    rec += _both32(size)                # data length
    rec += _dir_ts()                    # recording date/time (7 bytes)
    rec += struct.pack('BBB', flags, 0, 0)  # flags, file-unit-size, interleave
    rec += _both16(1)                   # volume sequence number
    rec += struct.pack('B', nlen)       # length of file identifier
    rec += raw
    while len(rec) < rlen:
        rec += b'\x00'
    return bytes(rec)


def _pvd(vol_label, root_lba, total_sectors):
    """Build a 2 048-byte Primary Volume Descriptor."""
    pvd = bytearray(SECTOR)
    pvd[0] = 0x01                          # volume descriptor type = PVD
    pvd[1:6] = b'CD001'                    # standard identifier
    pvd[6] = 0x01                          # version
    # system identifier [8..39] – leave as spaces (0x20)
    for i in range(8, 40):
        pvd[i] = 0x20
    # volume identifier [40..71] – space-padded
    label = vol_label.upper().encode('ascii')
    for i in range(32):
        pvd[40 + i] = label[i] if i < len(label) else 0x20
    pvd[80:88] = _both32(total_sectors)    # volume space size
    pvd[120:124] = _both16(1)              # volume set size
    pvd[124:128] = _both16(1)              # volume sequence number
    pvd[128:132] = _both16(SECTOR)         # logical block size
    pvd[132:140] = _both32(10)             # path table size (10 bytes)
    struct.pack_into('<I', pvd, 140, 18)   # LE path table LBA
    struct.pack_into('<I', pvd, 144, 0)    # optional LE path table LBA
    struct.pack_into('>I', pvd, 148, 19)   # BE path table LBA
    struct.pack_into('>I', pvd, 152, 0)    # optional BE path table LBA
    # root directory record [156..189] – exactly 34 bytes (1-byte "." id)
    root_rec = _dir_record(b'\x00', root_lba, SECTOR, is_dir=True)
    pvd[156:156 + len(root_rec)] = root_rec
    pvd[881] = 0x01                        # file structure version
    return bytes(pvd)


def _vdst():
    """Volume Descriptor Set Terminator (2 048 bytes)."""
    vdst = bytearray(SECTOR)
    vdst[0] = 0xFF
    vdst[1:6] = b'CD001'
    vdst[6] = 0x01
    return bytes(vdst)


def _path_table(root_lba, big_endian=False):
    """One-entry path table for the root directory only."""
    pt = bytearray(SECTOR)
    pt[0] = 1   # length of directory identifier
    pt[1] = 0   # extended attribute record length
    if big_endian:
        struct.pack_into('>I', pt, 2, root_lba)
        struct.pack_into('>H', pt, 6, 1)
    else:
        struct.pack_into('<I', pt, 2, root_lba)
        struct.pack_into('<H', pt, 6, 1)
    pt[8] = 0x00  # directory identifier (NUL = root)
    pt[9] = 0x00  # padding (odd-length identifier → add one pad byte)
    return bytes(pt)


# ── public entry point ────────────────────────────────────────────────────────

def create_seed_iso(output_path, seed_dir):
    """Create a minimal cloud-init seed ISO from files in *seed_dir*.

    The produced image is a valid ISO 9660 volume labelled CIDATA that
    contains META-DATA and USER-DATA at the root.  When attached to a VM
    as a cdrom, cloud-init's NoCloud datasource will read it automatically.

    Sector layout
    -------------
    0-15  : system area (zeroed)
    16    : Primary Volume Descriptor
    17    : Volume Descriptor Set Terminator
    18    : Little-endian path table
    19    : Big-endian path table
    20    : Root directory records
    21    : meta-data file data
    22    : user-data file data
    """
    required_files = ('user-data', 'meta-data')
    files = []
    for fname in required_files:
        fpath = os.path.join(seed_dir, fname)
        if not os.path.isfile(fpath):
            sys.exit(
                f'ERROR: required seed file not found: {fpath}\n'
                f'       SEED_DIR must contain both "user-data" and "meta-data" files.'
            )
        with open(fpath, 'rb') as fh:
            files.append((fname.upper() + ';1', fh.read()))

    # Fixed LBA assignments
    root_lba = 20
    file_lbas = []
    lba = 21
    for _, data in files:
        file_lbas.append(lba)
        lba += max(1, (len(data) + SECTOR - 1) // SECTOR)
    total_sectors = lba

    # Build root directory sector
    root_dir = bytearray(SECTOR)
    pos = 0
    for special in (b'\x00', b'\x01'):   # "." and ".." entries
        rec = _dir_record(special, root_lba, SECTOR, is_dir=True)
        root_dir[pos:pos + len(rec)] = rec
        pos += len(rec)
    for i, (iso_name, data) in enumerate(files):
        rec = _dir_record(iso_name, file_lbas[i], len(data))
        root_dir[pos:pos + len(rec)] = rec
        pos += len(rec)

    with open(output_path, 'wb') as out:
        out.write(b'\x00' * (16 * SECTOR))                      # system area
        out.write(_pvd('CIDATA', root_lba, total_sectors))      # sector 16
        out.write(_vdst())                                       # sector 17
        out.write(_path_table(root_lba, big_endian=False))      # sector 18
        out.write(_path_table(root_lba, big_endian=True))       # sector 19
        out.write(bytes(root_dir))                               # sector 20
        for _, data in files:
            out.write(data)
            pad = (-len(data)) % SECTOR
            if pad:
                out.write(b'\x00' * pad)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} OUTPUT.iso SEED_DIR')
        sys.exit(1)
    create_seed_iso(sys.argv[1], sys.argv[2])
    print(f'[make-seed-iso] Created {sys.argv[1]}')
