#!/bin/sh
# Parity check: renders samples/before1-4.png with the Python reference (reference/flashgrade.py, preset N for
# beforeN) and with the app's headless renderer, prints the mean absolute pixel difference, then runs the app's
# self-test. Needs uv. Samples are not in the repo: put any four photos with a person in samples/.
set -e
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/flashedit-parity
APP=dist/FlashEdit.app/Contents/MacOS/FlashEdit
mkdir -p "$OUT"
ls samples/before1.png samples/before2.png samples/before3.png samples/before4.png >/dev/null 2>&1 || {
    echo "Put four photos with a person in samples/before1.png ... samples/before4.png first."; exit 1; }
[ -x reference/flashmask ] || swiftc -O reference/flashmask.swift -o reference/flashmask
[ -x "$APP" ] || scripts/build.sh
uv run -q --no-project --with numpy --with pillow --with scipy python - "$APP" "$OUT" <<'PY'
import subprocess, sys
import numpy as np
from PIL import Image
app, out = sys.argv[1:]
total = []
for k in (1, 2, 3, 4):
    src, py, sw = f"samples/before{k}.png", f"{out}/py{k}.png", f"{out}/swift{k}.png"
    subprocess.run([sys.executable, "reference/flashgrade.py", src, py, str(k)], check=True, capture_output=True)
    subprocess.run([app, "render", src, sw, str(k)], check=True, capture_output=True)
    a, b = (np.asarray(Image.open(p).convert("RGB")).astype(float) for p in (py, sw))
    e = np.abs(a - b)
    total.append(e.mean() / 2.55)
    print(f"preset {k}: mean abs diff {total[-1]:.3f}%, max {e.max():.0f}/255 (label text), "
          f"pixels off by >1/255: {(e.max(-1) > 1).mean() * 100:.2f}%")
print(f"mean over the 4 photos: {np.mean(total):.3f}% (target < 1%)  outputs in {out}")
assert max(total) < 1
PY
# Isolate, presets, Color Mixer, catalog loading; a throwaway home so your own library and presets are untouched
CFFIXED_USER_HOME="$(mktemp -d)" "$APP" selftest samples/before1.png
