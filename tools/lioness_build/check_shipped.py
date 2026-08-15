"""Did I ship the TAWNY coat as ch23_001 and the CHARCOAL as ch23_002, or did I cross them?

Aurora reports force-PUMA producing a black cat. The puma resolves ch23_001 through the
untouched vanilla mdf2, so a black puma is only possible if the ch23_001 albedo I shipped
is the charcoal one. Decode both and measure. No inference -- read the texels.
"""
import sys, os
import numpy as np
ADDON = r"C:\Users\Krist\AppData\Roaming\Blender Foundation\Blender\4.3\scripts\addons\RE-Mesh-Editor-main"
sys.path.insert(0, ADDON)
import bpy
bpy.ops.preferences.addon_enable(module="RE-Mesh-Editor-main")
from modules.tex.file_re_tex import Tex

STAGE = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework\rs_tools\lioness_build\stage_all\natives\stm\character\ch"
VAN = r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001"

for label, path in (
        ("VANILLA  ch23_001_body_ALBD", os.path.join(VAN, "ch23_001_body_ALBD.tex.760230703")),
        ("SHIPPED  ch23_001_body_ALBD", os.path.join(STAGE, "ch23_001", "ch23_001_body_ALBD.tex.760230703")),
        ("SHIPPED  ch23_002_body_ALBD", os.path.join(STAGE, "ch23_002", "ch23_002_body_ALBD.tex.760230703")),
        ("SHIPPED  ch23_001_eye_ALBE", os.path.join(STAGE, "ch23_001", "ch23_001_eye_ALBE.tex.760230703")),
        ("SHIPPED  ch23_002_eye_ALBE", os.path.join(STAGE, "ch23_002", "ch23_002_eye_ALBE.tex.760230703")),
):
    if not os.path.exists(path):
        print(f"{label:<32} MISSING {path}")
        continue
    # decode mip0 by asking the library, then look at the raw BC block colours cheaply:
    # for BC1/BC7 the average of the endpoint colours tracks overall brightness well enough
    # to tell tawny (mean ~0.6) from charcoal (mean ~0.08) beyond any doubt.
    d = open(path, "rb").read()
    f = open(path, "rb"); t = Tex(); t.header.read(f); f.close()
    h = t.header
    import struct
    off = struct.unpack_from("<Q", d, 0)[0]
    # mip table starts right after the header; entry 0 holds mip0's offset
    # (re-read exactly the way the splice does)
    f = open(path, "rb"); t2 = Tex(); t2.header.read(f); tbl = f.tell(); f.close()
    mip0 = struct.unpack_from("<Q", d, tbl)[0]
    usize = struct.unpack_from("<I", d, tbl + 12)[0]
    blob = d[mip0:mip0 + usize]
    if h.format in (71, 72):        # BC1: 8 bytes/block, 2 RGB565 endpoints
        n = len(blob) // 8
        c0 = np.frombuffer(blob, dtype='<u2')[0::4][:n].astype(np.float32)
        c1 = np.frombuffer(blob, dtype='<u2')[1::4][:n].astype(np.float32)
        def rgb(c):
            r = np.floor(c / 2048) * 8
            g = np.floor((c % 2048) / 32) * 4
            b = (c % 32) * 8
            return np.stack([r, g, b], -1) / 255.0
        px = (rgb(c0) + rgb(c1)) * 0.5
        print(f"{label:<32} {h.width}x{h.height} fmt={h.format}  "
              f"mean RGB={px.mean(0).round(4)}  luma={px.mean():.4f}")
    else:
        print(f"{label:<32} {h.width}x{h.height} fmt={h.format}  (BC7, endpoints not "
              f"decoded here) bytes={len(blob)}")
