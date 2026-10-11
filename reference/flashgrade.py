"""Meitu-style "De Fog + Flash" edit, rebuilt from real image operations so it adapts to any photo.

Pipeline (each step has a few parameters, fitted once on a reference before/after pair):
  1. De Fog  - dark-channel-prior dehaze (He et al.), strength `omega`
  2. Tone    - exposure, contrast, highlights, shadows, saturation, temperature, tint
  3. Flash   - extra light on the person (Vision mask) that falls off toward the silhouette edges
  4. Skin    - faces get a brighter, pinker skin tone and gentle smoothing
Usage: python flashgrade.py in.jpg out.jpg [preset 1-4]
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt, gaussian_filter, minimum_filter, uniform_filter

HERE = os.path.dirname(os.path.abspath(__file__))
LUMA = np.array([0.2126, 0.7152, 0.0722])


def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float32) / 255


def save(path, img, label=None):
    im = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8))
    if label:  # small white tag in the top-left corner, with a soft shadow so it reads on bright skies
        from PIL import ImageDraw, ImageFilter, ImageFont
        W = im.width
        font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", max(14, round(W * 0.045)))
        pos = (round(W * 0.035), round(W * 0.03))
        shadow = Image.new("L", im.size, 0)
        ImageDraw.Draw(shadow).text(pos, label, font=font, fill=110)
        im.paste((0, 0, 0), mask=shadow.filter(ImageFilter.GaussianBlur(max(1, W / 400))))
        ImageDraw.Draw(im).text(pos, label, font=font, fill=(255, 255, 255))
    im.save(path, quality=95)


def lin(x):
    return np.where(x <= 0.04045, x / 12.92, ((np.clip(x, 0, None) + 0.055) / 1.055) ** 2.4)


def srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * x ** (1 / 2.4) - 0.055)


def guided(I, p, r, eps):
    box = lambda x: gaussian_filter(x, r / 2)  # round windows: square ones leave blocky patches in the mask
    mI, mp = box(I), box(p)
    a = (box(I * p) - mI * mp) / (box(I * I) - mI * mI + eps)
    b = mp - a * mI
    return box(a) * I + box(b)


def dehaze(img, omega, s):
    """Dark channel prior: estimate haze (airlight A, transmission t) and remove `omega` of it."""
    patch = max(3, int(15 * s) | 1)
    dark = minimum_filter(img.min(2), size=patch)
    top = np.argsort(dark.ravel())[-max(1, dark.size // 1000):]
    A = img.reshape(-1, 3)[top].mean(0)
    t = 1 - omega * minimum_filter((img / A).min(2), size=patch)
    t = guided(img @ LUMA, t, max(4, int(40 * s)), 1e-3)
    return (img - A) / np.maximum(t, 0.1)[..., None] + A


def curve(x, steps):
    """Monotone tone curve through 9 knots; `steps` = 8 rises (identity = 0.125 each)."""
    from scipy.interpolate import PchipInterpolator
    knots = np.minimum(np.r_[0.0, np.cumsum(np.maximum(steps, 0))], 1.0)
    return PchipInterpolator(np.linspace(0, 1, 9), knots)(np.clip(x, 0, 1))


def tone(x, steps, sat, temp, tint):
    """Brightness-only curve (keeps hue), then white balance and saturation."""
    y = np.maximum(x @ LUMA, 1e-4)
    x = x * (curve(y, steps) / y)[..., None]
    x = srgb(lin(np.clip(x, 0, 1)) * np.array([1 + temp, 1 + tint, 1 - temp]))
    y = x @ LUMA
    return y[..., None] + (x - y[..., None]) * sat


XYZ = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
WHITE = np.array([0.9505, 1, 1.089])


def rgb2lab(x):
    X = lin(x) @ XYZ.T / WHITE
    f = np.where(X > 0.008856, np.cbrt(np.clip(X, 0, None)), 7.787 * X + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def lab2rgb(L):
    fy = (L[..., 0] + 16) / 116
    f = np.stack([fy + L[..., 1] / 500, fy, fy - L[..., 2] / 200], -1)
    X = np.where(f > 0.2069, f ** 3, (f - 16 / 116) / 7.787) * WHITE
    return srgb(X @ np.linalg.inv(XYZ).T)


def skin_weight(img):
    """Soft skin-likeness: warm hue, not grey, not too dark or blown out."""
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    y = img @ LUMA
    warm = np.clip((r - b - 0.02) / 0.06, 0, 1) * np.clip((r - g + 0.01) / 0.03, 0, 1)
    return warm * np.clip((y - 0.12) / 0.08, 0, 1) * np.clip((0.95 - y) / 0.1, 0, 1)


def face_mask(shape, face, person):
    """Soft oval over the Vision face box (x, y, w, h), limited to the person."""
    H, W = shape
    x, y, w, h = face
    yy, xx = np.mgrid[:H, :W]
    d = ((xx - (x + w / 2)) / (w * 0.85)) ** 2 + ((yy - (y + h * 0.55)) / (h * 0.85)) ** 2  # Vision boxes are tight
    return np.clip((1.25 - d) / 0.5, 0, 1) * np.clip(person * 1.5, 0, 1)


def skin_smooth(img, r, eps=0.002):
    """Self-guided filter: flattens skin texture, keeps edges (eyes, lips, glasses)."""
    box = lambda x: uniform_filter(x, size=2 * r + 1, mode="reflect")
    out = np.empty_like(img)
    for c in range(3):
        I = img[..., c]
        m = box(I); v = box(I * I) - m * m
        a = v / (v + eps)
        out[..., c] = box(a) * I + box(m - a * m)
    return out


def refine_mask(img, M, s):
    """Snap the coarse Vision mask to real edges (cap against sky, hair) with a guided filter."""
    return np.clip(guided(img @ LUMA, M, max(4, int(8 * s)), 1e-3), 0, 1)


def flash_light(x, p, s):
    """Flash exposure on the person: own curve and white balance, plus shine on bright surfaces (cap, forehead)."""
    x = tone(x, p["flash"], p["sat_flash"], p["temp_flash"], p["tint_flash"])
    if p.get("warm_ev"):  # luminance of dark warm tones (brown hair), like Lightroom's orange-luminance slider
        y = x @ LUMA
        w = np.clip((x[..., 0] - x[..., 2] - 0.02) / 0.06, 0, 1) * np.clip((0.5 - y) / 0.15, 0, 1)
        w = gaussian_filter(w, 2 * s)[..., None]  # smooth, so JPEG colour blocks can't show through
        x = srgb(lin(x) * 2 ** (p["warm_ev"] * w))
    hi = np.clip((x @ LUMA - 0.45) / 0.4, 0, 1)[..., None] ** 1.5
    x = x + p["shine"] * hi * (1 - x)
    y = (x @ LUMA)[..., None]
    x = y + (x - y) * (1 - p.get("white", 0) * hi)  # flash keeps whites neutral (cap stays white, not cream)
    detail = x - np.stack([gaussian_filter(x[..., c], 3 * s) for c in range(3)], -1)
    return x + p["clarity"] * detail * (0.3 + hi)


def edit(img, M, faces, p):
    """Ambient exposure on the background, flash exposure on the person (like a real flash shot)."""
    H, W = M.shape
    s = min(H, W) / 720  # parameters were fitted on ~720px-wide photos
    x = np.clip(dehaze(img, p["omega"], s), 0, 1)
    Mr = refine_mask(img, M, s)
    # a real flash also reaches the scene just behind the person, so the edge fades instead of looking cut out
    spill = p["spill"] * np.exp(-distance_transform_edt(Mr < 0.5) / (60 * s))
    Wf = (Mr + (1 - Mr) * spill)[..., None]
    amb = tone(x, p["ambient"], p["sat_ambient"], p["temp_ambient"], p["tint_ambient"])
    x = np.clip(amb * (1 - Wf) + flash_light(x, p, s) * Wf, 0, 1)
    if p.get("fog", 0) > 0:  # mist behind the person, thicker toward the top (farther away)
        up = 1 - np.arange(H, dtype=np.float32) / (H - 1)
        ramp = np.clip((up - p["fog_start"]) / (1 - p["fog_start"] + 1e-6), 0, 1) ** p["fog_gamma"]
        f = p["fog"] * ramp[:, None, None] * (1 - Mr[..., None])
        x = x * (1 - f) + np.array(p["fog_color"]) * f
    # hands, neck, arms: same skin tone as the face (skin-coloured and brighter than hair)
    redness = np.clip((img[..., 0] - img[..., 2] - 0.11) / 0.04, 0, 1)  # skin r-b ~0.17, brown hair ~0.05
    body = gaussian_filter(skin_weight(img) * redness * np.clip((img @ LUMA - 0.33) / 0.08, 0, 1), s) * Mr
    for f in faces:
        body *= 1 - face_mask((H, W), f, Mr)
    if faces:
        bshift = [p.get("body_L", p["skin_L"]), p["skin_a"], p["skin_b"]]
        x = x * (1 - body[..., None]) + np.clip(lab2rgb(rgb2lab(x) + bshift), 0, 1) * body[..., None]
    for f in faces:
        F = (face_mask((H, W), f, Mr) * gaussian_filter(skin_weight(img), 1.5 * s))[..., None]
        lab = rgb2lab(x)
        Lm = gaussian_filter(lab[..., 0], f[2] / 4)  # keep the face's own shading (cheek/jaw shadows), scaled by skin_contrast
        lab[..., 0] = Lm + (lab[..., 0] - Lm) * p.get("skin_contrast", 1.0)
        sk = skin_smooth(np.clip(lab2rgb(lab + [p["skin_L"], p["skin_a"], p["skin_b"]]), 0, 1), max(2, round(f[2] / 35)))
        x = x * (1 - F) + sk * F
    return np.clip(x, 0, 1)


def person_and_faces(path):
    mpath = tempfile.mktemp(suffix=".png")
    out = subprocess.run([os.path.join(HERE, "flashmask"), path, mpath], capture_output=True, text=True, check=True).stdout
    faces = [tuple(int(v) for v in l.split()[1:]) for l in out.splitlines() if l.startswith("face")]
    M = np.asarray(Image.open(mpath)).astype(np.float32) / 255
    os.remove(mpath)
    return M, faces


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    preset = sys.argv[3] if len(sys.argv) > 3 else "1"  # look learned from reference photo 1..4
    params = json.load(open(os.path.join(HERE, f"preset{preset}.json")))
    M, faces = person_and_faces(src)
    save(dst, edit(load(src), M, faces, params), label="claude")
    print(f"{dst}: {len(faces)} face(s)")
