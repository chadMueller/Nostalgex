#!/usr/bin/env python3
"""Draw the guide's overlay images into images/look/, from the Apple TV app's
SwiftUI drawing code (upstream Nostalgex/Nostalgex/Views):

  CRTOverlayView.swift   scanlines.png, vignette.png, vignette_full.png
  ChannelGuideView.swift focus.9.png (row outline and glow), badge.9.png,
                         seasonal.9.png, seasonal_focus.9.png, capsule.9.png
  StaticScreenView.swift snow_0..2.png
  PlayerView.swift       osd.png (ChannelOSD's gradient)
  bolt.png and gear.png are drawn here: SF Symbols can't be bundled. star.png
  stands in for the meta row's "★", which none of the bundled fonts has.
  App/Plex90App.swift    step_ring.png, step_dot.png, step_check.png
                         (LibraryLoadStepRail: Roku draws no circles)
  OnboardingStyle.swift  ob_*.9.png: the connect screens' slab, edges, field
                         frame and capsules, each with its glow

White art is tinted on the TV with a Poster's blendColor. Run it again after
changing it; the PNGs are committed. Needs Pillow.
"""
import os
import random

from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "images", "look")
os.makedirs(OUT, exist_ok=True)


def save(img, name):
    img.save(os.path.join(OUT, name), optimize=True)


def lerp(a, b, t):
    return a + (b - a) * max(0.0, min(1.0, t))


# ── CRT (CRTOverlayView.swift) ──────────────────────────────────────────────

# RetroLook (upstream e48cdc1): the look picked on a TV on 2026-10-18, in the
# guide and in full screen alike. The flicker chance is components/GuideView.brs's.
# The tracking (drift) line is not drawn, as on the Apple TV.
SCANLINE_OPACITY = 0.18
CORNER_SHADOW = 0.78
TOP_BOTTOM_SHADOW = 0.58
SIDE_SHADOW = 0.48

def scanlines(w, h):
    # Black lines at SCANLINE_OPACITY, 1.5 wide every 3 px, centred on y = 0,
    # 3, 6...: each covers three quarters of the pixel row above and below it.
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    a = round(255 * SCANLINE_OPACITY * 0.75)
    px = img.load()
    for y in range(0, h + 1, 3):
        for row in (y - 1, y):
            if 0 <= row < h:
                for x in range(w):
                    px[x, row] = (0, 0, 0, a)
    return img


def vignette(w, h, scale=1.0):
    """VignetteLayer plus the screen-edge stroke, for a w x h screen drawn at
    `scale` (the full-screen one is drawn at half size and stretched)."""
    sw, sh = int(w * scale), int(h * scale)
    img = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    px = img.load()
    # RadialGradient [clear, clear, black CORNER_SHADOW] from min*0.3 to
    # max*0.7: clear to the midpoint, then up to it at the end radius and held
    # beyond it.
    r0 = min(w, h) * 0.3
    r1 = max(w, h) * 0.7
    mid = (r0 + r1) / 2
    band_y = h * 0.08
    band_x = w * 0.06
    cx, cy = w / 2, h / 2
    for j in range(sh):
        y = (j + 0.5) / scale
        for i in range(sw):
            x = (i + 0.5) / scale
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            radial = 0.0 if d <= mid else lerp(0, CORNER_SHADOW, (d - mid) / (r1 - mid))
            top = lerp(TOP_BOTTOM_SHADOW, 0, y / band_y) if y < band_y else 0
            bottom = lerp(0, TOP_BOTTOM_SHADOW, (y - (h - band_y)) / band_y) if y > h - band_y else 0
            left = lerp(SIDE_SHADOW, 0, x / band_x) if x < band_x else 0
            right = lerp(0, SIDE_SHADOW, (x - (w - band_x)) / band_x) if x > w - band_x else 0
            keep = 1.0
            for a in (radial, top, bottom, left, right):
                keep *= 1 - a
            px[i, j] = (0, 0, 0, round(255 * (1 - keep)))
    # RoundedRectangle(cornerRadius: 12).stroke(white 4%, lineWidth: 2).
    edge = Image.new("RGBA", (sw * 4, sh * 4), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        [0, 0, sw * 4 - 1, sh * 4 - 1], radius=int(12 * scale * 4),
        outline=(255, 255, 255, round(255 * 0.04)), width=max(1, int(1 * scale * 4)))
    img.alpha_composite(edge.resize((sw, sh), Image.LANCZOS))
    return img


