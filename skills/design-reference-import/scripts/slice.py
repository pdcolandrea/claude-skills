#!/usr/bin/env python3
"""Slice tall reference PNGs into per-section crops using PIL.

Reads <folder>/design.json and writes <folder>/sections/{desktop,mobile}/<NN>-<id>.png.
Top-left anchored crop semantics (unlike `sips --cropOffset`, which is centered).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.stderr.write(
        "PIL/Pillow is required. Install with: pip3 install --user Pillow\n"
    )
    sys.exit(1)


def slice_design(design_dir: Path) -> int:
    manifest_path = design_dir / "design.json"
    if not manifest_path.exists():
        sys.stderr.write(f"design.json not found at {manifest_path}\n")
        return 1

    manifest = json.loads(manifest_path.read_text())
    sources = manifest.get("sources") or {}
    sections = manifest.get("sections") or []

    if not sections:
        sys.stderr.write("No sections defined in manifest.\n")
        return 1

    for variant in ("desktop", "mobile"):
        src = sources.get(variant)
        if not src:
            print(f"(skipping {variant} — no source defined)")
            continue

        src_path = design_dir / src["image"]
        if not src_path.exists():
            sys.stderr.write(f"source image missing: {src_path}\n")
            return 1

        out_dir = design_dir / "sections" / variant
        out_dir.mkdir(parents=True, exist_ok=True)

        with Image.open(src_path) as img:
            png_w, png_h = img.size
            for idx, section in enumerate(sections):
                region = section.get(variant)
                if not region:
                    continue
                n = f"{idx + 1:02d}"
                out_path = out_dir / f"{n}-{section['id']}.png"

                y = max(0, int(region["y"]))
                height = max(0, min(int(region["height"]), png_h - y))
                if height == 0:
                    print(f"  ({variant}/{n}-{section['id']} — height 0, skipped)")
                    continue

                crop = img.crop((0, y, png_w, y + height))
                crop.save(out_path)
                print(f"  {variant}/{n}-{section['id']}.png  ({png_w}×{height} @ y={y})")

    print("\ndone.")
    return 0


def main() -> int:
    design_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    return slice_design(design_dir)


if __name__ == "__main__":
    sys.exit(main())
