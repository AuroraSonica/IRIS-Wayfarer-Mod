import sys, os
ADDON = r"C:\Users\Krist\AppData\Roaming\Blender Foundation\Blender\4.3\scripts\addons\RE-Mesh-Editor-main"
sys.path.insert(0, ADDON)
import bpy
bpy.ops.preferences.addon_enable(module="RE-Mesh-Editor-main")
from modules.tex.file_re_tex import Tex

for base in (r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\character\ch\ch23_001",
             r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\DD2_EXTRACT\re_chunk_000\natives\STM\streaming\Character\ch\ch23_001"):
    print(f"\n=== {'STREAMING' if 'streaming' in base.lower() else 'BASE'} ===")
    for fn in sorted(os.listdir(base)):
        if "eye" not in fn.lower() and "body_ALBD" not in fn:
            continue
        p = os.path.join(base, fn)
        f = open(p, "rb")
        t = Tex()
        t.header.read(f)
        f.close()
        h = t.header
        print(f"   {fn:<46} {h.width}x{h.height} fmt={h.format} mips={h.mipCount} "
              f"size={os.path.getsize(p)}")
