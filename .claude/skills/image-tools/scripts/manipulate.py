#!/usr/bin/env python3
"""Deterministic image manipulation CLI built on Pillow.

Covers the common, non-generative edits: resize, crop, rotate, flip, format
conversion, color/brightness/contrast adjustment, grayscale, blur, sharpen,
text watermark, and overlay/composite. Describing image *contents* is handled
by the Read tool, not this script (see SKILL.md).
"""

import argparse
import os
import sys


def _require_pillow():
    try:
        import PIL  # noqa: F401
    except ImportError:
        sys.exit(
            "Pillow is not installed. Install it with:\n"
            "    python3 -m pip install Pillow"
        )


def _default_output(input_path, command, ext=None):
    """Build an output path next to the input, suffixed with the command."""
    root, original_ext = os.path.splitext(input_path)
    return f"{root}_{command}{ext or original_ext}"


def _open(path):
    from PIL import Image

    if not os.path.exists(path):
        sys.exit(f"Input image not found: {path}")
    return Image.open(path)


def _save(img, path):
    # JPEG can't hold an alpha channel; flatten if needed.
    ext = os.path.splitext(path)[1].lower()
    if ext in (".jpg", ".jpeg") and img.mode in ("RGBA", "P", "LA"):
        img = img.convert("RGB")
    img.save(path)
    print(f"Wrote {path} ({img.width}x{img.height}, {img.mode})")


def _parse_pair(value, name, sep="x"):
    try:
        a, b = value.lower().split(sep)
        return int(a), int(b)
    except (ValueError, AttributeError):
        sys.exit(f"--{name} must look like A{sep}B, got: {value}")


# --- commands ---------------------------------------------------------------


def cmd_info(args):
    img = _open(args.input)
    print(f"path:   {args.input}")
    print(f"format: {img.format}")
    print(f"mode:   {img.mode}")
    print(f"size:   {img.width}x{img.height}")
    exif = getattr(img, "_getexif", lambda: None)()
    if exif:
        from PIL.ExifTags import TAGS

        print("exif:")
        for tag_id, value in exif.items():
            tag = TAGS.get(tag_id, tag_id)
            print(f"  {tag}: {value}")


def cmd_resize(args):
    from PIL import Image

    img = _open(args.input)
    w, h = _parse_pair(args.size, "size")
    if args.keep_aspect:
        img.thumbnail((w, h), Image.LANCZOS)
    else:
        img = img.resize((w, h), Image.LANCZOS)
    _save(img, args.output or _default_output(args.input, "resize"))


def cmd_thumbnail(args):
    from PIL import Image

    img = _open(args.input)
    img.thumbnail((args.max, args.max), Image.LANCZOS)
    _save(img, args.output or _default_output(args.input, "thumb"))


def cmd_crop(args):
    img = _open(args.input)
    try:
        box = tuple(int(x) for x in args.box.split(","))
        assert len(box) == 4
    except (ValueError, AssertionError):
        sys.exit("--box must be left,top,right,bottom (4 ints)")
    _save(img.crop(box), args.output or _default_output(args.input, "crop"))


def cmd_rotate(args):
    img = _open(args.input)
    out = img.rotate(args.degrees, expand=True)
    _save(out, args.output or _default_output(args.input, "rotate"))


def cmd_flip(args):
    from PIL import Image

    img = _open(args.input)
    if args.direction == "horizontal":
        out = img.transpose(Image.FLIP_LEFT_RIGHT)
    else:
        out = img.transpose(Image.FLIP_TOP_BOTTOM)
    _save(out, args.output or _default_output(args.input, "flip"))


def cmd_convert(args):
    img = _open(args.input)
    if not args.output:
        sys.exit("convert requires an output path with the target extension")
    _save(img, args.output)


def cmd_grayscale(args):
    img = _open(args.input).convert("L")
    _save(img, args.output or _default_output(args.input, "gray"))


def _enhance(args, enhancer_name, suffix):
    from PIL import ImageEnhance

    img = _open(args.input)
    if img.mode not in ("RGB", "RGBA", "L"):
        img = img.convert("RGB")
    enhancer = getattr(ImageEnhance, enhancer_name)(img)
    out = enhancer.enhance(args.factor)
    _save(out, args.output or _default_output(args.input, suffix))


def cmd_brightness(args):
    _enhance(args, "Brightness", "bright")


def cmd_contrast(args):
    _enhance(args, "Contrast", "contrast")


def cmd_color(args):
    _enhance(args, "Color", "color")


def cmd_blur(args):
    from PIL import ImageFilter

    img = _open(args.input)
    out = img.filter(ImageFilter.GaussianBlur(radius=args.radius))
    _save(out, args.output or _default_output(args.input, "blur"))


