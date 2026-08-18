"""AXIS-FIX byte patch for the CE-synthesized housecat motlists (2026-08-18).

Forensic finding: the only functional difference between the crashing cat
motlists and the field-proven horse motlist is the Blender->FBX axis pair:
the 'ch99_200 Armature' pseudo-bone carries a constant -90degX rotation and
'root' carries the inverse +90degX -- in rest pose AND on every animation key.
The proven horse file has identity on both.  This patch normalizes the pair
to identity while preserving world-space motion:

  armature: rest quat -> identity; ROT keys -> identity; TRANS keys kept
  root:     rest quat -> rx(-90) x q; rest/key TRANS v -> (x, z, -y);
            ROT keys  -> rx(-90) x q  (general multiply, so any authored
            one-shot travel survives)

Output goes LOOSE into the game natives tree (loose loading is field-proven
by the horse v2.2 loose install), under NEW paths so nothing collides with
the v0.9.3 pak:
  natives/stm/character/ch/iris_housecat/iris_housecat_bisect3_axisfix.motlist.751
  natives/stm/character/ch/iris_housecat/iris_housecat_full_axisfix.motlist.751
"""
from __future__ import annotations

import math
import struct
from pathlib import Path

RS = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools")
GAME_LOOSE = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\natives\stm\character\ch\iris_housecat")

JOBS = [
    (RS / "exports/w3_housecat_BISECT.motlist.751", GAME_LOOSE / "iris_housecat_bisect3_axisfix.motlist.751"),
    (RS / "exports/w3_housecat_full_catalogue.motlist.751", GAME_LOOSE / "iris_housecat_full_axisfix.motlist.751"),
]

ARMATURE_HASH = 0xACC2584F   # mm3(utf16le) "ch99_200 Armature"
ROOT_HASH = 0xABA7DE3C       # "root"
RX_NEG90 = (-math.sqrt(0.5), 0.0, 0.0, math.sqrt(0.5))


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def fix_rot3(x, y, z):
    """Stored 3-comp quat (w = +sqrt(1-|v|^2)); return rx(-90) * q, w kept +."""
    w2 = 1.0 - (x * x + y * y + z * z)
    w = math.sqrt(w2) if w2 > 0.0 else 0.0
    nx, ny, nz, nw = qmul(RX_NEG90, (x, y, z, w))
    if nw < 0.0:
        nx, ny, nz, nw = -nx, -ny, -nz, -nw
    return nx, ny, nz


def rot_vec(x, y, z):
    return (x, z, -y)


def unique_mots(buf):
    ptr_tab = struct.unpack_from("<Q", buf, 0x10)[0]
    n = struct.unpack_from("<I", buf, 0x30)[0]
    out = []
    for i in range(n):
        m = struct.unpack_from("<Q", buf, ptr_tab + 8 * i)[0]
        if m not in out:
            out.append(m)
    return out


def patch(src: Path, dst: Path):
    buf = bytearray(src.read_bytes())
    stats = {"rest": 0, "rot_keys": 0, "trans_keys": 0, "mots": 0}
    for mot in unique_mots(buf):
        stats["mots"] += 1
        # ---- bone table rest poses ----
        tab = struct.unpack_from("<Q", buf, mot + 0x10)[0]
        cnt = struct.unpack_from("<Q", buf, mot + tab + 0x08)[0]
        for k in range(cnt):
            eo = mot + tab + 0x10 + k * 0x50
            h = struct.unpack_from("<I", buf, eo + 0x44)[0]
            if h == ARMATURE_HASH:
                struct.pack_into("<4f", buf, eo + 0x30, 0.0, 0.0, 0.0, 1.0)
                stats["rest"] += 1
            elif h == ROOT_HASH:
                tx, ty, tz = struct.unpack_from("<3f", buf, eo + 0x20)
                struct.pack_into("<3f", buf, eo + 0x20, *rot_vec(tx, ty, tz))
                qx, qy, qz, qw = struct.unpack_from("<4f", buf, eo + 0x30)
                nx, ny, nz, nw = qmul(RX_NEG90, (qx, qy, qz, qw))
                struct.pack_into("<4f", buf, eo + 0x30, nx, ny, nz, nw)
                stats["rest"] += 1
        # ---- animation tracks ----
        ntr = struct.unpack_from("<H", buf, mot + 0x70)[0]
        for ti in range(ntr):
            to = mot + 0x80 + ti * 12
            _flags, h, rel = struct.unpack_from("<III", buf, to)
            if h not in (ARMATURE_HASH, ROOT_HASH):
                continue
            for di in range(2):
                typ, kc, idxo, datao, _z = struct.unpack_from("<5I", buf, mot + rel + di * 0x14)
                is_rot = (typ & 0xFFFF) == 0x0112
                for k in range(kc):
                    ko = mot + datao + 12 * k
                    x, y, z = struct.unpack_from("<3f", buf, ko)
                    if is_rot:
                        if h == ARMATURE_HASH:
                            struct.pack_into("<3f", buf, ko, 0.0, 0.0, 0.0)
                        else:
                            struct.pack_into("<3f", buf, ko, *fix_rot3(x, y, z))
                        stats["rot_keys"] += 1
                    else:
                        if h == ROOT_HASH:
                            struct.pack_into("<3f", buf, ko, *rot_vec(x, y, z))
                            stats["trans_keys"] += 1
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(bytes(buf))
    print(f"{src.name} -> {dst}")
    print(f"   mots={stats['mots']} rest_fixed={stats['rest']} rot_keys={stats['rot_keys']} trans_keys={stats['trans_keys']}")
    # verify: armature+root now identity-ish in mot0
    mot = unique_mots(buf)[0]
    for ti in (0, 1):
        _f, h, rel = struct.unpack_from("<III", buf, mot + 0x80 + ti * 12)
        typ, kc, idxo, datao, _z = struct.unpack_from("<5I", buf, mot + rel + 0x14)
        x, y, z = struct.unpack_from("<3f", buf, mot + datao)
        print(f"   verify trk{ti} hash={h:08x} rot key0=({x:.4f},{y:.4f},{z:.4f})")


for src, dst in JOBS:
    patch(src, dst)
print("AXISFIX_OK")
