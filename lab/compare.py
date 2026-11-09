# For every output image, find which part of the source frame it actually shows.
import glob, subprocess, numpy as np
from PIL import Image
subprocess.run(['./ffmpeg','-v','error','-y','-ss','1','-i','src.mp4','-frames:v','1','-update','1','srcframe.png'])
src = np.asarray(Image.open('srcframe.png').convert('L')).astype(np.float32)
S = src[::4, ::4]
for f in sorted(glob.glob('*.mp4.*.png')):
    im = np.asarray(Image.open(f).convert('L')).astype(np.float32)
    h, w = im.shape
    if w > src.shape[1] or h > src.shape[0]:
        print(f'MATCH {f} size={w}x{h} (bigger than source)'); continue
    T = im[::4, ::4]; th, tw = T.shape
    best = (1e18, 0, 0)
    for y in range(0, S.shape[0] - th + 1):
        for x in range(0, S.shape[1] - tw + 1, 1):
            d = np.mean((S[y:y+th, x:x+tw] - T) ** 2)
            if d < best[0]: best = (d, x, y)
    print(f'MATCH {f} size={w}x{h} shows source area starting at x={best[1]*4}, y={best[2]*4} (want x=400,y=200 for crop variants; 0,0 for control) mse={best[0]:.1f}')
