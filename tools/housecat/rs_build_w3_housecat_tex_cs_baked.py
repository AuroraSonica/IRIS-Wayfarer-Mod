"""Rebuild the DD2 house-cat textures from the W3 CUTSCENE maps at 2048px.

08-19, Aurora: the tabby fur "looks pretty low res".  Root cause: the v07
material build's docstring said it used the close-up maps, but SOURCE_ALBEDO/
SOURCE_NORMAL actually pointed at the 512px GAMEPLAY pair, upscaled to 1024.
The 2048px cutscene pair (t_01__cat_cs_d01/n01.dds) shares the cat UV layout
and was never wired in.

This script builds ONLY the two textures (no MDF -- the proven v07 mdf2 stays
byte-untouched per the mdf2 patch law) and writes them under the SAME relative
paths the mdf2 already references, so deploying them LOOSE overrides the v08
pak copies with zero other changes.  Run with Blender 4.5 --background.
"""

from pathlib import Path
import ctypes
import json
import shutil
import subprocess
import sys

import bpy
import numpy as np


ROOT = Path(r"D:\SteamLibrary\steamapps\common\Dragons Dogma 2\reframework")
RS = ROOT / "rs_tools"
ADDON = ROOT.parent / "RE-Mesh-Editor-main"
FFMPEG = Path(r"C:\ffmpeg\bin\ffmpeg.exe")
SOURCE = RS / "witcher 3 files" / "cat"
BUILD = RS / "w3_housecat_material_build_cs_baked"
STAGE = RS / "w3_housecat_tex_cs_baked" / "natives" / "stm"
REPORT = RS / "w3_housecat_tex_cs_baked_report.json"
SOURCE_ALBEDO = RS / "w3_housecat_material_build_cs2" / "baked_ALBD_2048.png"  # UV-rebaked
SOURCE_NORMAL = RS / "w3_housecat_material_build_cs2" / "baked_NRMR_2048.png"  # UV-rebaked

DD2_TEX_VERSION = 760230703
SIZE = 2048
ROUGHNESS = 205.0 / 255.0

ctypes.windll.ole32.CoInitializeEx(None, 2)
sys.path.insert(0, str(ADDON))
from modules.ddsconv.directx.texconv import Texconv  # noqa: E402
from modules.ddsconv.directx.dds import DDS, DDS_CAPS, DDS_FLAGS  # noqa: E402
from modules.tex.re_tex_utils import DDSToTex  # noqa: E402


BUILD.mkdir(parents=True, exist_ok=True)


def load_raw(path: Path) -> np.ndarray:
    decoded = BUILD / ("decoded_" + path.stem + ".png")
    subprocess.run(
        [
            str(FFMPEG), "-loglevel", "error", "-y", "-i", str(path),
            "-frames:v", "1", "-update", "1", str(decoded),
        ],
        check=True,
    )
    image = bpy.data.images.load(str(decoded), check_existing=False)
    image.colorspace_settings.name = "Non-Color"
    image.scale(SIZE, SIZE)
    pixels = np.empty(SIZE * SIZE * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    bpy.data.images.remove(image)
    return pixels.reshape(SIZE, SIZE, 4)


def write_png(array: np.ndarray, path: Path) -> Path:
    image = bpy.data.images.new(path.stem, width=SIZE, height=SIZE, alpha=True)
    image.colorspace_settings.name = "Non-Color"
    image.alpha_mode = "CHANNEL_PACKED"
    image.pixels.foreach_set(np.ascontiguousarray(array, dtype=np.float32).ravel())
    image.filepath_raw = str(path)
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)
    return path


def build_tex(png: Path, fmt: str, relative_paths: list[str]) -> list[dict]:
    mip_dir = BUILD / ("mips_" + png.stem)
    dds_dir = BUILD / ("dds_" + png.stem)
    mip_dir.mkdir(parents=True, exist_ok=True)
    if dds_dir.exists():
        shutil.rmtree(dds_dir)
    dds_dir.mkdir(parents=True)

    converter = Texconv()
    levels = []
    size = SIZE
    while size >= 1:
        tga = mip_dir / f"m_{size}.tga"
        subprocess.run(
            [
                str(FFMPEG), "-loglevel", "error", "-y", "-i", str(png),
                "-vf", f"scale={size}:{size}:flags=lanczos",
                "-frames:v", "1", "-update", "1", "-pix_fmt", "bgra", str(tga),
            ],
            check=True,
        )
        dds_path = converter.convert_to_dds(
            file=str(tga), dds_fmt=fmt, out=str(dds_dir), no_mip=True,
            verbose=False, allow_slow_codec=True,
        )
        levels.append(DDS.load(str(dds_path)))
        size //= 2

    header = levels[0].header
    header.mipmap_num = len(levels)
    header.flags = int(header.flags) | int(DDS_FLAGS.MIPMAPCOUNT)
    header.caps = int(header.caps) | int(DDS_CAPS.MIPMAP)
    assembled = BUILD / (png.stem + ".dds")
    DDS(header, [b"".join(level.slice_bin_list[0] for level in levels)]).save(str(assembled))

    written = []
    first = None
    for relative in relative_paths:
        destination = STAGE / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if first is None:
            DDSToTex([str(assembled)], DD2_TEX_VERSION, str(destination), streamingFlag=False)
            first = destination
        else:
            shutil.copyfile(first, destination)
        written.append({"path": str(destination), "size": destination.stat().st_size})
    return written


albedo = load_raw(SOURCE_ALBEDO)
albedo[..., 3] = 1.0
albedo_png = write_png(albedo, BUILD / "housecat_ALBD.png")

source_normal = load_raw(SOURCE_NORMAL)
nrmr = np.empty_like(source_normal)
nrmr[..., 0] = source_normal[..., 0]
nrmr[..., 1] = source_normal[..., 1]
nrmr[..., 2] = 1.0
nrmr[..., 3] = ROUGHNESS
nrmr_png = write_png(nrmr, BUILD / "housecat_NRMR.png")

texture_outputs = []
texture_outputs += build_tex(
    albedo_png,
    "BC1_UNORM_SRGB",
    [
        rf"riftspeak\housecat\housecat_v07_ALBD.tex.{DD2_TEX_VERSION}",
        rf"streaming\riftspeak\housecat\housecat_v07_ALBD.tex.{DD2_TEX_VERSION}",
    ],
)
texture_outputs += build_tex(
    nrmr_png,
    "BC7_UNORM",
    [
        rf"riftspeak\housecat\housecat_v07_NRMR.tex.{DD2_TEX_VERSION}",
        rf"streaming\riftspeak\housecat\housecat_v07_NRMR.tex.{DD2_TEX_VERSION}",
    ],
)

report = {
    "format": "iris-w3-housecat-tex-cutscene-v1",
    "source_albedo": str(SOURCE_ALBEDO),
    "source_normal": str(SOURCE_NORMAL),
    "resolution": SIZE,
    "roughness": ROUGHNESS,
    "textures": texture_outputs,
}
REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("W3_HOUSECAT_TEX_CS_OK", REPORT)
