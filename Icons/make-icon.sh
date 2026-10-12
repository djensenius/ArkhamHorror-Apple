#!/usr/bin/env bash
#
# Render the AH LCG elder-sign glyph into Apple app-icon assets for every
# platform target. The font path is an input so the unlicensed fan font is not
# vendored into this repository.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS="$ROOT/Icons"
FONT_PATH="${1:-}"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"

if [[ -z "$FONT_PATH" ]]; then
  echo "usage: $0 /path/to/arkham.ttf" >&2
  exit 2
fi
if [[ ! -f "$FONT_PATH" ]]; then
  echo "missing font: $FONT_PATH" >&2
  exit 1
fi
if [[ ! -x "$MAGICK" ]]; then
  if command -v magick >/dev/null 2>&1; then
    MAGICK="$(command -v magick)"
  else
    echo "magick not found — install ImageMagick or set MAGICK" >&2
    exit 1
  fi
fi
if [[ ! -f "$ICONS/AppIcon-background.png" ]]; then
  echo "missing $ICONS/AppIcon-background.png" >&2
  exit 1
fi

mkdir -p "$ICONS"
"$ICONS/render-elder-sign.swift" --font "$FONT_PATH" --output-dir "$ICONS"

BACKGROUND="$ICONS/AppIcon-background.png"
FOREGROUND="$ICONS/AppIcon-foreground.png"
COMPOSITE="$ICONS/AppIcon-composite.png"
DARK_COMPOSITE="$ICONS/AppIcon-dark.png"
TINTED_COMPOSITE="$ICONS/AppIcon-tinted.png"
FG_WHITE="$ICONS/.AppIcon-fg-white.png"
BG_DARK="$ICONS/.AppIcon-bg-dark.png"

"$MAGICK" "$BACKGROUND" "$FOREGROUND" -compose over -composite -depth 8 "$COMPOSITE"
"$MAGICK" "$FOREGROUND" -fill white -colorize 100% -depth 8 "$FG_WHITE"
"$MAGICK" "$BACKGROUND" -modulate 22 -depth 8 "$BG_DARK"
"$MAGICK" "$BG_DARK" "$FG_WHITE" -compose over -composite -depth 8 "$DARK_COMPOSITE"
"$MAGICK" -size 1024x1024 xc:black "$FG_WHITE" -compose over -composite -colorspace sRGB -depth 8 "$TINTED_COMPOSITE"
rm -f "$FG_WHITE" "$BG_DARK"

write_json() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "$file"
}

write_asset_catalog_root() {
  write_json "$1/Contents.json" '{
  "info" : { "author" : "xcode", "version" : 1 }
}'
}

render_square() {
  local out="$1" size="$2" source="${3:-$COMPOSITE}"
  mkdir -p "$(dirname "$out")"
  "$MAGICK" "$source" -resize "${size}x${size}!" -depth 8 "$out"
  echo "  ${size}x${size} -> ${out#$ROOT/}"
}

render_layer() {
  local source="$1" out="$2" width="$3" height="$4" mode="${5:-contain}"
  mkdir -p "$(dirname "$out")"
  if [[ "$mode" == "cover" ]]; then
    "$MAGICK" "$source" -resize "${width}x${height}^" -gravity center -extent "${width}x${height}" -depth 8 "$out"
  else
    "$MAGICK" -size "${width}x${height}" xc:none \
      "$source" -resize "${width}x${height}" -gravity center -compose over -composite \
      -depth 8 "$out"
  fi
}

render_tv_composite() {
  local out="$1" width="$2" height="$3"
  mkdir -p "$(dirname "$out")"
  "$MAGICK" "$COMPOSITE" -resize "${width}x${height}^" -gravity center -extent "${width}x${height}" -depth 8 "$out"
}

# iOS / iPadOS app icon: light, dark, and tinted appearances (iOS 18+).
IOS_ASSETS="$ROOT/Sources/Platforms/iOS/Assets.xcassets"
IOS_SET="$IOS_ASSETS/AppIcon.appiconset"
rm -rf "$IOS_ASSETS"
write_asset_catalog_root "$IOS_ASSETS"
render_square "$IOS_SET/AppIcon-1024.png" 1024
render_square "$IOS_SET/AppIcon-1024-dark.png" 1024 "$DARK_COMPOSITE"
render_square "$IOS_SET/AppIcon-1024-tinted.png" 1024 "$TINTED_COMPOSITE"
write_json "$IOS_SET/Contents.json" '{
  "images" : [
    { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "AppIcon-1024-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "AppIcon-1024-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}'

# macOS .icns-style appiconset.
MAC_ASSETS="$ROOT/Sources/Platforms/macOS/Assets.xcassets"
MAC_SET="$MAC_ASSETS/AppIcon.appiconset"
rm -rf "$MAC_ASSETS"
write_asset_catalog_root "$MAC_ASSETS"
render_square "$MAC_SET/icon_16x16.png" 16
render_square "$MAC_SET/icon_16x16@2x.png" 32
render_square "$MAC_SET/icon_32x32.png" 32
render_square "$MAC_SET/icon_32x32@2x.png" 64
render_square "$MAC_SET/icon_128x128.png" 128
render_square "$MAC_SET/icon_128x128@2x.png" 256
render_square "$MAC_SET/icon_256x256.png" 256
render_square "$MAC_SET/icon_256x256@2x.png" 512
render_square "$MAC_SET/icon_512x512.png" 512
render_square "$MAC_SET/icon_512x512@2x.png" 1024
write_json "$MAC_SET/Contents.json" '{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}'

# visionOS layered icon: parchment background + elder-sign foreground.
VISION_ASSETS="$ROOT/Sources/Platforms/visionOS/Assets.xcassets"
VISION_SET="$VISION_ASSETS/AppIcon.solidimagestack"
rm -rf "$VISION_ASSETS"
write_asset_catalog_root "$VISION_ASSETS"
for layer in Back Front; do
  mkdir -p "$VISION_SET/$layer.solidimagestacklayer/Content.imageset"
  write_json "$VISION_SET/$layer.solidimagestacklayer/Contents.json" '{
  "info" : { "author" : "xcode", "version" : 1 }
}'
done
write_json "$VISION_SET/Contents.json" '{
  "info" : { "author" : "xcode", "version" : 1 },
  "layers" : [
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "Back.solidimagestacklayer" }
  ]
}'
render_layer "$BACKGROUND" "$VISION_SET/Back.solidimagestacklayer/Content.imageset/background.png" 1024 1024 cover
render_layer "$FOREGROUND" "$VISION_SET/Front.solidimagestacklayer/Content.imageset/foreground.png" 1024 1024 contain
write_json "$VISION_SET/Back.solidimagestacklayer/Content.imageset/Contents.json" '{
  "images" : [{ "filename" : "background.png", "idiom" : "vision", "scale" : "2x" }],
  "info" : { "author" : "xcode", "version" : 1 }
}'
write_json "$VISION_SET/Front.solidimagestacklayer/Content.imageset/Contents.json" '{
  "images" : [{ "filename" : "foreground.png", "idiom" : "vision", "scale" : "2x" }],
  "info" : { "author" : "xcode", "version" : 1 }
}'