# ── Outlines (ChannelGuideView.swift) ───────────────────────────────────────

def nine_patch(art, fixed):
    """Adds the 1 px nine-patch border: the middle stretches, `fixed` px stay
    at each edge."""
    w, h = art.size
    out = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    out.paste(art, (1, 1))
    d = ImageDraw.Draw(out)
    d.line([(1 + fixed, 0), (w - fixed, 0)], fill=(0, 0, 0, 255))
    d.line([(0, 1 + fixed), (0, h - fixed)], fill=(0, 0, 0, 255))
    return out


def outline(inner, radius, stroke, inset, glow_radius, glow_alpha, margin):
    """A rounded stroke `inset` into an inner x inner box with a glow
    (SwiftUI shadow) around it, white, with `margin` px outside for the glow.
    Drawn 4x and scaled down for smooth corners."""
    s = 4
    size = inner + 2 * margin
    line = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    o = (margin + inset) * s
    half = stroke * s / 2
    ImageDraw.Draw(line).rounded_rectangle(
        [o + half - s / 2, o + half - s / 2, size * s - o - half + s / 2, size * s - o - half + s / 2],
        radius=radius * s, outline=(255, 255, 255, 255), width=int(stroke * s))
    line = line.resize((size, size), Image.LANCZOS)
    # A SwiftUI shadow's radius is close to a Gaussian's 2 sigma.
    glow = line.filter(ImageFilter.GaussianBlur(glow_radius / 2))
    a = glow.getchannel("A").point(lambda v: round(v * glow_alpha))
    glow.putalpha(a)
    glow.alpha_composite(line)
    return nine_patch(glow, margin + inset + radius + stroke)


