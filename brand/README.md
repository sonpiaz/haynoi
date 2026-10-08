# Haynoi Brand Assets

Every icon is drawn by one script from one geometry — never hand-edit the PNGs.

```
python3 brand/make-icons.py             # app icon, menu bar, site, this kit (needs Pillow)
python3 brand/make-icons.py --compare   # the 5-variant compare set
```

## The mark

Lowercase geometric **ń** — "n" with dấu sắc (Vietnamese acute tone mark), one flat
colour on a solid rounded tile (macOS grid: 824/1024, radius 22.5%). The mark takes
62% of the tile height, 70% at 32 px and below.

## Files

| File | Use |
|---|---|
| `make-icons.py` | Source of every icon below, the app icon set, menu bar icon and site icons. |
| `haynoi-icon.svg` · `haynoi-icon-1024.png` | App icon master, vector and raster. |
| `Haynoi.icns` | macOS icon file (also usable as a DMG volume icon). |
| `haynoi-glyph.svg` | ń mark alone, cyan. |
| `haynoi-glyph-black.svg` · `haynoi-glyph-white.svg` · `haynoi-mark-{black,white}.png` | Monochrome mark. |
| `favicon.svg` · `favicon.ico` · `apple-touch-icon.png` | Site favicons (mirrored into `site/`). |
| `icon-192.png` · `icon-512.png` · `icon-maskable-512.png` | PWA / web manifest. |
| `og-1200x630.png` | Link preview (mirrored to `site/og.png`). |
| `lockup-horizontal-{dark,light}.png` | Mark + "Haynoi" wordmark. |
| `avatar-400.png` | Social avatar (safe in a circle crop). |

## Colors (Obsidian, default since 2026-10-08)

| Token | Hex | Use |
|---|---|---|
| Obsidian | `#0B0D1A` | Tile |
| Signal Cyan | `#38E8D0` | Mark |
| Paper | `#F2F0EA` | Wordmark on dark |

Other variants (Signal, Paper, Graphite, Lotus) live in `VARIANTS` in the script.

## Rules

- Don't stretch, recolor, or rotate the mark. Dấu sắc angle is fixed at 60°.
- Menu bar (idle) uses the black template mark; recording/transcribing/error keep their SF Symbols.
- On photos or busy backgrounds use the black/white mark.
