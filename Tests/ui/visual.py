"""Compares screen regions against committed baselines, in perceptual terms.

Dynamic text moves a little between runs, so a whole-image byte comparison would
always fail. This measures the fraction of pixels that changed by more than a
tolerance, after a blur that absorbs antialiasing, and writes a diff image.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter

TOLERANCE = 28  # Per-channel difference a person would not see after the blur.
LIMIT = 0.02  # The share of pixels allowed to differ.


def compare(actual, baseline, diff_path, update=False):
    """Returns the changed share, or None when this run created the baseline."""
    actual, baseline, diff_path = Path(actual), Path(baseline), Path(diff_path)
    if update or not baseline.exists():
        baseline.parent.mkdir(parents=True, exist_ok=True)
        Image.open(actual).convert("RGB").resize((1400, 900)).save(baseline)
        return None
    a = Image.open(actual).convert("RGB").resize((1400, 900)).filter(ImageFilter.GaussianBlur(1))
    b = Image.open(baseline).convert("RGB").filter(ImageFilter.GaussianBlur(1))
    delta = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > TOLERANCE else 0)
    changed = sum(delta.histogram()[255:]) / (delta.width * delta.height)
    diff_path.parent.mkdir(parents=True, exist_ok=True)
    delta.save(diff_path)
    return changed
