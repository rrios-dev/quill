# Quill — brand

A glass quill laid across a text selection: the selection is what you give Quill,
the quill is what it does with it. Drawn in layers like macOS 27's Liquid Glass
icons — an ink-blue body, the selection band with its two handles, the quill in
front with a gap around it — so it reads at 16 px and still has depth at 1024.

Everything here is generated. Do not edit an SVG or a PNG by hand: change the
geometry in `QuillBrand.swift` / `generate.py` and regenerate.

## Files

| File | Use |
|---|---|
| `app-icon.svg`, `png/app-icon-{16…1024}.png` | The app icon (dark ink body). |
| `app-icon-light.svg`, `png/app-icon-light-1024.png` | Light variant, for light documents and slides. |
| `mark.svg`, `png/mark-512.png` | The mark alone, in colour, transparent background. |
| `mark-black.svg`, `mark-white.svg`, `png/mono-512.png`, `png/mono-white-512.png` | One-ink mark, for print, embossing or a photo background. |
| `wordmark.svg`, `wordmark-white.svg` | "quill" in Geist, lowercase, tracking −0.045 em. |
| `lockup.svg`, `lockup-white.svg` | Mark + wordmark, transparent. |
| `lockup-on-dark.svg`, `lockup-on-light.svg` | Mark + wordmark on their own background. |
| `favicon.svg`, `web/` | Favicons (SVG, 32 px PNG, `.ico` 16/32/48), `apple-touch-icon.png` (180 px, full bleed) and `og-image.png` (1200×630). |
| `png/og-image-es.png`, `png/og-image-en.png` | Share images in each language. |
| `icon-composer/1…4-*.svg` | The icon's layers, for Apple's Icon Composer if the icon ever moves to an `.icon` file. |

Not kept here, rendered at build time from the same geometry:

- `AppIcon.icns` — `Scripts/make-app.sh` runs `QuillBrand.swift icns`.
- The installer window's background — `Scripts/make-dmg.sh` runs `QuillBrand.swift dmg`.
- The menu bar mark — `apps/Quill/Menu/BrandMark.swift`, a template image drawn in
  code (the barbs and notches are dropped at 18 pt; the silhouette is what reads).

## Rules

- The mark is never recoloured, rotated, outlined or set on a busy image; on a
  photo use the one-ink mark.
- The wordmark is always lowercase and always Geist. No other typeface.
- Keep clear space of at least the wordmark's x-height around the lockup.
- The selection blue (`#2F6BFF` → `#6FA2FF`) belongs to the selection; the ink
  (`#2C2F9E` → `#0B0A2E`) to the body. Do not swap them.

## Regenerate

```bash
native/quill/assets/brand/make-brand.sh
```

It needs `python3` with `fontTools` and Geist-Regular.ttf, which it finds inside
Next.js's `@vercel/og` in the main checkout (pass its path as the first argument
otherwise).

Geist is © Vercel, under the SIL Open Font License 1.1: the wordmark outlines are
converted to paths, so the font itself is not redistributed.
