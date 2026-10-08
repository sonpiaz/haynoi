#!/usr/bin/env python3
"""Every Haynoi icon, drawn from one geometry: the ń mark on a solid tile.

    python3 brand/make-icons.py            # write app icon, menu bar, site, brand kit
    python3 brand/make-icons.py --compare  # write the 5-variant compare set only

The mark is the path from haynoi-glyph.svg (512 units). The accent is drawn
wider than the old 13 units so it survives at 16 px.
"""
import math, os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SS = 4  # supersample

VARIANTS = {  # name: (tile, mark)
    'obsidian': ((0x0B, 0x0D, 0x1A), (0x38, 0xE8, 0xD0)),
    'signal':   ((0x2E, 0xD8, 0xC3), (0x0B, 0x0D, 0x1A)),
    'paper':    ((0xF2, 0xF0, 0xEA), (0x0B, 0x0D, 0x1A)),
    'graphite': ((0x16, 0x18, 0x1C), (0xF2, 0xF0, 0xEA)),
    'lotus':    ((0xF2, 0xB4, 0xC1), (0x2A, 0x10, 0x1C)),
}
DEFAULT = 'obsidian'

# ń, one closed path in 512 units (haynoi-glyph.svg).
N_PATH = [('M', (158, 370)), ('Q', (158, 378), (166, 378)), ('Q', (212, 378), (212, 370)),
          ('L', (212, 188)), ('C', (234, 200), (278, 200), (300, 194)), ('L', (300, 370)),
          ('Q', (300, 378), (308, 378)), ('Q', (354, 378), (354, 370)), ('L', (354, 210)),
          ('C', (303, 122), (205, 122), (158, 158))]
N_SVG = ('M158 370Q158 378 166 378Q212 378 212 370L212 188C234 200 278 200 300 194L300 370'
         'Q300 378 308 378Q354 378 354 370L354 210C303 122 205 122 158 158Z')
# Dấu sắc: a bar centred on (344, 98), rotated 60°, 20 wide x 62 long.
ACC_C, ACC_W, ACC_L, ACC_ROT = (344, 98), 20, 62, 60
ACC_SVG = (f'<rect x="{ACC_C[0] - ACC_W / 2:g}" y="{ACC_C[1] - ACC_L / 2:g}" width="{ACC_W}" '
           f'height="{ACC_L}" rx="3" transform="rotate({ACC_ROT} {ACC_C[0]} {ACC_C[1]})"/>')