def badge():
    # Badges: 1 px white stroke, radius 4, no fill; opacity on the Poster.
    s = 4
    img = Image.new("RGBA", (24 * s, 24 * s), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([0, 0, 24 * s - 1, 24 * s - 1], radius=4 * s,
                                          outline=(255, 255, 255, 255), width=s)
    return nine_patch(img.resize((24, 24), Image.LANCZOS), 6)


def capsule(h):
    s = 4
    w = h * 2
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([0, 0, w * s - 1, h * s - 1], radius=h * s // 2,
                                          fill=(255, 255, 255, 255))
    img = img.resize((w, h), Image.LANCZOS)
    out = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    out.paste(img, (1, 1))
    d = ImageDraw.Draw(out)
    d.line([(1 + h // 2, 0), (w - h // 2, 0)], fill=(0, 0, 0, 255))
    d.point((0, 1 + h // 2), fill=(0, 0, 0, 255))
    return out


# ── Connect screens (OnboardingStyle.swift) ────────────────────────────────
# The sign-in look: a focused control is a solid slab that glows, the others
# are outlines, a text field is a well with a frame. All white, tinted on the
# TV with blendColor; translucency comes from the Poster's opacity. Each has
# `margin` px of transparent room around the shape for its glow, so the
# Poster goes at the control's place minus margin, margin bigger each way.

def nine_patch_xy(art, fixed_x, fixed_y):
    """nine_patch with its own fixed size for each axis."""
    w, h = art.size
    out = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    out.paste(art, (1, 1))
    d = ImageDraw.Draw(out)
    d.line([(1 + fixed_x, 0), (w - fixed_x, 0)], fill=(0, 0, 0, 255))
    d.line([(0, 1 + fixed_y), (0, h - fixed_y)], fill=(0, 0, 0, 255))
    return out


def onboarding_shape(w, h, radius, fill, stroke, glow_radius, glow_alpha, margin):
    """A w x h rounded rectangle (a capsule when radius is h / 2), filled or
    stroked inside its edge as SwiftUI's strokeBorder, with a shadow of
    glow_radius at glow_alpha around it. Drawn 4x and scaled down."""
    s = 4
    big_w, big_h = (w + 2 * margin) * s, (h + 2 * margin) * s
    shape = Image.new("RGBA", (big_w, big_h), (0, 0, 0, 0))
    box = [margin * s, margin * s, (margin + w) * s - 1, (margin + h) * s - 1]
    d = ImageDraw.Draw(shape)
    if fill:
        d.rounded_rectangle(box, radius=radius * s, fill=(255, 255, 255, 255))
    else:
        d.rounded_rectangle(box, radius=radius * s, outline=(255, 255, 255, 255), width=round(stroke * s))
    shape = shape.resize((w + 2 * margin, h + 2 * margin), Image.LANCZOS)
    if glow_radius:
        # A SwiftUI shadow's radius is close to a Gaussian's 2 sigma.
        glow = shape.filter(ImageFilter.GaussianBlur(glow_radius / 2))
        glow.putalpha(glow.getchannel("A").point(lambda v: round(v * glow_alpha)))
        glow.alpha_composite(shape)
        shape = glow
    return shape


def onboarding(w, h, radius, fill=False, stroke=0, glow_radius=0, glow_alpha=0, margin=0):
    art = onboarding_shape(w, h, radius, fill, stroke, glow_radius, glow_alpha, margin)
    edge = margin + radius + int(stroke + 0.99)
    if radius * 2 >= h:
        # A capsule: only its middle row stretches, so the ends stay round.
        return nine_patch_xy(art, edge, margin + h // 2)
    return nine_patch_xy(art, edge, edge)


# ── Icons ───────────────────────────────────────────────────────────────────

def bolt():
    # An 11 pt bold bolt, black 95%, for the live chip.
    s = 8
    w, h = 9, 13
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    pts = [(5.6, 0), (0.4, 7.4), (4.2, 7.4), (3.2, 13), (8.6, 5.2), (4.8, 5.2), (6.2, 0)]
    ImageDraw.Draw(img).polygon([(x * s, y * s) for x, y in pts], fill=(0, 0, 0, 242))
    return img.resize((w, h), Image.LANCZOS)


def gear():
    # A 22 px gear, white, for the sidebar's SETTINGS row.
    s = 8
    n = 22 * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = n / 2
    import math
    for k in range(8):
        a = k * math.pi / 4
        dx, dy = math.cos(a), math.sin(a)
        px, py = -dy, dx
        r0, r1, tw = 6.5 * s, 10.8 * s, 2.2 * s
        d.polygon([(c + dx * r0 + px * tw, c + dy * r0 + py * tw), (c + dx * r1 + px * tw * 0.8, c + dy * r1 + py * tw * 0.8),
                   (c + dx * r1 - px * tw * 0.8, c + dy * r1 - py * tw * 0.8), (c + dx * r0 - px * tw, c + dy * r0 - py * tw)],
                  fill=(255, 255, 255, 255))
    d.ellipse([c - 8 * s, c - 8 * s, c + 8 * s, c + 8 * s], fill=(255, 255, 255, 255))
    d.ellipse([c - 3.4 * s, c - 3.4 * s, c + 3.4 * s, c + 3.4 * s], fill=(0, 0, 0, 0))
    return img.resize((22, 22), Image.LANCZOS)


def star():
    # A five-pointed star, 16 px, white.
    import math
    s = 8
    n = 16 * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    c, r0, r1 = n / 2, n * 0.5, n * 0.2
    pts = []
    for k in range(10):
        a = -math.pi / 2 + k * math.pi / 5
        r = r0 if k % 2 == 0 else r1
        pts.append((c + r * math.cos(a), c + 0.55 * s + r * math.sin(a)))
    ImageDraw.Draw(img).polygon(pts, fill=(255, 255, 255, 255))
    return img.resize((16, 16), Image.LANCZOS)


def step_ring():
    # LibraryLoadStepRail's 28 pt circle, a 2 pt stroke inside it, white.
    s = 8
    n = 28 * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse([0, 0, n - 1, n - 1], outline=(255, 255, 255, 255), width=2 * s)
    return img.resize((28, 28), Image.LANCZOS)


def step_dot():
    # The active step's 10 pt dot, white.
    s = 8
    n = 10 * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse([0, 0, n - 1, n - 1], fill=(255, 255, 255, 255))
    return img.resize((10, 10), Image.LANCZOS)


def step_check():
    # A complete step's 12 pt bold checkmark, white, on a 14 px square.
    s = 8
    n = 14 * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    pts = [(2.2 * s, 7.4 * s), (5.6 * s, 10.6 * s), (11.8 * s, 3.4 * s)]
    ImageDraw.Draw(img).line(pts, fill=(255, 255, 255, 255), width=round(2.4 * s), joint="curve")
    return img.resize((14, 14), Image.LANCZOS)


# ── Snow (StaticScreenView.swift) and the OSD gradient ─────────────────────

def snow(seed, w=740, h=556):
    # 4 px blocks of random grey at 45%, drawn at full size so the blocks stay
    # sharp. Sixteen greys keep the file small.
    rnd = random.Random(seed)
    img = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(0, h, 4):
        for x in range(0, w, 4):
            g = rnd.randrange(16) * 17
            d.rectangle([x, y, x + 3, y + 3], fill=(g, g, g, round(255 * 0.45)))
    return img.quantize(colors=16, method=Image.Quantize.FASTOCTREE)


def osd():
    img = Image.new("RGBA", (256, 4))
    px = img.load()
    for x in range(256):
        for y in range(4):
            px[x, y] = (0, 0, 0, round(255 * lerp(0.85, 0, (x + 0.5) / 256)))
    return img


save(scanlines(740, 555), "scanlines.png")
save(scanlines(1920, 1080), "scanlines_full.png")
save(vignette(740, 555), "vignette.png")
save(vignette(1920, 1080, 0.5), "vignette_full.png")
save(outline(64, 6, 3, 2, 14, 0.7, 16), "focus.9.png")
save(outline(64, 6, 2, 2, 7, 0.3, 16), "seasonal.9.png")
save(outline(64, 6, 4, 2, 14, 0.7, 16), "seasonal_focus.9.png")
save(badge(), "badge.9.png")
save(capsule(28), "capsule.9.png")
# Connect screens: radius 14 boxes, the quiet buttons' 56 px capsules.
save(onboarding(80, 80, 14, fill=True), "ob_fill.9.png")
save(onboarding(80, 80, 14, stroke=1.5), "ob_edge.9.png")
save(onboarding(80, 80, 14, stroke=2.5), "ob_edge_primary.9.png")
save(onboarding(80, 80, 14, fill=True, glow_radius=28, glow_alpha=0.6, margin=44), "ob_slab.9.png")
save(onboarding(80, 80, 14, stroke=3, glow_radius=18, glow_alpha=0.45, margin=32), "ob_ring.9.png")
save(onboarding(80, 80, 14, stroke=4, glow_radius=26, glow_alpha=0.55, margin=44), "ob_field_ring.9.png")
save(onboarding(112, 56, 28, fill=True, glow_radius=28, glow_alpha=0.6, margin=44), "ob_pill.9.png")
save(onboarding(112, 56, 28, stroke=3, glow_radius=18, glow_alpha=0.45, margin=32), "ob_pill_ring.9.png")
save(bolt(), "bolt.png")
save(gear(), "gear.png")
save(star(), "star.png")
save(step_ring(), "step_ring.png")
save(step_dot(), "step_dot.png")
save(step_check(), "step_check.png")
for i in range(3):
    save(snow(i), "snow_%d.png" % i)
save(osd(), "osd.png")
