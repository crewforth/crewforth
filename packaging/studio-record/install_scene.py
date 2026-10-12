#!/usr/bin/env python3
"""Change the version and the skill count the overview video's install scene prints, and nothing else.

The scene (7.0 s – 12.2 s) types `npx crewforth init` into a terminal, and two of the lines that answer carry
numbers: "Crewforth 3.0.0" and "12 agents  39 skills". This rewrites those digits in place. Every other pixel of
every frame is the input video's, the sound is copied, and the picture is encoded once.

The video's source page is not in the repository, so the lines are not rendered again from it.
`install-render.mjs` draws the two numbers the way that page lays them out, as the video has them and as they
should read, and says where each character is. Only the characters that differ are touched ("0" → "1"; "39" →
"40"): there the video's own picture of the old character is taken out and the drawing of the new one put in, at
the weight the line has on that frame. The drawing is first matched to the video (a gain, an offset and a blur
fitted on the old numbers, on a frame where both lines are fully shown), because a frame of a compressed video is
softer than a fresh drawing.

The timing is the page's own: a line appears at 8.8 s and 9.3 s over 0.3 s, the scene fades out 11.7 → 12.2,
and the next scene comes in above it from 12.0. `check` measures the first of those on the video before anything
is written.

  node install-render.mjs --out DIR --was "3.0.0,39" --now "3.1.0,40"
  python3 install_scene.py --video IN.mp4 --drawn DIR --out OUT.mp4 [--offset FRAMES] [--crf N]

Needs ffmpeg, numpy and Pillow (as scene.py does).
"""
import argparse
import json
import os
import subprocess

import numpy as np
from PIL import Image, ImageFilter

from scene import FPS, die, eo, frames_of, p

# What is handed to the encoder: one rectangle holding both numbers, on even pixels.
X0, Y0, X1, Y1 = 576, 262, 664, 342
SPLIT = 301                         # the first line is above this row, the second below
LINES = (8.8, 9.3)                  # when each of the two lines starts to appear
FIRST, LAST = 265, 365              # the frames on which either line is on screen
REFERENCE = 330                     # 11.0 s: both lines fully shown, nothing fading


def shown(t, line):
    """How much of a line is on the page at t."""
    appear = eo(p(t, LINES[line], LINES[line] + 0.3))
    scene = 1 - eo(p(t, 11.7, 12.2))
    under_next = 1 - eo(p(t, 12.0, 12.5))
    return appear * scene * under_next


def crop(image):
    return image[Y0:Y1, X0:X1]


def layout(drawn_dir):
    """
    Where the two numbers are, as the browser laid them out.
    @returns (numbers, changed): two masks over the rectangle — every character of the two numbers, and the
             characters that are different in the new text.
    """
    with open(os.path.join(drawn_dir, 'rects.json')) as f:
        drawn = json.load(f)
    numbers = np.zeros((Y1 - Y0, X1 - X0), bool)
    changed = np.zeros_like(numbers)
    for name, was in drawn['was'].items():
        now = drawn['now'][name]
        if len(was['text']) != len(now['text']):
            die(f'"{was["text"]}" and "{now["text"]}" are not the same length: the characters after them would move')
        for cell, a, b in zip(was['cells'], was['text'], now['text']):
            left, top, width, height = cell
            if left < X0 or left + width > X1 or top < Y0 or top + height > Y1:
                die(f'the character "{a}" at {left:.0f},{top:.0f} is outside the rectangle this script rewrites')
            box = (slice(int(top) - Y0, int(np.ceil(top + height)) - Y0), slice(int(left) - X0, int(np.ceil(left + width)) - X0))
            numbers[box] = True
            if a != b:
                changed[box] = True
    return numbers, changed


def match(video_frame, was_image, mask):
    """
    The gain, offset and blur that make the drawing of the old numbers look like the video's frame of them.
    @returns (blur, gain, offset, psnr)
    """
    target = crop(video_frame)[mask]
    best = None
    for blur in (0.0, 0.2, 0.3, 0.45, 0.6, 0.8):
        drawn = crop(np.asarray(was_image.filter(ImageFilter.GaussianBlur(blur)), np.float32))[mask]
        gain, offset = np.polyfit(drawn.ravel(), target.ravel(), 1)
        err = ((drawn * gain + offset - target) ** 2).mean()
        if best is None or err < best[0]:
            best = (err, blur, gain, offset)
    err, blur, gain, offset = best
    return blur, gain, offset, 10 * np.log10(255 ** 2 / err)


