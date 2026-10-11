"""Learn a flashgrade preset from one before/after pair.
Usage: python fit.py before.png after.png out.json [y0:y1:x0:x1 ...]   (regions to ignore, e.g. UI overlays)
"""
import json, sys, time
import numpy as np
from scipy.ndimage import gaussian_filter, zoom
from scipy.optimize import minimize
from flashgrade import *

bpath, apath, out = sys.argv[1:4]
B, A = load(bpath), load(apath)
M, faces = person_and_faces(bpath)
H, W = M.shape
ok = np.ones((H, W), bool)
for r in sys.argv[4:]:
    y0, y1, x0, x1 = map(int, r.split(":")); ok[y0:y1, x0:x1] = False
noface = np.ones((H, W), bool)
for f in faces: noface &= face_mask((H, W), f, M) < 0.05   # faces get their own skin step below
sc = 0.35
h = lambda x: zoom(x, (sc, sc, 1)[:x.ndim], order=1)
Bh, Ah, Mh = h(B), h(A), h(M)
okh = h((ok & noface).astype(np.float32)) > 0.99
wt = (1 + 2 * Mh)[okh]  # the flash-lit person matters most
bl = lambda x: np.stack([gaussian_filter(x[..., c], 0.9) for c in range(3)], -1)
Abl = bl(Ah)
ID = [0.125] * 8
skin0 = {"skin_L": 0, "skin_a": 0, "skin_b": 0}
names = ["omega", "temp_ambient", "tint_ambient", "temp_flash", "tint_flash", "sat_ambient", "sat_flash", "spill", "shine", "clarity"]
def P(v):
    p = dict(zip(names, v[:10]), ambient=list(v[10:18]), flash=list(v[18:26]), **skin0)
    if len(v) > 26: p.update(fog=v[26], fog_start=v[27], fog_gamma=v[28], fog_color=list(v[29:32]))
    return p
x0 = [0.0, 0, 0, 0, 0, 1, 1, 0.2, 0, 0] + ID + ID + [0.3, 0.2, 1.0, 0.6, 0.65, 0.62]
bounds = [(0, 0.95), (-0.2, 0.2), (-0.2, 0.2), (-0.2, 0.2), (-0.2, 0.2), (0.5, 1.6), (0.8, 1.4), (0, 0.6), (0, 0.6), (0, 2)] + [(0, 0.4)] * 16 \
    + [(0, 0.9), (0, 0.8), (0.3, 3), (0.3, 1), (0.3, 1), (0.3, 1)]
def err(v): return float((np.abs(bl(edit(Bh, Mh, [], P(v))) - Abl)[okh].mean(-1) * wt).sum() / wt.sum())
def loss(v): return err(v) + 0.02 * np.mean((np.array(v[10:26]) - 0.125) ** 2) * 64
t = time.time()
r = minimize(loss, x0, method="Powell", bounds=bounds, options={"maxiter": 8000, "xtol": 1e-3, "ftol": 1e-5})
p = P(r.x)
# skin: Lab shift that takes our graded skin to their skin
if faces:
    o = edit(B, M, [], p)
    core = np.zeros((H, W), bool)
    for f in faces: core |= face_mask((H, W), f, M) > 0.9
    core &= ok
    skB, skA = core & (skin_weight(B) > 0.8), core & (skin_weight(A) > 0.8)
    if skB.sum() > 50 and skA.sum() > 50:
        d = rgb2lab(A)[skA].mean(0) - rgb2lab(o)[skB].mean(0)
        p.update(skin_L=float(d[0]), skin_a=float(d[1]), skin_b=float(d[2]))
p = {k: ([round(float(c), 4) for c in v] if isinstance(v, list) else round(float(v), 4)) for k, v in p.items()}
json.dump(p, open(out, "w"), indent=1)
print(f"{out}: before-vs-after err {err([0.0, 0, 0, 0, 0, 1, 1, 0, 0, 0] + ID + ID):.4f} -> fitted {err(r.x):.4f} ({time.time()-t:.0f}s)")
