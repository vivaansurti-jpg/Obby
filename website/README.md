# Obby landing page

A dependency-free static website. Serve `dist/` with any static web server.

## Finish the release details

- The download button is configured for the latest Obby release: `https://github.com/vivaansurti-jpg/Obby/releases/latest/download/Obby.dmg`. Publish a release with an asset named exactly `Obby.dmg` for it to resolve.
- The supplied Obby logo is stored unchanged in `dist/obby-icon.png` and used throughout the page and as the favicon.
- Replace the `.placeholder` element inside `.video-slot` in `dist/index.html` with `<video src="/demo.mp4" controls playsinline preload="metadata" aria-label="Obby demo"></video>` and place `demo.mp4` in `dist/`. No autoplay is configured.

All styling lives in `dist/styles.css`. Scroll reveals use IntersectionObserver, with reduced-motion and no-JavaScript fallbacks.

## Discovery files

`dist/robots.txt`, `dist/sitemap.xml`, and `dist/llms.txt` provide crawl and machine-readable discovery information for the published site. The homepage also includes canonical, social, and SoftwareApplication structured metadata.