# tvOS brand assets: background + elder-sign app-icon stacks and top shelf art.
TV_ASSETS="$ROOT/Sources/Platforms/tvOS/Assets.xcassets"
TV_SET="$TV_ASSETS/App Icon.brandassets"
rm -rf "$TV_ASSETS"
write_asset_catalog_root "$TV_ASSETS"
write_json "$TV_SET/Contents.json" '{
  "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}'

create_tv_stack() {
  local stack="$1" width="$2" height="$3" scale_json="$4"
  mkdir -p "$stack"
  write_json "$stack/Contents.json" '{
  "info" : { "author" : "xcode", "version" : 1 },
  "layers" : [
    { "filename" : "Front.imagestacklayer" },
    { "filename" : "Back.imagestacklayer" }
  ]
}'
  for layer in Back Front; do
    mkdir -p "$stack/$layer.imagestacklayer/Content.imageset"
    write_json "$stack/$layer.imagestacklayer/Contents.json" '{
  "info" : { "author" : "xcode", "version" : 1 }
}'
  done
  render_layer "$BACKGROUND" "$stack/Back.imagestacklayer/Content.imageset/back.png" "$width" "$height" cover
  render_layer "$FOREGROUND" "$stack/Front.imagestacklayer/Content.imageset/front.png" "$width" "$height" contain
  write_json "$stack/Back.imagestacklayer/Content.imageset/Contents.json" "{
  \"images\" : [{ \"filename\" : \"back.png\", \"idiom\" : \"tv\"$scale_json }],
  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }
}"
  write_json "$stack/Front.imagestacklayer/Content.imageset/Contents.json" "{
  \"images\" : [{ \"filename\" : \"front.png\", \"idiom\" : \"tv\"$scale_json }],
  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }
}"
}

create_tv_stack "$TV_SET/App Icon - App Store.imagestack" 1280 768 ""
APP_STACK="$TV_SET/App Icon.imagestack"
create_tv_stack "$APP_STACK" 800 480 ', "scale" : "2x"'
for layer in Back Front; do
  case "$layer" in
    Back) layer_source="$BACKGROUND"; file1x="back-1x.png"; file2x="back.png"; mode="cover" ;;
    Front) layer_source="$FOREGROUND"; file1x="front-1x.png"; file2x="front.png"; mode="contain" ;;
  esac
  render_layer "$layer_source" "$APP_STACK/$layer.imagestacklayer/Content.imageset/$file1x" 400 240 "$mode"
  write_json "$APP_STACK/$layer.imagestacklayer/Content.imageset/Contents.json" "{
  \"images\" : [
    { \"filename\" : \"$file1x\", \"idiom\" : \"tv\", \"scale\" : \"1x\" },
    { \"filename\" : \"$file2x\", \"idiom\" : \"tv\", \"scale\" : \"2x\" }
  ],
  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }
}"
done

TOP="$TV_SET/Top Shelf Image.imageset"
TOP_WIDE="$TV_SET/Top Shelf Image Wide.imageset"
render_tv_composite "$TOP/topshelf-1x.png" 1920 720
render_tv_composite "$TOP/topshelf-2x.png" 3840 1440
render_tv_composite "$TOP_WIDE/topshelf-wide-1x.png" 2320 720
render_tv_composite "$TOP_WIDE/topshelf-wide-2x.png" 4640 1440
write_json "$TOP/Contents.json" '{
  "images" : [
    { "filename" : "topshelf-1x.png", "idiom" : "tv", "scale" : "1x" },
    { "filename" : "topshelf-2x.png", "idiom" : "tv", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}'
write_json "$TOP_WIDE/Contents.json" '{
  "images" : [
    { "filename" : "topshelf-wide-1x.png", "idiom" : "tv", "scale" : "1x" },
    { "filename" : "topshelf-wide-2x.png", "idiom" : "tv", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}'

echo "Done. Rendered elder-sign artwork into Apple app-icon assets."
