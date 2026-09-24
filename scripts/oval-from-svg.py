#!/usr/bin/env python3
"""
Read a year-oval SVG and update where Knolling draws the months.

    python3 scripts/oval-from-svg.py design/year-oval.svg           # print the numbers
    python3 scripts/oval-from-svg.py design/year-oval.svg --write   # also update MenuView.swift

The SVG is in the menu's own coordinates: a 288 x 86 drawing area (files exported at 2x or 3x
are scaled automatically) with the ring centred at (144, 43), radii 114 x 29. It should contain,
in order from September to August, one dot per month (where that month begins on the ring) and
one label per month. Dots and labels can be <circle>/<text> elements or outlined <path>s, as
Figma and Illustrator export them.
"""
import math, re, sys
from pathlib import Path

W, H = 288, 86
CX, CY, RX, RY = 144, 43, 114, 29
MONTHS = ["sep", "oct", "nov", "dec", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug"]

def path_bbox(d):
    xs, ys, x, y = [], [], 0.0, 0.0
    for cmd, args in re.findall(r'([MLHVCSQTZmlhvcsqtz])([^MLHVCSQTZmlhvcsqtz]*)', d):
        n = [float(v) for v in re.findall(r'-?\d*\.?\d+(?:e-?\d+)?', args)]
        if cmd in "MLT":
            for i in range(0, len(n) - 1, 2): x, y = n[i], n[i + 1]; xs.append(x); ys.append(y)
        elif cmd == "H":
            for v in n: x = v; xs.append(x); ys.append(y)
        elif cmd == "V":
            for v in n: y = v; xs.append(x); ys.append(y)
        elif cmd in "CSQ":
            for i in range(0, len(n) - 1, 2): xs.append(n[i]); ys.append(n[i + 1])
            if len(n) >= 2: x, y = n[-2], n[-1]
    return min(xs), min(ys), max(xs), max(ys)

def read(svg):
    vb = re.search(r'viewBox="([\d.\s-]+)"', svg)
    scale = float(vb.group(1).split()[2]) / W if vb else 1.0
    dots, labels = [], []
    # elements in document order
    for m in re.finditer(r'<(circle)\b([^>]*)>|<(text)\b([^>]*)>(.*?)</text>|<(path)\b([^>]*)>', svg, re.S):
        tag = m.group(1) or m.group(3) or m.group(6)
        attrs = m.group(2) or m.group(4) or m.group(7) or ""
        get = lambda k: (re.search(rf'\b{k}="([^"]+)"', attrs) or [None, None])[1]
        if tag == "circle":
            dots.append((float(get("cx")) / scale, float(get("cy")) / scale))
        elif tag == "text":
            # a text's x/y is its anchor; nudge to a centre using a monospace estimate
            x, y, anchor = float(get("x")), float(get("y")), get("text-anchor") or "start"
            width = 5.1 * len((m.group(5) or "").strip()) * scale
            x = x - width / 2 if anchor == "end" else (x + width / 2 if anchor == "start" else x)
            labels.append((x / scale, (y - 3 * scale) / scale))
        elif get("d"):
            x0, y0, x1, y1 = path_bbox(get("d"))
            w, h = (x1 - x0) / scale, (y1 - y0) / scale
            if w > 200:                      # the backdrop or the ring
                continue
            if w < 4 and h < 4:
                dots.append(((x0 + x1) / 2 / scale, (y0 + y1) / 2 / scale))
            elif h < 12 and w < 40:
                labels.append(((x0 + x1) / 2 / scale, (y0 + y1) / 2 / scale))
    if len(dots) < 12 or len(labels) < 12:
        sys.exit(f"Expected 12 dots and 12 labels, found {len(dots)} and {len(labels)}.")
    return dots[:12], labels[:12]

def angles(dots):
    out, prev = [], None
    for x, y in dots:
        a = math.degrees(math.atan2((y - CY) / RY, (x - CX) / RX)) % 360
        if prev is not None:
            while a < prev: a += 360
        out.append(round(a, 1)); prev = a
    return out + [round(out[0] + 360, 1)]

def swift(starts, labels):
    s = "    static let monthStarts: [Double] = [" + ", ".join(f"{a}" for a in starts) + "]"
    pts = [f"CGPoint(x: {x:.1f}, y: {y:.1f})" for x, y in labels]
    rows = [", ".join(pts[i:i + 4]) for i in range(0, 12, 4)]
    l = "    static let labelCentres: [CGPoint] = [\n        " + ",\n        ".join(rows) + "\n    ]"
    return s, l

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    dots, labels = read(Path(sys.argv[1]).read_text())
    starts_line, labels_block = swift(angles(dots), labels)
    print(starts_line); print(labels_block)
    if "--write" in sys.argv:
        view = Path(__file__).resolve().parent.parent / "Sources/Knolling/MenuView.swift"
        code = view.read_text()
        code = re.sub(r"    static let monthStarts: \[Double\] = \[[^\]]*\]", starts_line, code)
        code = re.sub(r"    static let labelCentres: \[CGPoint\] = \[.*?\n    \]", labels_block, code, flags=re.S)
        view.write_text(code)
        print(f"Updated {view}. Rebuild with ./build.sh")
