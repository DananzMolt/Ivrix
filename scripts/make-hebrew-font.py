#!/usr/bin/env python3
"""Build the Ivrix Mono He Hebrew fallback from a proportional source face.

A terminal gives every Hebrew letter exactly one cell, so a proportional face
gaps badly: advances vary 18-25% across the alphabet in every Hebrew font
measured, and a narrow letter such as yod can advance 0.213em inside a 0.600em
cell. This normalises a source face to a uniform advance so the row keeps an
even rhythm.

What it does per style:

  1. Subsets to the Hebrew block (Maple Mono owns Latin, so nothing else is
     needed and the files drop from ~200KB to ~20KB).
  2. Scales by whichever limit binds first - the target letter height, or the
     maximum ink width that keeps the widest letter inside the cell. Fitting
     is measured AFTER any shear, because shearing widens glyphs and sizing on
     the upright form overflows the cell for oblique styles.
  3. Centres every spacing glyph on a uniform advance. Combining marks (nikud)
     keep their zero advance so they stack on the base letter instead of
     consuming a cell.
  4. Renames the family and records the origin and modification in the name
     table, as the OFL requires for a derivative.

Usage:
  scripts/make-hebrew-font.py \
      --regular /path/NotoSansHebrew[wdth,wght].ttf \
      --bold    /path/NotoSansHebrew[wdth,wght].ttf \
      --license /path/OFL.txt \
      --credit  "Copyright ... (Noto Sans Hebrew)." \
      --out Resources/Fonts

Variable sources are instantiated at wght 400/700 automatically.
"""

import argparse
import math
import os
import sys

from fontTools.ttLib import TTFont
from fontTools import subset
from fontTools.varLib import instancer
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.misc.transform import Transform

CELL_EM = 0.600  # Maple Mono NF advance, i.e. the terminal cell width
HEBREW = range(0x0590, 0x0600)
LETTERS = range(0x05D0, 0x05EB)


def load_static(path, weight):
    """Load `path`, instantiating a variable font at `weight`."""
    f = TTFont(path)
    if "fvar" in f:
        axes = {a.axisTag: a for a in f["fvar"].axes}
        loc = {}
        if "wght" in axes:
            a = axes["wght"]
            loc["wght"] = min(max(weight, a.minValue), a.maxValue)
        for tag, a in axes.items():
            if tag != "wght":
                loc[tag] = a.defaultValue
        f = instancer.instantiateVariableFont(f, loc, updateFontNames=False, inplace=False)
        tmp = "/tmp/_ivrix_instance.ttf"
        f.save(tmp)
        f = TTFont(tmp)
    return f


def set_name(font, nid, value):
    for rec in font["name"].names:
        if rec.nameID == nid:
            rec.string = value