def check(video, offset):
    """Does the first line appear when the model says? Its brightness over the 0.3 s is its opacity."""
    frames = dict(frames_of(video, 262 + offset, 280 + offset))
    box = (slice(268, 298), slice(440, 570))                 # "Crewforth", which this script does not touch
    ground = np.median(frames[262 + offset][box].reshape(-1, 3), axis=0)
    full = frames[280 + offset][box]
    glyph = (full - ground).sum(axis=2) > 200
    if glyph.sum() < 200:
        die('check: the first line is not where the model expects it — this is not the video the model describes')
    worst = 0.0
    for n in range(263, 277):
        got = float(((frames[n + offset][box][glyph] - ground) / (full[glyph] - ground)).mean())
        worst = max(worst, abs(got - eo(p(n / FPS, LINES[0], LINES[0] + 0.3))))
    print(f'install: check — the first line appearing, worst difference between the file and the model: {worst:.3f}')
    if worst > 0.08:
        die('check: the video does not show the line the way the model says; nothing was written')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--video', required=True)
    ap.add_argument('--drawn', required=True, help='the directory install-render.mjs wrote')
    ap.add_argument('--out', required=True)
    ap.add_argument('--offset', type=int, default=0, help='frames this file has before the video proper')
    ap.add_argument('--crf', default='20')
    a = ap.parse_args()
    off = a.offset

    check(a.video, off)
    was = Image.open(os.path.join(a.drawn, 'was.png')).convert('RGB')
    now = Image.open(os.path.join(a.drawn, 'now.png')).convert('RGB')
    reference = next(frames_of(a.video, REFERENCE + off, REFERENCE + off))[1]
    numbers, changed = layout(a.drawn)
    blur, gain, offset, fit = match(reference, was, numbers)
    print(f'install: the drawing matched to the video — blur {blur}, gain {gain:.3f}, offset {offset:.1f}, {fit:.1f} dB on the old numbers')
    if fit < 27:
        die(f'the drawing of the old numbers does not look like the video ({fit:.1f} dB): the layout, the font or its smoothing is not the video\'s')
    as_video = crop(np.asarray(now.filter(ImageFilter.GaussianBlur(blur)), np.float32)) * gain + offset
    # In a character that changes, the video's own picture of the old one is taken out (the reference frame, where
    # the line is fully shown) and the matched drawing of the new one put in. Everywhere else nothing changes.
    change = np.where(changed[..., None], as_video - crop(reference), 0.0)
    rows = np.arange(Y0, Y1)[:, None, None]

    w, h = X1 - X0, Y1 - Y0
    enc = subprocess.Popen([
        'ffmpeg', '-v', 'error', '-y', '-i', a.video,
        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{w}x{h}', '-framerate', str(FPS), '-i', '-',
        '-filter_complex',
        f"[1:v]setpts=PTS+{FIRST + off}/({FPS}*TB)[p];"
        f"[0:v][p]overlay={X0}:{Y0}:eof_action=pass:enable='between(n,{FIRST + off},{LAST + off})'[v]",
        '-map', '[v]', '-map', '0:a', '-c:a', 'copy',
        '-c:v', 'libx264', '-preset', 'slow', '-tune', 'animation', '-crf', a.crf, '-pix_fmt', 'yuv420p',
        '-fps_mode', 'passthrough', '-movflags', '+faststart', a.out,
    ], stdin=subprocess.PIPE)
    for n, frame in frames_of(a.video, FIRST + off, LAST + off):
        t = (n - off) / FPS
        weight = np.where(rows < SPLIT, shown(t, 0), shown(t, 1))
        patch = crop(frame) + weight * change
        enc.stdin.write(np.clip(patch + 0.5, 0, 255).astype(np.uint8).tobytes())
    enc.stdin.close()
    if enc.wait() != 0:
        die('the encoder failed')
    print(f'install: {a.out}  {os.path.getsize(a.out)} bytes  (frames {FIRST + off}–{LAST + off}; {int(changed.sum())} pixels in the characters that change)')


if __name__ == '__main__':
    main()