def cmd_sharpen(args):
    from PIL import ImageFilter

    img = _open(args.input)
    out = img.filter(ImageFilter.SHARPEN)
    _save(out, args.output or _default_output(args.input, "sharpen"))


def cmd_watermark(args):
    from PIL import Image, ImageDraw, ImageFont

    img = _open(args.input).convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    size = args.font_size or max(16, img.width // 20)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", size)
    except OSError:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), args.text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    margin = max(10, img.width // 50)
    positions = {
        "tl": (margin, margin),
        "tr": (img.width - tw - margin, margin),
        "bl": (margin, img.height - th - margin),
        "br": (img.width - tw - margin, img.height - th - margin),
        "center": ((img.width - tw) // 2, (img.height - th) // 2),
    }
    xy = positions.get(args.position, positions["br"])
    alpha = int(255 * args.opacity)
    draw.text(xy, args.text, font=font, fill=(255, 255, 255, alpha))
    out = Image.alpha_composite(img, overlay)
    _save(out, args.output or _default_output(args.input, "watermark"))


def cmd_overlay(args):
    img = _open(args.input).convert("RGBA")
    top = _open(args.top).convert("RGBA")
    x, y = _parse_pair(args.xy, "xy", sep=",")
    if args.opacity < 1.0:
        alpha = top.split()[3].point(lambda p: int(p * args.opacity))
        top.putalpha(alpha)
    img.alpha_composite(top, dest=(x, y))
    _save(img, args.output or _default_output(args.input, "overlay"))


# --- arg parsing ------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(description="Deterministic image manipulation (Pillow).")
    sub = p.add_subparsers(dest="command", required=True)

    def add_io(sp, with_output=True):
        sp.add_argument("input", help="input image path")
        if with_output:
            sp.add_argument("output", nargs="?", help="output path (optional)")

    s = sub.add_parser("info", help="print metadata")
    s.add_argument("input")
    s.set_defaults(func=cmd_info)

    s = sub.add_parser("resize", help="resize to WxH")
    add_io(s)
    s.add_argument("--size", required=True, help="WxH, e.g. 800x600")
    s.add_argument("--keep-aspect", action="store_true", help="fit within box")
    s.set_defaults(func=cmd_resize)

    s = sub.add_parser("thumbnail", help="thumbnail capped at max edge")
    add_io(s)
    s.add_argument("--max", type=int, default=256)
    s.set_defaults(func=cmd_thumbnail)

    s = sub.add_parser("crop", help="crop a box")
    add_io(s)
    s.add_argument("--box", required=True, help="left,top,right,bottom")
    s.set_defaults(func=cmd_crop)

    s = sub.add_parser("rotate", help="rotate by degrees")
    add_io(s)
    s.add_argument("--degrees", type=float, required=True)
    s.set_defaults(func=cmd_rotate)

    s = sub.add_parser("flip", help="flip image")
    add_io(s)
    s.add_argument("--direction", choices=["horizontal", "vertical"], required=True)
    s.set_defaults(func=cmd_flip)

    s = sub.add_parser("convert", help="convert format by output extension")
    add_io(s)
    s.set_defaults(func=cmd_convert)

    s = sub.add_parser("grayscale", help="convert to grayscale")
    add_io(s)
    s.set_defaults(func=cmd_grayscale)

    for name, fn in [("brightness", cmd_brightness), ("contrast", cmd_contrast), ("color", cmd_color)]:
        s = sub.add_parser(name, help=f"adjust {name} (1.0 = no change)")
        add_io(s)
        s.add_argument("--factor", type=float, required=True)
        s.set_defaults(func=fn)

    s = sub.add_parser("blur", help="gaussian blur")
    add_io(s)
    s.add_argument("--radius", type=float, default=2.0)
    s.set_defaults(func=cmd_blur)

    s = sub.add_parser("sharpen", help="sharpen")
    add_io(s)
    s.set_defaults(func=cmd_sharpen)

    s = sub.add_parser("watermark", help="draw text watermark")
    add_io(s)
    s.add_argument("--text", required=True)
    s.add_argument("--position", choices=["tl", "tr", "bl", "br", "center"], default="br")
    s.add_argument("--opacity", type=float, default=0.6)
    s.add_argument("--font-size", type=int, default=0)
    s.set_defaults(func=cmd_watermark)

    s = sub.add_parser("overlay", help="composite a second image on top")
    s.add_argument("input", help="base image path")
    s.add_argument("top", help="image to place on top")
    s.add_argument("--xy", default="0,0", help="x,y placement")
    s.add_argument("--opacity", type=float, default=1.0)
    s.add_argument("--output", "-o", help="output path (optional)")
    s.set_defaults(func=cmd_overlay)

    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    _require_pillow()
    args.func(args)


if __name__ == "__main__":
    main()
