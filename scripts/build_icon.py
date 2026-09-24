"""Crop the supplied artwork without altering its interior; package macOS icons."""
from pathlib import Path
from PIL import Image, ImageFilter
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = Image.open(root / 'Resources/Obby.png').convert('RGB')
# The warm ivory tile is distinct from the neutral gray presentation backdrop.
# Crop along its original silhouette, rather than drawing a new rounded square.
mask = Image.new('L', source.size)
pixels = mask.load()
for y in range(270, 980):
    tile = [x for x in range(270, 980)
            if source.getpixel((x, y))[0] > 230
            and source.getpixel((x, y))[0] - source.getpixel((x, y))[1] > 3]
    if tile:
        for x in range(min(tile), max(tile) + 1):
            pixels[x, y] = 255
art = source.convert('RGBA')
art.putalpha(mask.filter(ImageFilter.GaussianBlur(0.45)))
art = art.crop(mask.getbbox())
# Standard transparent macOS icon margin. No additional artwork or treatment.
canvas = Image.new('RGBA', (1024, 1024))
art.thumbnail((824, 824), Image.Resampling.LANCZOS)
# thumbnail does not enlarge; explicitly resize the square artwork proportionally.
scale = 824 / max(art.size)
art = art.resize((round(art.width * scale), round(art.height * scale)), Image.Resampling.LANCZOS)
canvas.alpha_composite(art, ((1024-art.width)//2, (1024-art.height)//2))
assets = root / 'Resources/Assets.xcassets'
appicon = assets / 'AppIcon.appiconset'
appicon.mkdir(parents=True, exist_ok=True)
(assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        filename = f'icon_{size}x{size}@{scale}x.png'
        path = appicon / filename
        canvas.resize((size*scale, size*scale), Image.Resampling.LANCZOS).save(path)
        images.append({'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': filename})
(appicon / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
# Use Apple's native compiler and replace the existing icon only on success.
with tempfile.TemporaryDirectory(prefix="obby-icon-") as temp:
    iconset = Path(temp) / 'AppIcon.iconset'
    iconset.mkdir()
    for image in appicon.glob('*.png'):
        shutil.copyfile(image, iconset / image.name.replace('@1x', ''))
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(Path(temp) / 'AppIcon.icns')], check=True)
    shutil.copyfile(Path(temp) / 'AppIcon.icns', root / 'Resources/AppIcon.icns')
print('Generated all 10 macOS AppIcon sizes and Apple-compiled AppIcon.icns')
