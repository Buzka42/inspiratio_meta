#!/usr/bin/env python3
"""Download the NASA SVS CGI Moon Kit colour maps and build the bundled moon assets.

Outputs (in client/assets/moon/):
  default.jpg              4096x2048 equirectangular colour map, JPEG q90
  tiles/L0_{x}_{y}.jpg     8192x4096 map cut into 512x512 JPEG q90 tiles
  manifest.json            levels, tile size, dimensions, file names, credit

Also writes moon_assets/manifest.json (source URLs, byte sizes, sha256).
Needs: curl and vips (libvips CLI). Run: python3 -I moon_assets/build_moon_assets.py
"""
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "raw"
WORK = HERE / "work"
OUT = HERE.parent / "client" / "assets" / "moon"
BASE = "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/"
CREDIT = ("Image credit: NASA's Scientific Visualization Studio, "
          "CGI Moon Kit (svs.gsfc.nasa.gov/4720)")
QUALITY = 90
TILE = 512
# Sizes in bytes from the server's Content-Length (page lists 59.0 MB / 232.0 MB).
SOURCES = {
    "4k": ("lroc_color_16bit_srgb_4k.tif", 61891324, (4096, 2048)),
    "8k": ("lroc_color_16bit_srgb_8k.tif", 243289792, (8192, 4096)),
}


def run(*cmd):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run([str(c) for c in cmd], check=True)


def vips_out(*cmd):
    return subprocess.run(["vipsheader", *map(str, cmd)], check=True,
                          capture_output=True, text=True).stdout.strip()


def download(name, size):
    dest = RAW / name
    if dest.exists() and dest.stat().st_size == size:
        print(f"have {name} ({size} bytes)")
        return dest
    # -C - resumes a partial file; --fail stops on HTTP errors.
    run("curl", "--fail", "-L", "-C", "-", "-o", dest, BASE + name)
    got = dest.stat().st_size
    if got != size:
        sys.exit(f"ERROR: {name} is {got} bytes, expected {size}")
    return dest


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def to_srgb8(src, dest, dims):
    """16-bit sRGB TIFF -> 8-bit sRGB vips image (values scaled, not clipped)."""
    w, h = (int(vips_out("-f", f, src)) for f in ("width", "height"))
    if (w, h) != dims:
        sys.exit(f"ERROR: {src.name} is {w}x{h}, expected {dims[0]}x{dims[1]}")
    run("vips", "colourspace", src, dest, "srgb")


def main():
    for d in (RAW, WORK, OUT / "tiles"):
        d.mkdir(parents=True, exist_ok=True)
    for old in (OUT / "tiles").glob("*.jpg"):
        old.unlink()

    raw = {k: download(n, s) for k, (n, s, _) in SOURCES.items()}

    # Default map.
    v4 = WORK / "moon4k.v"
    to_srgb8(raw["4k"], v4, SOURCES["4k"][2])
    run("vips", "jpegsave", v4, OUT / "default.jpg", f"--Q={QUALITY}",
        "--keep=none", "--optimize-coding")

    # Level 0 tiles from the 8k map at full size. No deeper level: the 16k and
    # 27k sources are not shipped, and upsampling 8k would only add bytes.
    v8 = WORK / "moon8k.v"
    w, h = SOURCES["8k"][2]
    to_srgb8(raw["8k"], v8, (w, h))
    cols, rows = w // TILE, h // TILE
    tiles = []
    for y in range(rows):
        for x in range(cols):
            name = f"L0_{x}_{y}.jpg"
            run("vips", "crop", v8, f"{OUT / 'tiles' / name}[Q={QUALITY},keep=none,optimize-coding]",
                x * TILE, y * TILE, TILE, TILE)
            tiles.append(name)

    manifest = {
        "projection": "equirectangular",
        "centre_longitude_deg": 0,
        "credit": CREDIT,
        "jpeg_quality": QUALITY,
        "default": {"file": "default.jpg", "width": 4096, "height": 2048},
        "tile_size": TILE,
        "levels": [{
            "level": 0, "width": w, "height": h, "columns": cols, "rows": rows,
            "pattern": "tiles/L{level}_{x}_{y}.jpg",
            "files": [f"tiles/{t}" for t in tiles],
        }],
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    source_record = {
        "page": "https://svs.gsfc.nasa.gov/4720",
        "credit": CREDIT,
        "sources": [{"file": n, "url": BASE + n, "bytes": s,
                     "width": d[0], "height": d[1], "sha256": sha256(raw[k])}
                    for k, (n, s, d) in SOURCES.items()],
    }
    (HERE / "manifest.json").write_text(json.dumps(source_record, indent=2) + "\n")
    shutil.rmtree(WORK)
    print(f"done: default.jpg + {len(tiles)} tiles in {OUT}")


if __name__ == "__main__":
    main()
