#!/usr/bin/env python3
"""Writes Quill's vector brand assets from one geometry (the same as QuillBrand.swift).

The mark: a glass quill laid across a text selection (owner's choice, 2026-10-05). The
wordmark: "quill" in Geist (SIL OFL 1.1, © Vercel), lowercase, tracking -0.045 em —
Tessera's typography, so the family reads as one — converted to outlines, so no asset
depends on the font being installed.

usage: generate.py <path to Geist-Regular.ttf>
Writes the SVGs next to this file; `make-brand.sh` renders the rasters and the .icns.
"""
import os
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))

INK_TOP, INK_MID, INK_BOTTOM = "#2C2F9E", "#1A1660", "#0B0A2E"
SELECTION_LIGHT, SELECTION, HANDLE = "#6FA2FF", "#2F6BFF", "#3D78FF"
QUILL_INK = "#3B3FC9"

# The quill's placement, exactly QuillBrand.swift's `Geometry.quill`:
# translate(540, 478) · rotate(0.70 rad) · scale(0.93) · translate(-512, -512).
QUILL = "translate(540 478) rotate(40.107) scale(0.93) translate(-512 -512)"
VANE = ("M512 150 C590 230 640 350 626 470 C612 590 560 690 520 742 "
        "C470 690 420 610 424 520 C428 380 462 230 512 150 Z")
NOTCHES = "".join(f"M{x} {y - 6} L{x + d * 74} {y + 20} L{x} {y + 16} Z"
                  for x, y, d in [(640, 400, -1), (620, 585, -1), (418, 520, 1)])
SHAFT = "M506 190 L518 190 L524 760 L512 880 L500 760 Z"
SHAFT_LINE = "M512 200 L512 760"
BAND = dict(x=196, y=556, w=632, h=132, r=26)
HANDLES = [(196, 520, 520, 700), (828, 724, 544, 724)]  # stem x, knob y, stem top, stem bottom


def svg(width, height, body, title, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:g}" height="{height:g}" '
            f'viewBox="0 0 {width:g} {height:g}" role="img"><title>{title}</title>'
            f'<defs>{defs}</defs>{body}</svg>\n')


