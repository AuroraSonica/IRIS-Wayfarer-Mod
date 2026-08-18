"""POLISH byte patch for the housecat AXIS-FIX motlist (2026-08-18 evening).

Field feedback (Aurora): shard-fins at the withers/chest during W3 motion
(= the v08 clavicle trap being ANIMATED by the W3 clavicle tracks), and paws
not sitting on the ground in some clips.

1. CLAVICLE NEUTRALIZE: overwrite L/R_Shoulder_Clavicle rotation keys with the
   bone's own rest quat and translation keys with its rest translation -- the
   mis-weighted verts stop being yanked. (Real fix = the v09 mesh remap, its
   own track.)
2. PAW GROUND PIN: full FK over the motlist's own bone table + tracks (key ==
   frame: every track is baked per-frame), measure the per-mot minimum world-Y
   across all Foot/Toes joints, then shift the Hip translation keys so that
   minimum sits at +1 cm. Clamped to +/-6 cm so lying poses (death, eat) can
   never be wrecked. Verified by re-running FK on the patched bytes.

In:  natives/.../iris_housecat_full_axisfix.motlist.751 (field-proven)
Out: natives/.../iris_housecat_full_polish.motlist.751 (new loose path)
"""
from __future__ import annotations

import math
import struct
from pathlib import Path

LOOSE = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\natives\stm\character\ch\iris_housecat")
SRC = LOOSE / "iris_housecat_full_axisfix.motlist.751"
DST = LOOSE / "iris_housecat_full_polish.motlist.751"

TARGET_MIN_Y = 0.010
MAX_SHIFT = 0.060

CLAVICLES = ("L_Shoulder_Clavicle", "R_Shoulder_Clavicle")
CONTACT = ("L_FrontLeg_Toes", "R_FrontLeg_Toes", "L_RearLeg_Toes", "R_RearLeg_Toes",
           "L_FrontLeg_Foot", "R_FrontLeg_Foot", "L_RearLeg_Foot", "R_RearLeg_Foot")


