#!/usr/bin/env python3
"""Put a new Studio take into the Studio scene of the overview video, and leave every other frame alone.

The overview video is 63 s; its Studio scene is 40.4 s – 47.8 s, a card on the page with the panel playing inside
it. This replaces what plays inside the card and nothing else: the page around the card, the caption, the other
scenes and the sound are the old video's own. The sound is copied, not re-encoded. The picture is encoded once.

The scene's timing is the video's own (its source page, which is not in the repository, states it):

  the card fades in    40.4 → 40.9      opacity eo(p(t, 40.4, 40.9))
  the card fades out   47.3 → 47.8      opacity 1 - eo(p(t, 47.3, 47.8))
  the scene before     fades out by 40.6; the scene after fades in from 47.6, above this one
  the take plays       40.6 → 47.4      frame floor(count * p(t, 40.6, 47.4))
  and is pushed in     40.4 → 47.8      zoom 1 + 0.06 * eo(p(t, 40.4, 47.8)), about (50 %, 35 %)

with p(t, a, b) = clamp((t - a) / (b - a)) and eo(x) = 1 - (1 - x)^3. `--check` measures that timing on the old
video before anything is written: if the caption does not fade the way the model says, the model is wrong for this
file and the script stops.

While the card is fully up its inside is the new take. While it fades in, the frame is rebuilt from what was under
it (the page's ground, and what is left of the scene before, read from the last frame before the card appears).
While it fades out it is rebuilt over the ground the same way, until the scene after starts to come in above it
(47.6): from there the old frame is kept and the take's share of it, under 7 %, is exchanged.

  python3 scene.py --video old.mp4 --film DIR --out new.mp4 [--offset FRAMES] [--crf N] [--check]

Needs ffmpeg and ffprobe on PATH, and numpy and Pillow.
"""
import argparse
import glob
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image

FPS = 30
W, H = 1920, 1080
# The inside of the card, measured on the old video: its 1 px border is the column 220 and the row 180.
CARD_X, CARD_Y, CARD_W, CARD_H = 221, 181, 1480, 771
CARD_R = 13
# What is handed to the encoder: the card and its border, on even pixels, so the colour planes line up.
PATCH_X, PATCH_Y, PATCH_W, PATCH_H = 220, 180, 1482, 774
T_IN, T_OUT = 40.4, 47.8
FIRST, LAST = 1213, 1433          # the frames the card is on; 1212 and 1434 have it at opacity 0


def clamp(x):
    return max(0.0, min(1.0, x))


def eo(x):
    return 1 - (1 - clamp(x)) ** 3


def p(t, a, b):
    return clamp((t - a) / (b - a))


def card_in(t):
    return eo(p(t, 40.4, 40.9))


def card_out(t):
    return 1 - eo(p(t, 47.3, 47.8))


def before_left(t):
    """How much of the scene before is still on the page."""
    return 1 - eo(p(t, 40.1, 40.6))


def after_in(t):
    """How much of the scene after is already over this one."""
    return eo(p(t, 47.6, 48.1))


def die(msg):
    print(f'scene: {msg}', file=sys.stderr)
    sys.exit(1)


