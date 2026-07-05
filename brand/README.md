# Haynoi Brand Assets

Canonical brand sources. Everything raster (app icon, favicon, og-image)
is generated from here — never hand-edit the PNGs.

## Files

| File | Use |
|---|---|
| `haynoi-icon.svg` | App icon master: obsidian squircle + ń mark. Source for all PNGs. |
| `haynoi-glyph.svg` | ń mark alone, transparent background, cyan gradient. For UI, docs, video. |
| `haynoi-glyph-black.svg` | ń mark, solid black. Light backgrounds / print. |
| `haynoi-glyph-white.svg` | ń mark, solid white. Dark backgrounds. |
| `haynoi-wordmark.svg` | "haynoi" wordmark. |
| `make-icons.sh` | Regenerates `Resources/Assets.xcassets/AppIcon.appiconset/*.png` + `site/icon.png`. |

## The mark

Lowercase geometric **ń** — "n" with dấu sắc (Vietnamese acute tone mark).
One continuous stroke, instrument-grade geometry, near-square terminals.

## Colors

| Token | Hex | Use |
|---|---|---|
| Signal Cyan (top) | `#38E8D0` | Glyph gradient start |
| Deep Teal (bottom) | `#0D9E9C` | Glyph gradient end |
| Dấu Sắc Cyan | `#38E1C6` | Accent stroke |
| Obsidian (center) | `#131829` | Icon background gradient start |
| Obsidian (edge) | `#080A14` | Icon background gradient end |
| Quiet Paper | `#F7F4EE` | Site light background |

## Rules

- Don't stretch, recolor, or rotate the mark. Dấu sắc angle is fixed at 60°.
- On photos or busy backgrounds use the black/white glyph, not the gradient.
- Regenerate after any SVG change: `./brand/make-icons.sh` (needs `brew install librsvg`).
- Full design exploration history lives in `redesign/brand/`.
