#!/usr/bin/env python3
"""Husora · App-Icons und Splash aus assets/logo.png erzeugen (Android, iOS, Web).
Aufruf: python3 tools/generate-icons.py   (benötigt Pillow)
Hinweis: logo.png ist 240 px breit – für die Store-Version ein Vektor-/1024-px-Logo nachreichen und erneut ausführen."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BG = (32, 58, 51)          # --ink #203a33 (Husora-Grün)
logo = Image.open(ROOT / 'assets/logo.png').convert('RGBA')
logo = logo.crop(logo.getbbox())

def place(size, scale, bg=BG, alpha=False):
    canvas = Image.new('RGBA', size, (0, 0, 0, 0) if alpha else bg + (255,))
    w = int(min(size) * scale)
    h = int(w * logo.height / logo.width)
    mark = logo.resize((w, h), Image.LANCZOS)
    canvas.alpha_composite(mark, ((size[0] - w) // 2, (size[1] - h) // 2))
    return canvas

def save(img, path, rgb=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    (img.convert('RGB') if rgb else img).save(path, optimize=True)

res = ROOT / 'android/app/src/main/res'
for d, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
    icon = place((px, px), 0.72)
    save(icon, res / f'mipmap-{d}/ic_launcher.png')
    mask = Image.new('L', (px, px), 0); ImageDraw.Draw(mask).ellipse((0, 0, px - 1, px - 1), fill=255)
    rnd = Image.new('RGBA', (px, px), (0, 0, 0, 0)); rnd.paste(icon, (0, 0), mask)
    save(rnd, res / f'mipmap-{d}/ic_launcher_round.png')
for d, px in {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}.items():
    save(place((px, px), 0.50, alpha=True), res / f'mipmap-{d}/ic_launcher_foreground.png')
for f in res.glob('drawable*/splash.png'):
    w, h = Image.open(f).size
    save(place((w, h), 0.32), f, rgb=True)
(res / 'values/ic_launcher_background.xml').write_text('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#203A33</color>\n</resources>\n')

ios = ROOT / 'ios/App/App/Assets.xcassets'
save(place((1024, 1024), 0.70), ios / 'AppIcon.appiconset/AppIcon-512@2x.png', rgb=True)   # App Store: ohne Alphakanal
for f in (ios / 'Splash.imageset').glob('*.png'):
    save(place((2732, 2732), 0.22), f, rgb=True)

web = ROOT / 'assets/icons'
for name, px in {'icon-192.png': 192, 'icon-512.png': 512, 'apple-touch-icon.png': 180, 'favicon-32.png': 32}.items():
    save(place((px, px), 0.72), web / name, rgb=True)
save(place((512, 512), 0.50), web / 'icon-maskable-512.png', rgb=True)
print('Icons und Splash erzeugt.')