def _flatten():
    pts, cur = [], None
    for seg in N_PATH:
        op, *p = seg
        if op in 'ML':
            cur = p[0]; pts.append(cur); continue
        ctrl = [cur] + p
        for i in range(1, 25):
            t = i / 24
            if op == 'Q':
                (a, b, c) = ctrl
                x = (1 - t) ** 2 * a[0] + 2 * (1 - t) * t * b[0] + t * t * c[0]
                y = (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * b[1] + t * t * c[1]
            else:
                (a, b, c, d) = ctrl
                x = (1-t)**3*a[0] + 3*(1-t)**2*t*b[0] + 3*(1-t)*t*t*c[0] + t**3*d[0]
                y = (1-t)**3*a[1] + 3*(1-t)**2*t*b[1] + 3*(1-t)*t*t*c[1] + t**3*d[1]
            pts.append((x, y))
        cur = p[-1]
    return pts


def _accent():
    r = math.radians(ACC_ROT); c, s = math.cos(r), math.sin(r)
    out = []
    for dx, dy in ((-ACC_W / 2, -ACC_L / 2), (ACC_W / 2, -ACC_L / 2), (ACC_W / 2, ACC_L / 2), (-ACC_W / 2, ACC_L / 2)):
        out.append((ACC_C[0] + dx * c - dy * s, ACC_C[1] + dx * s + dy * c))
    return out


N_PTS, ACC_PTS = _flatten(), _accent()
_all = N_PTS + ACC_PTS
BBOX = (min(p[0] for p in _all), min(p[1] for p in _all), max(p[0] for p in _all), max(p[1] for p in _all))
MARK_W, MARK_H = BBOX[2] - BBOX[0], BBOX[3] - BBOX[1]
MARK_CX, MARK_CY = (BBOX[0] + BBOX[2]) / 2, (BBOX[1] + BBOX[3]) / 2


def mark_layer(size, H, color, cx=None, cy=None):
    """The mark, height H px, centred on (cx, cy) of a size x size transparent canvas."""
    S = size * SS; k = H * SS / MARK_H
    ox = (size / 2 if cx is None else cx) * SS; oy = (size / 2 if cy is None else cy) * SS
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    tr = lambda p: (ox + (p[0] - MARK_CX) * k, oy + (p[1] - MARK_CY) * k)
    d.polygon([tr(p) for p in N_PTS], fill=color)
    d.polygon([tr(p) for p in ACC_PTS], fill=color)
    return im.resize((size, size), Image.LANCZOS)


def rounded_tile(size, inset, radius_frac, color):
    S = size * SS; im = Image.new('RGBA', (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    a = inset * SS; w = S - 2 * a
    d.rounded_rectangle([a, a, S - a, S - a], radius=w * radius_frac, fill=color + (255,))
    return im.resize((size, size), Image.LANCZOS)


def mark_ratio(size):
    return 0.70 if size <= 32 else 0.62  # mark height / tile; small sizes get a bigger mark


def app_icon(size, bg, fg):
    """macOS grid: 824/1024 tile, radius 22.5%, soft drop shadow at >= 128 px."""
    inset = size * 0.04 if size <= 32 else size * 100 / 1024
    tile_w = size - 2 * inset
    c = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    if size >= 128:
        sh = rounded_tile(size, inset, 0.225, (0, 0, 0))
        sh.putalpha(sh.split()[3].point(lambda v: int(v * 0.30)))
        sh = sh.filter(ImageFilter.GaussianBlur(size * 10 / 1024))
        c.alpha_composite(sh, (0, int(size * 10 / 1024)))
    c.alpha_composite(rounded_tile(size, inset, 0.225, bg))
    if size >= 64 and sum(bg) < 200:  # faint edge so dark tiles do not vanish on a dark Dock
        S2 = size * SS; e = Image.new('RGBA', (S2, S2), (0, 0, 0, 0)); a = inset * SS
        ImageDraw.Draw(e).rounded_rectangle([a, a, S2 - a, S2 - a], radius=(S2 - 2 * a) * 0.225,
                                            outline=(255, 255, 255, 30), width=max(SS, int(size * 2 / 1024 * SS)))
        c.alpha_composite(e.resize((size, size), Image.LANCZOS))
    c.alpha_composite(mark_layer(size, tile_w * mark_ratio(size), fg + (255,)))
    return c


def flat_tile(size, bg, fg, radius=0.225, ratio=None):
    c = rounded_tile(size, 0, radius, bg)
    c.alpha_composite(mark_layer(size, size * (ratio or mark_ratio(size)), fg + (255,)))
    return c


def square(size, bg, fg, ratio):
    c = Image.new('RGBA', (size, size), bg + (255,))
    c.alpha_composite(mark_layer(size, size * ratio, fg + (255,)))
    return c


# ---------- SVG ----------
def hexc(c): return '#%02X%02X%02X' % c


def svg(w, h, inner, title='Haynoi'):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" width="{w:g}" height="{h:g}" '
            f'role="img" aria-label="{title}"><title>{title}</title>{inner}</svg>\n')


def placed(cx, cy, H, fill):
    k = H / MARK_H
    return (f'<g fill="{fill}" transform="translate({cx:g} {cy:g}) scale({k:.5f}) '
            f'translate({-MARK_CX:.2f} {-MARK_CY:.2f})"><path d="{N_SVG}"/>{ACC_SVG}</g>')


def tile_svg(bg, fg, ratio):
    s = 1024
    return svg(s, s, f'<rect width="{s}" height="{s}" rx="{s * 0.225:g}" fill="{hexc(bg)}"/>' + placed(s / 2, s / 2, s * ratio, hexc(fg)))


def mark_svg(fill):
    w, h = MARK_W + 8, MARK_H + 8
    return svg(round(w), round(h), placed(w / 2, h / 2, MARK_H, fill))


# ---------- brand kit ----------
FONT = '/System/Library/Fonts/SFNS.ttf'
INK_ON_DARK, MUTED = (0xF2, 0xF0, 0xEA), (0x8E, 0x93, 0xA8)
TAGLINE = 'Hold a key. Speak. Done.'          # site/index.html <title>


def font(px, weight='Medium'):
    f = ImageFont.truetype(FONT, int(round(px)))
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f


def put_mark(img, cx, cy, H, color):
    side = int(H * 1.2) | 1
    img.alpha_composite(mark_layer(side, H, color + (255,)), (int(round(cx - side / 2)), int(round(cy - side / 2))))


def og(bg, fg):
    W, H = 1200, 630
    img = Image.new('RGBA', (W, H), bg + (255,))
    put_mark(img, 330, 315, 300, fg)
    d = ImageDraw.Draw(img)
    d.text((540, 330), 'Haynoi', font=font(140), fill=INK_ON_DARK + (255,), anchor='ls')
    d.line([(544, 372), (608, 372)], fill=fg + (255,), width=3)
    d.text((542, 440), TAGLINE, font=font(40, 'Regular'), fill=MUTED + (255,), anchor='ls')
    return img.convert('RGB')


def lockup(dark, bg, fg):
    M = 240.0; pad = 0.25 * M; gap = 0.30 * M
    mark_c = fg if dark else bg
    word_c = INK_ON_DARK if dark else bg
    f = font(0.62 * M)
    l, t, r, b = f.getbbox('Haynoi', anchor='ls')
    mw = M * MARK_W / MARK_H
    W, Hh = int(round(pad + mw + gap + (r - l) + pad)), int(round(pad + M + pad))
    img = Image.new('RGBA', (W, Hh), (0, 0, 0, 0))
    put_mark(img, pad + mw / 2, Hh / 2, M, mark_c)
    ty = Hh / 2 + (-t) / 2
    ImageDraw.Draw(img).text((pad + mw + gap - l, ty), 'Haynoi', font=f, fill=word_c + (255,), anchor='ls')
    return img


def icns(dest, bg, fg):
    tmp = tempfile.mkdtemp(); iset = os.path.join(tmp, 'Haynoi.iconset'); os.makedirs(iset)
    for base in (16, 32, 128, 256, 512):
        app_icon(base, bg, fg).save(os.path.join(iset, f'icon_{base}x{base}.png'))
        app_icon(base * 2, bg, fg).save(os.path.join(iset, f'icon_{base}x{base}@2x.png'))
    subprocess.run(['iconutil', '-c', 'icns', iset, '-o', dest], check=True)
    shutil.rmtree(tmp)


def write(p, text):
    with open(p, 'w') as f: f.write(text)


def ship(name=DEFAULT):
    bg, fg = VARIANTS[name]
    # App icon (filenames as in Contents.json)
    mac = os.path.join(ROOT, 'Resources/Assets.xcassets/AppIcon.appiconset')
    for s in (16, 32, 64, 128, 256, 512, 1024):
        app_icon(s, bg, fg).save(os.path.join(mac, f'icon_{s}x{s}.png'))
    # Menu bar, idle state: black template, macOS tints it
    menu = os.path.join(ROOT, 'Resources/Assets.xcassets/MenuBarIcon.imageset')
    for s, n in ((16, 'menubar_16'), (32, 'menubar_32')):
        mark_layer(s, s * 0.88, (0, 0, 0, 255)).save(os.path.join(menu, n + '.png'))
    # Brand kit
    kit = os.path.join(ROOT, 'brand')
    write(os.path.join(kit, 'haynoi-icon.svg'), tile_svg(bg, fg, 0.62))
    write(os.path.join(kit, 'haynoi-glyph.svg'), mark_svg(hexc(fg)))
    write(os.path.join(kit, 'haynoi-glyph-black.svg'), mark_svg('#000000'))
    write(os.path.join(kit, 'haynoi-glyph-white.svg'), mark_svg('#FFFFFF'))
    write(os.path.join(kit, 'favicon.svg'), tile_svg(bg, fg, 0.70))
    fav = {s: flat_tile(s, bg, fg, 0.22) for s in (16, 32, 48)}
    fav[48].save(os.path.join(kit, 'favicon.ico'), sizes=[(16, 16), (32, 32), (48, 48)], append_images=[fav[16], fav[32]])
    app_icon(1024, bg, fg).save(os.path.join(kit, 'haynoi-icon-1024.png'))
    flat_tile(512, bg, fg).save(os.path.join(kit, 'icon-512.png'))
    flat_tile(192, bg, fg).save(os.path.join(kit, 'icon-192.png'))
    square(512, bg, fg, 0.50).save(os.path.join(kit, 'icon-maskable-512.png'))
    square(180, bg, fg, 0.58).convert('RGB').save(os.path.join(kit, 'apple-touch-icon.png'))
    square(400, bg, fg, 0.52).convert('RGB').save(os.path.join(kit, 'avatar-400.png'))
    og(bg, fg).save(os.path.join(kit, 'og-1200x630.png'))
    for dark in (True, False):
        lockup(dark, bg, fg).save(os.path.join(kit, f'lockup-horizontal-{"dark" if dark else "light"}.png'))
    for n, c in (('white', (255, 255, 255)), ('black', (0, 0, 0))):
        mark_layer(1024, 1024 * 0.86, c + (255,)).save(os.path.join(kit, f'haynoi-mark-{n}.png'))
    icns(os.path.join(kit, 'Haynoi.icns'), bg, fg)
    # Site: the paths its pages already reference, plus favicons
    site = os.path.join(ROOT, 'site')
    flat_tile(512, bg, fg).save(os.path.join(site, 'icon.png'))
    shutil.copyfile(os.path.join(kit, 'og-1200x630.png'), os.path.join(site, 'og.png'))
    for n in ('favicon.svg', 'favicon.ico', 'apple-touch-icon.png'):
        shutil.copyfile(os.path.join(kit, n), os.path.join(site, n))
    print('ok', name)


def compare(out):
    os.makedirs(out, exist_ok=True)
    for name, (bg, fg) in VARIANTS.items():
        for s in (16, 32, 64, 128, 512):
            app_icon(s, bg, fg).save(os.path.join(out, f'appicon-{name}-{s}.png'))
        flat_tile(32, bg, fg, 0.22).save(os.path.join(out, f'favicon-{name}-32.png'))
        flat_tile(16, bg, fg, 0.22).save(os.path.join(out, f'favicon-{name}-16.png'))
    for s in (16, 32):
        mark_layer(s, s * 0.88, (0, 0, 0, 255)).save(os.path.join(out, f'menubar-{s}.png'))
    print('compare ->', out)


if __name__ == '__main__':
    if '--compare' in sys.argv:
        compare(sys.argv[sys.argv.index('--compare') + 1] if len(sys.argv) > 2 else os.path.join(ROOT, '.internal/design/2026-10-08-icon/proposal'))
    else:
        ship(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
