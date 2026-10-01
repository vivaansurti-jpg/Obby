# Obby website

A fresh, dependency-free HTML/CSS website. `dist/` is both the editable source and the production artifact. No framework, package installation, JavaScript runtime or compilation is required.

## Run locally

From the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website/dist
```

Open http://127.0.0.1:4173. All asset paths are relative so the site also works under `/Obby/` on GitHub Pages.

## Production

No build step: deploy `website/dist/` directly. The existing `.github/workflows/deploy-pages.yml` publishes that directory to GitHub Pages. `website/.openai/hosting.json` retains the existing Sites project ID and static directory. Do not upload this README or configuration as public site content.

The canonical URL remains https://vivaansurti-jpg.github.io/Obby/ from the original site. If the canonical host changes, update index.html, robots.txt, llms.txt and sitemap.xml together.

## Assets and placeholders

- `dist/reaching-hands-enhanced.jpg` is the user-supplied enhanced artwork (1068 × 664), copied without re-encoding. It replaces the original image in both the hero and closing section. The aspect ratio and CSS composition are unchanged; the new filename avoids stale cached artwork.
- `dist/obby-icon.png` is the preserved original favicon and social image. `dist/obby-icon-transparent.png` is copied from the native app’s transparent icon asset for the hero and navigation.
- `dist/obby-main-retina.png` is a genuine 2400 × 1520 native Retina capture of the running Obby app with temporary sample notes, used in the introduction and main product figure. The capture API returns JPEG; it was decoded to PNG without resizing or further lossy encoding. A direct lossless macOS PNG capture can replace it at the same dimensions. Both instances are normal images, capped at 700 CSS pixels (3.43× source density), with automatic height and contain sizing. No blur, sharpening, filters, or CSS enlargement. The original notes folder was restored after capture.
- Two supporting screenshot placeholders remain in index.html: main window, notes editor, AI & memory. Replace each `.screenshot-placeholder` with an `<img src="..." alt="..." width="..." height="..." loading="lazy">` showing the actual application. Put image files in dist and remove placeholder wording from captions. Do not add browser chrome.
- The report button is disabled, accompanied by “Report link coming soon.” Supply the actual report PDF or URL; replace the disabled button with an anchor and remove the status. The adjacent GitHub link intentionally points to the real source repository, not an invented report path.
- Download buttons use the existing latest-release URL ending in `Obby.dmg`. No placeholder download URL is used. A GitHub release must contain that exact asset name.

## Discovery and accessibility

`robots.txt` allows indexing. `sitemap.xml` contains only the canonical homepage; section anchors are not separate routes. `llms.txt` is a factual overview, including the unavailable report status. The page contains canonical, Open Graph, Twitter and SoftwareApplication metadata.

Semantic landmarks, a skip link, visible focus styles, descriptive links, decorative artwork treatment and reduced-motion CSS are included. All navigation works without JavaScript. No analytics, remote fonts, runtime scripts or frontend dependencies. The hero uses an 85vh desktop composition, compact copy, side-by-side CTAs and an outlined GitHub button.

## Replaced implementation

The previous index.html and styles.css were deleted and rebuilt. The old script.js, its runtime link assignment and scroll reveal system, old comparison table, feature strip and demo browser frame were removed. robots.txt, llms.txt and sitemap.xml were recreated for the new single page. The icon and deployment configuration were retained.