def build(src, style, weight, italic, fs_selection, args):
    opts = subset.Options()
    opts.name_IDs = ["*"]
    opts.name_legacy = True
    opts.name_languages = ["*"]
    opts.notdef_outline = True
    opts.layout_features = ["*"]
    opts.glyph_names = True
    opts.drop_tables = ["meta", "FFTM"]

    inst = load_static(src, weight)
    inst.save("/tmp/_ivrix_src.ttf")
    f = subset.load_font("/tmp/_ivrix_src.ttf", opts)
    sub = subset.Subsetter(options=opts)
    sub.populate(unicodes=list(HEBREW) + [0x20, 0x200E, 0x200F])
    sub.subset(f)

    upm = f["head"].unitsPerEm
    cell = int(CELL_EM * upm)
    glyphs = f.getGlyphSet()
    glyf = f["glyf"]
    hmtx = f["hmtx"]
    cmap = f.getBestCmap()

    present = [cmap[c] for c in LETTERS if c in cmap]
    if len(present) < 27:
        sys.exit(f"ERROR: {src} covers only {len(present)}/27 Hebrew letters")

    slant = math.tan(math.radians(args.slant)) if italic else 0.0

    def measure(scale):
        t = Transform(scale, 0, slant * scale, scale, 0, 0)
        heights, widths = [], []
        for gn in present:
            rec = DecomposingRecordingPen(glyphs)
            glyphs[gn].draw(rec)
            bp = BoundsPen(glyphs)
            rec.replay(TransformPen(bp, t))
            if bp.bounds:
                heights.append((bp.bounds[3] - bp.bounds[1]) / upm)
                widths.append((bp.bounds[2] - bp.bounds[0]) / upm)
        return sum(heights) / len(heights), max(widths)

    # Converge on the largest scale satisfying both limits. Measured after the
    # shear, since shearing widens glyphs.
    scale = 1.0
    for _ in range(8):
        h, w = measure(scale)
        limit = min(args.target_height / h, args.max_ink / w)
        if abs(limit - 1.0) < 0.001:
            break
        scale *= limit

    base = Transform(scale, 0, slant * scale, scale, 0, 0)
    for cp, gn in list(cmap.items()):
        if cp not in HEBREW:
            continue
        zero_width = hmtx[gn][0] == 0  # combining mark
        rec = DecomposingRecordingPen(glyphs)
        glyphs[gn].draw(rec)
        bp = BoundsPen(glyphs)
        glyphs[gn].draw(bp)
        if not bp.bounds:
            if not zero_width:
                hmtx[gn] = (cell, hmtx[gn][1])
            continue
        mb = BoundsPen(glyphs)
        rec.replay(TransformPen(mb, base))
        x0, _, x1, _ = mb.bounds
        width = x1 - x0
        tx = 0 if zero_width else (cell - width) / 2 - x0
        pen = TTGlyphPen(glyphs)
        rec.replay(TransformPen(pen, Transform(1, 0, 0, 1, tx, 0).transform(base)))
        glyf[gn] = pen.glyph()
        glyf[gn].recalcBounds(glyf)
        if not zero_width:
            hmtx[gn] = (cell, int((cell - width) / 2))

    note = ", synthetic oblique." if italic else "."
    set_name(f, 0, f"{args.credit} Modified for Ivrix: subset to Hebrew, "
                   f"uniform {CELL_EM:.3f}em advance{note}")
    set_name(f, 1, args.family)
    set_name(f, 2, style)
    set_name(f, 4, f"{args.family} {style}")
    set_name(f, 6, f"{args.family.replace(' ', '')}-{style.replace(' ', '')}")
    set_name(f, 16, args.family)
    set_name(f, 17, style)
    f["OS/2"].usWeightClass = weight
    f["OS/2"].fsSelection = (f["OS/2"].fsSelection & ~0b1100001) | fs_selection
    f["post"].isFixedPitch = 1
    f["OS/2"].panose.bProportion = 9
    if italic:
        f["post"].italicAngle = -float(args.slant)
        f["head"].macStyle |= 0b10
    if weight == 700:
        f["head"].macStyle |= 0b1

    out = os.path.join(args.out, f"{args.family.replace(' ', '')}-{style.replace(' ', '')}.ttf")
    f.save(out)

    # Report what actually landed, so a bad fit is visible rather than silent.
    v = TTFont(out)
    vc, vh, vg = v.getBestCmap(), v["hmtx"], v.getGlyphSet()
    vupm = v["head"].unitsPerEm
    advances = {vh[vc[c]][0] for c in LETTERS if c in vc}
    marks = {vh[vc[c]][0] for c in range(0x0591, 0x05BE) if c in vc}
    inks, heights = [], []
    for c in LETTERS:
        bp = BoundsPen(vg)
        vg[vc[c]].draw(bp)
        if bp.bounds:
            inks.append((bp.bounds[2] - bp.bounds[0]) / vupm)
            heights.append((bp.bounds[3] - bp.bounds[1]) / vupm)
    status = "OK" if max(inks) <= CELL_EM else "OVERFLOW"
    print(f"  {os.path.basename(out):28} scale={scale:.3f} h={sum(heights)/len(heights):.3f}em "
          f"ink={max(inks):.3f}em adv={advances} marks={marks or '{none}'} {status}")
    if status != "OK":
        sys.exit("ERROR: glyphs overflow the cell; lower --max-ink")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--regular", required=True, help="source face for regular/italic")
    p.add_argument("--bold", help="source face for bold (defaults to --regular)")
    p.add_argument("--license", required=True, help="OFL text to ship alongside")
    p.add_argument("--credit", required=True, help="upstream copyright line")
    p.add_argument("--family", default="Ivrix Mono He")
    p.add_argument("--out", default="Resources/Fonts")
    p.add_argument("--target-height", type=float, default=0.572,
                   help="desired Hebrew letter height in em")
    p.add_argument("--max-ink", type=float, default=0.595,
                   help="maximum ink width in em; must stay under the 0.600em cell")
    p.add_argument("--slant", type=float, default=12.0,
                   help="oblique angle in degrees for synthesised italics")
    p.add_argument("--regular-only", action="store_true",
                   help="build only the Regular face. Use for single-weight "
                        "sources: ghostty synthesises bold and italic when the "
                        "family lacks them, whereas shipping a 'Bold' with the "
                        "same outlines suppresses that and leaves no visual bold")
    args = p.parse_args()

    if args.max_ink > CELL_EM:
        sys.exit(f"ERROR: --max-ink {args.max_ink} exceeds the {CELL_EM} cell")
    bold_src = args.bold or args.regular
    os.makedirs(args.out, exist_ok=True)

    styles = [(args.regular, "Regular", 400, False, 0b1000000)]
    if not args.regular_only:
        styles += [
            (bold_src, "Bold", 700, False, 0b0100000),
            (args.regular, "Italic", 400, True, 0b0000001),
            (bold_src, "Bold Italic", 700, True, 0b0100001),
        ]
    else:
        # Drop any faces left from a previous build, or the stale Bold would
        # still be found and synthesis would never kick in.
        for style in ("Bold", "Italic", "BoldItalic"):
            stale = os.path.join(args.out, f"{args.family.replace(' ', '')}-{style}.ttf")
            if os.path.exists(stale):
                os.remove(stale)
                print(f"  removed stale {os.path.basename(stale)} (will be synthesised)")

    for src, style, weight, italic, fs in styles:
        build(src, style, weight, italic, fs, args)

    dest = os.path.join(args.out, f"OFL-{args.family.replace(' ', '')}.txt")
    with open(args.license) as fh, open(dest, "w") as out:
        out.write(fh.read())
    print(f"  {os.path.basename(dest):28} license shipped alongside")


if __name__ == "__main__":
    main()
