#!/usr/bin/env python3
"""Export docs/media/hero.gif: every default character walking through the main states. Requires Pillow."""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FRAMES = ROOT / 'Resources/CharacterFrames'
OUT = ROOT / 'docs/media/hero.gif'
CHARACTERS = [('chatgpt', 'Codex'), ('clawd', 'Claude Code'), ('grok', 'Grok Build')]
# Each segment plays at least one complete cycle of every character; one-shot states hold their last frame.
STATES = [('30', 'thinking'), ('32', 'working'), ('35', 'waiting for you'), ('33', 'done')]
HOLD = 30
CELL, SCALE, HEIGHT, FPS = 240, 3, 230, 15


def font(size):
    for name in ('SFNSRounded.ttf', 'SFNS.ttf', 'Helvetica.ttc'):
        try:
            return ImageFont.truetype(f'/System/Library/Fonts/{name}', size)
        except OSError:
            continue
    return ImageFont.load_default()


def background(size):
    image = Image.new('RGB', size)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        draw.line((0, y, size[0], y), fill=tuple(round(a + (b - a) * t) for a, b in zip((241, 244, 249), (224, 232, 241))))
    return image


manifests = {c: json.loads((FRAMES / c / 'manifest.json').read_text())['states'] for c, _ in CHARACTERS}
cache = {}


def sprite(character, state, index):
    key = (character, state, index)
    if key not in cache:
        image = Image.open(FRAMES / character / state / f'{index}.png').convert('RGBA')
        resample = Image.Resampling.NEAREST if character == 'clawd' else Image.Resampling.LANCZOS
        cache[key] = image.resize((image.width * SCALE, image.height * SCALE), resample)
    return cache[key]


title, caption = font(17), font(15)
width = CELL * len(CHARACTERS)
frames = []
for state, label in STATES:
    counts = {c: manifests[c][state]['frames'] for c, _ in CHARACTERS}
    loops = {c: manifests[c][state]['loop'] for c, _ in CHARACTERS}
    length = max(counts.values()) + (0 if all(loops.values()) else HOLD)
    for tick in range(length):
        canvas = background((width, HEIGHT))
        draw = ImageDraw.Draw(canvas)
        for column, (character, name) in enumerate(CHARACTERS):
            count = counts[character]
            index = tick % count if loops[character] else min(tick, count - 1)
            image = sprite(character, state, index)
            x = column * CELL + (CELL - image.width) // 2
            canvas.paste(image, (x, 28), image)
            draw.text((column * CELL + CELL / 2, 186), name, font=title, fill=(52, 58, 70), anchor='mm')
        draw.text((width / 2, 14), label, font=caption, fill=(110, 118, 132), anchor='mm')
        frames.append(canvas)

atlas = Image.new('RGB', (width, HEIGHT * 12))
for row, frame in enumerate(frames[:: max(1, len(frames) // 12)][:12]):
    atlas.paste(frame, (0, row * HEIGHT))
palette = atlas.quantize(colors=255)
indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
durations = [round((i + 1) * 100 / FPS) * 10 - round(i * 100 / FPS) * 10 for i in range(len(frames))]
indexed[0].save(OUT, save_all=True, append_images=indexed[1:], duration=durations, loop=0, disposal=1, optimize=True)
print(f'{OUT.relative_to(ROOT)}: {len(frames)} frames, {sum(durations) / 1000:.1f}s, {OUT.stat().st_size // 1024} KB')
