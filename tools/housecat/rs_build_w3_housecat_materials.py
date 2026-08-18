"""Build DD2 house-cat textures and a matching one-body material package.

Run with Blender 4.3. The Witcher close-up maps are used because they share
the cat UV layout at 2048px, versus the 512/256px gameplay pair.
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
BUILD = RS / "w3_housecat_material_build"
STAGE = RS / "w3_housecat_pak_v07" / "natives" / "stm"
DONOR_MDF = RS / r"horse2_pak\natives\stm\character\ch\ch99_011\horse2.mdf2.40"
OUTPUT_MDF = STAGE / r"riftspeak\housecat\iris_housecat_v07.mdf2.40"
REPORT = RS / "w3_housecat_material_build_report.json"
SOURCE_ALBEDO = SOURCE / "t_01__cat_d01.dds"
SOURCE_NORMAL = SOURCE / "t_01__cat_n01.dds"

DD2_TEX_VERSION = 760230703
SIZE = 1024
ROUGHNESS = 205.0 / 255.0
TEX_ROOT = "RiftSpeak/HouseCat/"

ctypes.windll.ole32.CoInitializeEx(None, 2)
sys.path.insert(0, str(ADDON))
from modules.ddsconv.directx.texconv import Texconv  # noqa: E402
from modules.ddsconv.directx.dds import DDS, DDS_CAPS, DDS_FLAGS  # noqa: E402
from modules.tex.re_tex_utils import DDSToTex  # noqa: E402
from modules.mdf.file_re_mdf import readMDF, writeMDF  # noqa: E402


BUILD.mkdir(parents=True, exist_ok=True)


def load_raw(path: Path) -> np.ndarray:
    # Blender's DDS loader reports the 512/256 gameplay maps as having no image
    # data even though ffmpeg decodes them correctly. Normalise through PNG
    # first; this also makes the chosen gameplay-vs-cutscene source explicit.
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

mdf = readMDF(str(DONOR_MDF))
body = next(material for material in mdf.materialList if material.materialName == "body_mat")
# The exported cat has exactly one submesh/material. RE Engine expects the MDF
# table to honour that contract; retaining the horse's eye/oral/VFX entries made
# set_Material report success while the one-slot cat rendered invisible.
mdf.materialList = [body]
for binding in body.textureList:
    if binding.textureType == "BaseDielectricMap":
        binding.texturePath = TEX_ROOT + "housecat_v07_ALBD.tex"
    elif binding.textureType == "NormalRoughnessMap":
        binding.texturePath = TEX_ROOT + "housecat_v07_NRMR.tex"
    elif binding.textureType == "AlphaTranslucentOcclusionCavityMap":
        binding.texturePath = "systems/rendering/NullWhite.tex"
    elif binding.textureType in {"EnemyMaskMap", "EnemyVfxMap"}:
        binding.texturePath = "systems/rendering/NullBlack.tex"

OUTPUT_MDF.parent.mkdir(parents=True, exist_ok=True)
writeMDF(mdf, str(OUTPUT_MDF))
check = readMDF(str(OUTPUT_MDF))
if len(check.materialList) != 1:
    raise RuntimeError(f"House-cat MDF contract is not one material: {len(check.materialList)}")
check_body = next(material for material in check.materialList if material.materialName == "body_mat")

report = {
    "format": "iris-w3-housecat-material-v1",
    "source_albedo": str(SOURCE_ALBEDO),
    "source_normal": str(SOURCE_NORMAL),
    "resolution": SIZE,
    "roughness": ROUGHNESS,
    "material": check_body.materialName,
    "material_count": len(check.materialList),
    "shader": check_body.mmtrPath,
    "mdf": {"path": str(OUTPUT_MDF), "size": OUTPUT_MDF.stat().st_size},
    "textures": texture_outputs,
    "preview": str(albedo_png),
}
REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("W3_HOUSECAT_MATERIALS_OK", REPORT)
