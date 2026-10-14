# Icons

The app icon uses the owner-approved elder sign treatment: the glyph from the
Arkham Horror LCG fan icon font rendered as a filled vector path, centered, with
its bounding box filling 64% of a 1024px canvas. Light icons use ink
`rgb(20,18,15)` on the Telephone-booth parchment background
`rgb(232,213,183)`. Dark iOS appearance uses a white glyph over that same
background darkened with `magick -modulate 22`. Tinted iOS appearance is a white
glyph on black for the system to recolor.

Run the deterministic renderer on macOS from the repository root (the Swift
renderer imports AppKit/CoreText):

```bash
./Icons/make-icon.sh <path-to-arkham.ttf>
# Example, when this repo sits beside the backend checkout:
./Icons/make-icon.sh ../ArkhamHorror/frontend/public/fonts/arkham.ttf
```

`AppIcon-background.png` is copied from the Telephone-booth app-icon background
(`Telephone-Booth-Operator-Mobile/Icons/AppIcon-background.png`).
`render-elder-sign.swift` reads the `X` (U+0058) glyph from the AHLCG
PostScript font via `CTFontCreatePathForGlyph`; the font itself is not vendored.
The generated source files (`AppIcon-foreground.png`, `AppIcon-foreground.svg`,
`AppIcon-composite.png`, `AppIcon-dark.png`, and `AppIcon-tinted.png`) are
committed alongside the target asset catalogs so the artwork is reviewable
without rerunning the generator. PNG output is byte-stable for a fixed Swift and
ImageMagick toolchain; `make-icon.sh` strips ImageMagick date/time chunks from
PNG files.

## Appearances

- **iOS / iPadOS** ship light, dark, and tinted app-icon appearances
  (`AppIcon.appiconset` references all three 1024px renders via the
  `luminosity` appearance keys).
- **visionOS** uses a layered icon that the system renders adaptively, so it
  has no separate dark/tinted files.
- **macOS and tvOS** asset-catalog icons do not support per-appearance
  variants; they use the single flat (macOS) or layered/banner (tvOS) art.

## Licensing caveat

The elder sign glyph comes from the AH LCG fan icon font (Fantasy Flight Games
iconography), which has no explicit licence. It is used here for personal and
fan builds, including internal TestFlight and self-built packages; the same font
is already published by the upstream ArkhamHorror web app. It **must be replaced
with original artwork before any public store listing (App Store, Flathub,
etc.)**.
