#!/usr/bin/env python3
"""Frame native captures for the README. Requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/media'
RAW = ROOT / '.codex-qa/readme-refresh'


def background(size, dark=False):
    top, bottom = ((32, 38, 48), (15, 19, 27)) if dark else ((241, 244, 249), (224, 232, 241))
    image = Image.new('RGB', size)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        draw.line((0, y, size[0], y), fill=color)
    return image.convert('RGBA')


for source in sorted(RAW.glob('*-*.png')):
    image = Image.open(source).convert('RGBA')
    padding = 96
    canvas = background((image.width + padding * 2, image.height + padding * 2), source.stem.endswith('dark'))
    shadow = Image.new('RGBA', canvas.size)
    shadow.putalpha(Image.new('L', canvas.size))
    mask = Image.new('L', canvas.size)
    mask.paste(image.getchannel('A'), (padding, padding + 18))
    shadow.putalpha(mask.point(lambda a: round(a * .22)).filter(ImageFilter.GaussianBlur(25)))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(image, (padding, padding))
    canvas.convert('RGB').save(OUT / source.name, optimize=True)

print('Finished 10 framed screenshots.')