def write(name, content):
    path = os.path.join(HERE, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(content)
    print("wrote", name)


def band_rect(fill):
    b = BAND
    return f'<rect x="{b["x"]}" y="{b["y"]}" width="{b["w"]}" height="{b["h"]}" rx="{b["r"]}" fill="{fill}"/>'


def handles(fill):
    out = ""
    for x, knob, top, bottom in HANDLES:
        out += f'<rect x="{x - 7}" y="{top}" width="14" height="{bottom - top}" rx="7" fill="{fill}"/>'
        out += f'<circle cx="{x}" cy="{knob}" r="30" fill="{fill}"/>'
    return out


def colour_mark(prefix=""):
    """The mark in colour, flat glass for vector use (the raster adds the light)."""
    defs = (f'<linearGradient id="{prefix}sel" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{SELECTION_LIGHT}"/><stop offset="1" stop-color="{SELECTION}"/></linearGradient>'
            f'<linearGradient id="{prefix}glass" x1="0" y1="0" x2="1" y2="1">'
            f'<stop offset="0" stop-color="#8E9BFF" stop-opacity="0.80"/><stop offset="1" stop-color="#9B7BFF" stop-opacity="0.72"/></linearGradient>'
            f'<mask id="{prefix}notch" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
            f'<rect width="1024" height="1024" fill="#fff"/><path d="{NOTCHES}" fill="#000"/></mask>')
    body = (band_rect(f"url(#{prefix}sel)") + handles(HANDLE)
            + f'<g transform="{QUILL}"><path d="{VANE}" fill="url(#{prefix}glass)" mask="url(#{prefix}notch)"/>'
              f'<path d="{VANE}" fill="none" stroke="#14125A" stroke-opacity="0.35" stroke-width="6"/>'
              f'<path d="{SHAFT}" fill="{QUILL_INK}"/></g>')
    return defs, body


def mono_mark(colour, prefix=""):
    """The mark in one ink: a gap around the quill so it reads in front of the selection."""
    defs = (f'<mask id="{prefix}gap" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
            f'<rect width="1024" height="1024" fill="#fff"/>'
            f'<g transform="{QUILL}"><path d="{VANE}" fill="#000" stroke="#000" stroke-width="47"/>'
            f'<path d="{SHAFT}" fill="#000" stroke="#000" stroke-width="39"/></g></mask>'
            f'<mask id="{prefix}vane" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
            f'<rect width="1024" height="1024" fill="#fff"/>'
            # In the vane's own (transformed) space: the mask is applied inside the group.
            f'<path d="{NOTCHES}" fill="#000"/>'
            f'<path d="{SHAFT_LINE}" stroke="#000" stroke-width="10.75" stroke-linecap="round"/></mask>')
    body = (f'<g mask="url(#{prefix}gap)">{band_rect(colour)}{handles(colour)}</g>'
            f'<g transform="{QUILL}"><path d="{VANE}" fill="{colour}" mask="url(#{prefix}vane)"/></g>'
            f'<g transform="{QUILL}"><path d="M500 760 L524 760 L512 880 Z" fill="{colour}"/></g>')
    return defs, body


def icon_svg(light=False):
    """The app icon as a vector, for the web: body, background, selection, quill."""
    defs, mark = colour_mark("i")
    if light:
        background = ('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
                      '<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E9E6FF"/></linearGradient>')
        edge = '#FFFFFF" stroke-opacity="0.6'
    else:
        background = ('<linearGradient id="bg" x1="0.2" y1="0" x2="0.8" y2="1">'
                      f'<stop offset="0" stop-color="{INK_TOP}"/><stop offset="0.5" stop-color="{INK_MID}"/>'
                      f'<stop offset="1" stop-color="{INK_BOTTOM}"/></linearGradient>'
                      '<radialGradient id="glow" cx="0.27" cy="0.19" r="0.68">'
                      '<stop offset="0" stop-color="#7C8CFF" stop-opacity="0.55"/><stop offset="1" stop-color="#7C8CFF" stop-opacity="0"/></radialGradient>')
        edge = '#FFFFFF" stroke-opacity="0.14'
        # On ink, the quill is white glass and its shaft white.
        mark = mark.replace('fill="url(#iglass)"', 'fill="#FFFFFF" fill-opacity="0.62"').replace(f'fill="{QUILL_INK}"', 'fill="#FFFFFF"')
    glow = '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#glow)"/>' if not light else ""
    body = ('<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>' + glow + mark
            + f'<rect x="103" y="103" width="818" height="818" rx="182" fill="none" stroke="{edge}" stroke-width="6"/>')
    return svg(1024, 1024, body, "Quill", defs + background)


# MARK: Wordmark

def wordmark_path(font_path, text="quill", size=100.0, tracking=-0.045):
    font = TTFont(font_path)
    glyphs, cmap = font.getGlyphSet(), font.getBestCmap()
    units = font["head"].unitsPerEm
    scale = size / units
    ascender = font["hhea"].ascent
    x, paths = 0.0, []
    for char in text:
        name = cmap[ord(char)]
        pen = SVGPathPen(glyphs)
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x * scale, ascender * scale)))
        paths.append(pen.getCommands())
        x += glyphs[name].width + tracking * units
    width = (x - tracking * units) * scale
    return " ".join(paths), width, ascender * scale, (ascender - font["hhea"].descent) * scale


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: generate.py <Geist-Regular.ttf>")
    font = sys.argv[1]

    defs, body = colour_mark()
    write("mark.svg", svg(1024, 1024, body, "Quill", defs))
    for name, colour in [("mark-black.svg", "#0a0a0a"), ("mark-white.svg", "#ffffff")]:
        mdefs, mbody = mono_mark(colour)
        write(name, svg(1024, 1024, mbody, "Quill", mdefs))
    write("app-icon.svg", icon_svg())
    write("app-icon-light.svg", icon_svg(light=True))
    # The favicon is the icon: browsers show it on tabs of either colour.
    write("favicon.svg", icon_svg())

    path, width, ascent, height = wordmark_path(font)
    for name, colour in [("wordmark.svg", "#0a0a0a"), ("wordmark-white.svg", "#ffffff")]:
        write(name, svg(width, height, f'<path d="{path}" fill="{colour}"/>', "quill"))

    # Lockups: the mark 1.5 × the type size tall, 0.4 × the type size from the name, centred
    # on the lowercase letters (the descender of the q would otherwise pull it up). The mark's
    # ink spans this box of its 1024 canvas (knobs to the quill's tip).
    box_x, box_y, box_w, box_h = 166.0, 158.0, 694.0, 598.0
    type_size = 100.0
    mark_h = 1.5 * type_size
    scale = mark_h / box_h
    mark_w = box_w * scale
    gap = 0.4 * type_size
    total_w = mark_w + gap + width
    # Text baseline at `ascent`; the lowercase letters' middle about 0.27 em above it.
    centre_from_text_top = ascent - 0.27 * type_size
    text_offset = max(0.0, mark_h / 2 - centre_from_text_top)
    total_h = max(text_offset + height, text_offset + centre_from_text_top + mark_h / 2)
    for name, colour, on in [("lockup.svg", "#0a0a0a", None), ("lockup-white.svg", "#ffffff", None),
                             ("lockup-on-dark.svg", "#ffffff", INK_BOTTOM), ("lockup-on-light.svg", "#0a0a0a", "#ffffff")]:
        mdefs, mbody = colour_mark("l") if colour == "#0a0a0a" else mono_mark("#ffffff", "l")
        # On a background, a full type size of clear space; transparent, a sliver for antialiasing.
        pad = type_size if on else 0.06 * type_size
        text_top = pad + text_offset
        mark_top = text_top + centre_from_text_top - mark_h / 2
        group = (f'<g transform="translate({pad - box_x * scale:.2f} {mark_top - box_y * scale:.2f}) scale({scale:.5f})">{mbody}</g>'
                 f'<g transform="translate({pad + mark_w + gap:.2f} {text_top:.2f})"><path d="{path}" fill="{colour}"/></g>')
        background = f'<rect width="100%" height="100%" rx="{type_size * 0.4:.0f}" fill="{on}"/>' if on else ""
        write(name, svg(total_w + 2 * pad, total_h + 2 * pad, background + group, "Quill", mdefs))

    # Icon Composer layers: flat, no shadows, glows or rounding — the system adds the glass.
    layer = lambda body: svg(1024, 1024, body, "Quill layer")
    write("icon-composer/1-background.svg", layer(f'<rect width="1024" height="1024" fill="{INK_MID}"/>'))
    write("icon-composer/2-selection.svg", layer(band_rect(SELECTION) + handles(HANDLE)))
    write("icon-composer/3-quill.svg", svg(1024, 1024, f'<g transform="{QUILL}"><path d="{VANE}" fill="#FFFFFF" mask="url(#n)"/></g>',
                                          "Quill layer", f'<mask id="n" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
                                          f'<rect width="1024" height="1024" fill="#fff"/><path d="{NOTCHES}" fill="#000"/></mask>'))
    write("icon-composer/4-shaft.svg", layer(f'<g transform="{QUILL}"><path d="{SHAFT}" fill="#FFFFFF"/></g>'))


if __name__ == "__main__":
    main()
