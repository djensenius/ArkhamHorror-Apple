# Icons

The app icon uses the owner-approved elder sign treatment: the glyph from the
Arkham Horror LCG fan icon font rendered as a filled vector path, centered, with
its bounding box filling 64% of a 1024px canvas. Light icons use ink
`rgb(20,18,15)` on the Telephone-booth parchment background
`rgb(232,213,183)`. Dark iOS appearance uses a white glyph over that same
background darkened with `magick -modulate 22`. Tinted iOS appearance is a white
glyph on black for the system to recolor.

Run the deterministic renderer from the repository root:

```bash
./Icons/make-icon.sh /Users/david/Developer/ArkhamHorror/ArkhamHorror/frontend/public/fonts/arkham.ttf
```

`AppIcon-background.png` is copied from
`/Users/david/Developer/Art/Telephone-booth/Telephone-Booth-Operator-Mobile/Icons/AppIcon-background.png`.
`render-elder-sign.swift` reads the `X` (U+0058) glyph from the AHLCG
PostScript font via `CTFontCreatePathForGlyph`; the font itself is not vendored.
The generated source files (`AppIcon-foreground.png`, `AppIcon-foreground.svg`,
`AppIcon-composite.png`, `AppIcon-dark.png`, and `AppIcon-tinted.png`) are
committed alongside the target asset catalogs so the artwork is reviewable
without rerunning the generator.

## Licensing caveat

The elder sign glyph comes from the unlicensed "AH LCG" fan icon font and uses
Fantasy Flight Games iconography. It is acceptable here for personal/internal
TestFlight builds, but it **must be replaced with original art before any App
Store submission**.