def frames_of(video, first, last):
    """Frames first..last of the video, as RGB arrays, in order."""
    cmd = ['ffmpeg', '-v', 'error', '-i', video, '-vf', f"select='between(n,{first},{last})'",
           '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = W * H * 3
    for n in range(first, last + 1):
        buf = proc.stdout.read(size)
        if len(buf) != size:
            die(f'{video} ended at frame {n}: {len(buf)} of {size} bytes')
        yield n, np.frombuffer(buf, np.uint8).reshape(H, W, 3).astype(np.float32)
    proc.stdout.close()
    proc.wait()


def rounded_mask(w, h, r):
    """1 inside a w×h rectangle with corners of radius r, 0 outside, a pixel of antialiasing between."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    qx = np.abs(x + 0.5 - w / 2) - (w / 2 - r)
    qy = np.abs(y + 0.5 - h / 2) - (h / 2 - r)
    dist = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
    return np.clip(0.5 - dist, 0, 1)[..., None]


def take_frame(files, cache, t):
    """What the card shows at t: the take's frame for that moment, pushed in as far as the scene has got."""
    k = min(len(files) - 1, math.floor(len(files) * p(t, 40.6, 47.4)))
    if cache.get('k') != k:
        cache['k'] = k
        cache['im'] = Image.open(files[k]).convert('RGB')
    im = cache['im']
    z = 1 + 0.06 * eo(p(t, T_IN, T_OUT))
    sw, sh = im.width / z, im.height / z
    x0, y0 = (im.width - sw) / 2, (im.height - sh) * 0.35
    out = im.resize((CARD_W, CARD_H), Image.LANCZOS, box=(x0, y0, x0 + sw, y0 + sh))
    return np.asarray(out, np.float32)


def check(video, offset):
    """
    Does the old video fade the way the model says? The caption is white on the ground and belongs to the scene,
    so its brightness over the fade-in is the scene's opacity, read off the file.
    """
    rows = []
    box = (slice(60, 112), slice(700, 1220))
    frames = dict(frames_of(video, 1212 + offset, 1240 + offset))
    full = frames[1240 + offset][box]
    ground = np.median(frames[1240 + offset][20:50, 20:300].reshape(-1, 3), axis=0)
    glyph = full.sum(axis=2) > 600                    # the pixels that are solid text when the scene is fully up
    if glyph.sum() < 500:
        die('check: the caption is not where the model expects it — this is not the video the model describes')
    worst = 0.0
    for n in range(1212, 1232):
        got = float(((frames[n + offset][box][glyph] - ground) / (full[glyph] - ground)).mean())
        want = card_in(n / FPS)
        worst = max(worst, abs(got - want))
        rows.append(f'  frame {n}  t={n / FPS:6.3f}  measured {got:5.3f}  model {want:5.3f}')
    print('\n'.join(rows))
    print(f'scene: check — fade-in, worst difference between the file and the model: {worst:.3f}')
    if worst > 0.05:
        die('check: the old video does not fade the way the model says; nothing was written')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--video', required=True)
    ap.add_argument('--film', required=True)
    ap.add_argument('--out')
    ap.add_argument('--offset', type=int, default=0, help='frames this file has before the video proper')
    ap.add_argument('--crf', default='20')
    ap.add_argument('--tune', default='animation')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.film, 'f*.png')))
    if len(files) < 60:
        die(f'{a.film} holds {len(files)} frames; a take is a few hundred')
    check(a.video, a.offset)
    if a.check:
        return
    if not a.out:
        die('--out is required')

    off = a.offset
    enc = subprocess.Popen([
        'ffmpeg', '-v', 'error', '-y', '-i', a.video,
        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{PATCH_W}x{PATCH_H}', '-framerate', str(FPS), '-i', '-',
        '-filter_complex',
        f"[1:v]setpts=PTS+{FIRST + off}/({FPS}*TB)[p];"
        f"[0:v][p]overlay={PATCH_X}:{PATCH_Y}:eof_action=pass:enable='between(n,{FIRST + off},{LAST + off})'[v]",
        '-map', '[v]', '-map', '0:a', '-c:a', 'copy',
        '-c:v', 'libx264', '-preset', 'slow', '-tune', a.tune, '-crf', a.crf, '-pix_fmt', 'yuv420p',
        '-fps_mode', 'passthrough', '-movflags', '+faststart', a.out,
    ], stdin=subprocess.PIPE)

    mask = rounded_mask(CARD_W, CARD_H, CARD_R)
    inner = (slice(CARD_Y, CARD_Y + CARD_H), slice(CARD_X, CARD_X + CARD_W))
    patch = (slice(PATCH_Y, PATCH_Y + PATCH_H), slice(PATCH_X, PATCH_X + PATCH_W))
    cache = {}
    under = ground = old_end = None
    for n, frame in frames_of(a.video, FIRST - 1 + off, LAST + off):
        n -= off
        t = n / FPS
        if n == FIRST - 1:
            # The card is at opacity 0 here: this is the ground with what is left of the scene before.
            under = frame[inner].copy()
            ground = np.median(frame[20:50, 20:300].reshape(-1, 3), axis=0)
            continue
        old = frame[inner]
        new = take_frame(files, cache, t)
        if t < 40.9:
            alpha = card_in(t)
            below = ground + (before_left(t) / before_left(T_IN)) * (under - ground)
            shown = (1 - alpha) * below + alpha * new
        elif t <= 47.3 + 1e-9:
            shown = new
            old_end = old.copy()                     # the last fully shown frame of the old take
        elif t < 47.6:
            # Nothing is over the card yet, and nothing under it but the ground.
            alpha = card_out(t)
            shown = (1 - alpha) * ground + alpha * new
        else:
            # The scene after is coming in above. What it has put here is not known, so the old frame is kept
            # and the take's share of it exchanged. That share is under 7 % from here on.
            weight = card_out(t) * (1 - after_in(t))
            shown = old + weight * (new - old_end)
        frame[inner] = old + mask * (shown - old)
        enc.stdin.write(np.clip(frame[patch] + 0.5, 0, 255).astype(np.uint8).tobytes())
    enc.stdin.close()
    if enc.wait() != 0:
        die('the encoder failed')
    print(f'scene: {a.out}  {os.path.getsize(a.out)} bytes  (frames {FIRST + off}–{LAST + off} of the card rebuilt from {len(files)} take frames)')


if __name__ == '__main__':
    main()
