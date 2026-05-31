---
name: image-tools
description: View, describe, and edit/manipulate images. Use when the user wants to look at or describe the contents of an image (PNG, JPG, JPEG, GIF, WEBP, BMP, TIFF), OR transform one — resize, crop, rotate, flip, convert format, adjust brightness/contrast/color, grayscale, blur, sharpen, add a text watermark, composite/overlay images, or generate thumbnails.
---

# Image Tools

This skill does two things: **describe** what's in an image, and **edit/manipulate** images.

## 1. Viewing & describing images

To describe an image, **read it directly with the Read tool** — it renders the
image visually and you can describe its contents, read text in it, identify
objects, colors, layout, etc. No script is needed for this.

```
Read(file_path="/abs/path/to/image.png")
```

Then answer the user's question about the image (what it shows, OCR-style text
extraction, dominant colors, composition, etc.).

If you only need quick objective metadata (dimensions, format, mode, EXIF)
without "looking," use:

```
python3 scripts/manipulate.py info /abs/path/to/image.png
```

## 2. Editing & manipulating images

All manipulation goes through `scripts/manipulate.py`, a Pillow-based CLI.

**Setup (run once if Pillow is missing):**

```bash
python3 -m pip install --quiet Pillow
```

The script also prints a clear hint to run this if the import fails.

**General form:**

```bash
python3 scripts/manipulate.py <command> <input> [output] [options]
```

If `output` is omitted, the script writes `<input>_<command>.<ext>` next to the
input so the original is never overwritten unless the user passes the same path.

### Available commands

| Command | What it does | Example |
|---|---|---|
| `info` | Print dimensions, format, mode, EXIF | `info in.jpg` |
| `resize` | Resize to WxH (use `--keep-aspect` to fit within box) | `resize in.png out.png --size 800x600 --keep-aspect` |
| `thumbnail` | Make a thumbnail capped at a max edge | `thumbnail in.jpg --max 256` |
| `crop` | Crop a box `left,top,right,bottom` | `crop in.png --box 10,10,210,210` |
| `rotate` | Rotate by degrees (expands canvas) | `rotate in.jpg --degrees 90` |
| `flip` | Flip `horizontal` or `vertical` | `flip in.png --direction horizontal` |
| `convert` | Convert format (by output extension) | `convert in.png out.webp` |
| `grayscale` | Convert to grayscale | `grayscale in.jpg` |
| `brightness` | Scale brightness (1.0 = no change) | `brightness in.jpg --factor 1.3` |
| `contrast` | Scale contrast | `contrast in.jpg --factor 1.2` |
| `color` | Scale color saturation | `color in.jpg --factor 0.5` |
| `blur` | Gaussian blur | `blur in.png --radius 3` |
| `sharpen` | Sharpen | `sharpen in.png` |
| `watermark` | Draw text watermark | `watermark in.jpg --text "© 2026" --position br` |
| `overlay` | Composite a second image on top at x,y | `overlay base.png logo.png --xy 20,20 --opacity 0.8` |

Run `python3 scripts/manipulate.py --help` or `<command> --help` for full flags.

### Workflow guidance

- Always use absolute paths or paths relative to the user's working directory.
- After producing an output file, tell the user the output path. If it would
  help them confirm the result, `Read` the output image and describe it.
- Don't overwrite the original unless the user explicitly asks; rely on the
  auto-suffixed output name otherwise.
- For multi-step edits (e.g. "resize then grayscale"), chain commands, feeding
  each output into the next.

## Scope / limitations

This skill does NOT do generative image work: no inpainting, outpainting,
object removal, style transfer, or text-to-image generation. It is limited to
deterministic, pixel-level transforms via Pillow plus visual description via the
Read tool. If the user asks for generative edits, say so plainly and offer the
closest deterministic alternative (e.g. crop/overlay instead of "remove object").