def mm3(text, seed=0xFFFFFFFF):
    data = text.encode("utf-16le"); h1 = seed
    c1, c2 = 0xCC9E2D51, 0x1B873593
    for i in range(0, len(data)//4*4, 4):
        k1 = int.from_bytes(data[i:i+4], "little")
        k1 = (k1*c1) & 0xFFFFFFFF; k1 = ((k1<<15)|(k1>>17)) & 0xFFFFFFFF; k1 = (k1*c2) & 0xFFFFFFFF
        h1 ^= k1; h1 = ((h1<<13)|(h1>>19)) & 0xFFFFFFFF; h1 = (h1*5+0xE6546B64) & 0xFFFFFFFF
    tail = data[len(data)//4*4:]; k1 = 0
    if len(tail) >= 3: k1 ^= tail[2] << 16
    if len(tail) >= 2: k1 ^= tail[1] << 8
    if len(tail) >= 1:
        k1 ^= tail[0]; k1 = (k1*c1) & 0xFFFFFFFF; k1 = ((k1<<15)|(k1>>17)) & 0xFFFFFFFF; k1 = (k1*c2) & 0xFFFFFFFF; h1 ^= k1
    h1 ^= len(data); h1 ^= h1 >> 16; h1 = (h1*0x85EBCA6B) & 0xFFFFFFFF
    h1 ^= h1 >> 13; h1 = (h1*0xC2B2AE35) & 0xFFFFFFFF; h1 ^= h1 >> 16
    return h1

H_CLAV = {mm3(n): n for n in CLAVICLES}
H_CONTACT = {mm3(n): n for n in CONTACT}
H_HIP = mm3("Hip")
H_GROUND = mm3("GroundAngle")


def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw,
            aw*bw - ax*bx - ay*by - az*bz)


def qrot(q, v):
    qv = (q[0], q[1], q[2])
    uv = (qv[1]*v[2]-qv[2]*v[1], qv[2]*v[0]-qv[0]*v[2], qv[0]*v[1]-qv[1]*v[0])
    uuv = (qv[1]*uv[2]-qv[2]*uv[1], qv[2]*uv[0]-qv[0]*uv[2], qv[0]*uv[1]-qv[1]*uv[0])
    return (v[0] + 2.0*(q[3]*uv[0] + uuv[0]),
            v[1] + 2.0*(q[3]*uv[1] + uuv[1]),
            v[2] + 2.0*(q[3]*uv[2] + uuv[2]))


def unique_mots(buf):
    pt = struct.unpack_from("<Q", buf, 0x10)[0]
    n = struct.unpack_from("<I", buf, 0x30)[0]
    out = []
    for i in range(n):
        m = struct.unpack_from("<Q", buf, pt + 8*i)[0]
        if m not in out:
            out.append(m)
    return out


def read_u16z(buf, off):
    out = []
    while off + 1 < len(buf):
        c = buf[off] | (buf[off+1] << 8)
        if c == 0: break
        out.append(chr(c)); off += 2
    return "".join(out)


def mot_model(buf, mot):
    """Bone table + track map for one mot."""
    tab = struct.unpack_from("<Q", buf, mot+0x10)[0]
    cnt = struct.unpack_from("<Q", buf, mot+tab+0x08)[0]
    base = tab + 0x10
    bones = []
    byhash = {}
    for k in range(cnt):
        eo = mot + base + k*0x50
        namep, parp = struct.unpack_from("<2Q", buf, eo)
        tx, ty, tz = struct.unpack_from("<3f", buf, eo+0x20)
        qx, qy, qz, qw = struct.unpack_from("<4f", buf, eo+0x30)
        h = struct.unpack_from("<I", buf, eo+0x44)[0]
        par = None
        if parp:
            rel = parp - base
            assert rel >= 0 and rel % 0x50 == 0
            par = rel // 0x50
        bones.append({"name": read_u16z(buf, mot+namep), "hash": h, "parent": par,
                      "rest_t": (tx, ty, tz), "rest_q": (qx, qy, qz, qw)})
        byhash[h] = k
    ntr = struct.unpack_from("<H", buf, mot+0x70)[0]
    tracks = {}
    for ti in range(ntr):
        to = mot + 0x80 + ti*12
        _f, h, rel = struct.unpack_from("<III", buf, to)
        descs = []
        for di in range(2):
            typ, kc, idxo, datao, _z = struct.unpack_from("<5I", buf, mot+rel+di*0x14)
            descs.append({"type": typ, "kc": kc, "data": datao,
                          "is_rot": (typ & 0xFFFF) == 0x0112})
        tracks[h] = descs
    return bones, byhash, tracks


def key3(buf, mot, desc, k):
    return struct.unpack_from("<3f", buf, mot + desc["data"] + 12*k)


def set_key3(buf, mot, desc, k, v):
    struct.pack_into("<3f", buf, mot + desc["data"] + 12*k, *v)


def quat_of(v3):
    x, y, z = v3
    w2 = 1.0 - (x*x + y*y + z*z)
    return (x, y, z, math.sqrt(w2) if w2 > 0.0 else 0.0)


def fk_min_contact(buf, mot, bones, byhash, tracks):
    """Per-frame FK; returns min world-Y over contact joints across all frames."""
    frames = min(d["kc"] for descs in tracks.values() for d in descs)
    contact_idx = [byhash[h] for h in H_CONTACT if h in byhash]
    min_y = 1e9
    for f in range(frames):
        world = {}
        for k, b in enumerate(bones):
            if b["hash"] == H_GROUND:
                continue
            descs = tracks.get(b["hash"])
            if descs:
                lt = key3(buf, mot, descs[0], min(f, descs[0]["kc"]-1))
                lq = quat_of(key3(buf, mot, descs[1], min(f, descs[1]["kc"]-1)))
            else:
                lt, lq = b["rest_t"], b["rest_q"]
            p = b["parent"]
            if p is None or p not in world:
                world[k] = (lt, lq)
            else:
                pt, pq = world[p]
                wt = tuple(pt[i] + v for i, v in enumerate(qrot(pq, lt)))
                world[k] = (wt, qmul(pq, lq))
        for ci in contact_idx:
            if ci in world:
                y = world[ci][0][1]
                if y < min_y:
                    min_y = y
    return min_y, frames


buf = bytearray(SRC.read_bytes())
mots = unique_mots(buf)
print(f"{SRC.name}: {len(mots)} mots")

report = []
for mi, mot in enumerate(mots):
    bones, byhash, tracks = mot_model(buf, mot)
    # ---- 1. clavicle neutralize ----
    for h, nm in H_CLAV.items():
        descs = tracks.get(h)
        bi = byhash.get(h)
        if not descs or bi is None:
            continue
        rt = bones[bi]["rest_t"]
        rq = bones[bi]["rest_q"]
        if rq[3] < 0.0:
            rq = tuple(-c for c in rq)
        for d in descs:
            val = (rq[0], rq[1], rq[2]) if d["is_rot"] else rt
            for k in range(d["kc"]):
                set_key3(buf, mot, d, k, val)
    # ---- 2. paw ground pin ----
    min_y, frames = fk_min_contact(buf, mot, bones, byhash, tracks)
    delta = TARGET_MIN_Y - min_y
    delta = max(-MAX_SHIFT, min(MAX_SHIFT, delta))
    if abs(delta) > 0.004:
        hd = tracks.get(H_HIP)
        if hd:
            d0 = hd[0]           # translation descriptor
            for k in range(d0["kc"]):
                x, y, z = key3(buf, mot, d0, k)
                set_key3(buf, mot, d0, k, (x, y + delta, z))
    v_min, _ = fk_min_contact(buf, mot, bones, byhash, tracks)
    report.append((mi, frames, min_y, delta, v_min))
    print(f"  mot{mi:02d} frames={frames:4d} paw_minY={min_y:+.3f} shift={delta:+.3f} -> now {v_min:+.3f}")

DST.write_bytes(bytes(buf))
print(f"\nwrote {DST} ({DST.stat().st_size:,} B)")
print("POLISH_OK")
