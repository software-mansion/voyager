#!/usr/bin/env bash
# Generates the Tauri app icon set from a single source PNG.
#
# Usage: dev/generate_tauri_icons.sh path/to/source.png
#
# Resizes the source image (unmodified otherwise - no background removal,
# recoloring, or cropping) into the icon files Tauri expects at
# rel/app/src-tauri/icons/:
#   32x32.png, 128x128.png, 128x128@2x.png, icon.png, icon.ico, icon.icns
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 path/to/source.png" >&2
  exit 1
fi

src_image="$1"

if [ ! -f "$src_image" ]; then
  echo "Source image not found: $src_image" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required but was not found on PATH." >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil is required (macOS only) but was not found on PATH." >&2
  exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icons_dir="$root_dir/rel/app/src-tauri/icons"

if [ ! -d "$icons_dir" ]; then
  echo "Icons directory not found: $icons_dir" >&2
  exit 1
fi

scale_png() {
  local size="$1" out="$2"
  ffmpeg -y -loglevel error -i "$src_image" -update 1 -vf "scale=${size}:${size}:flags=lanczos" "$out"
}

echo "Generating icons from $src_image into $icons_dir"

scale_png 32 "$icons_dir/32x32.png"
scale_png 128 "$icons_dir/128x128.png"
scale_png 256 "$icons_dir/128x128@2x.png"
scale_png 512 "$icons_dir/icon.png"

iconset_dir="$(mktemp -d)/icon.iconset"
mkdir -p "$iconset_dir"
trap 'rm -rf "$(dirname "$iconset_dir")"' EXIT

for size in 16 32 128 256 512; do
  size2x=$((size * 2))
  scale_png "$size" "$iconset_dir/icon_${size}x${size}.png"
  scale_png "$size2x" "$iconset_dir/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$iconset_dir" -o "$icons_dir/icon.icns"

ffmpeg -y -loglevel error -i "$src_image" -vf "scale=256:256:flags=lanczos" "$icons_dir/icon.ico"

echo "Done. Wrote: 32x32.png, 128x128.png, 128x128@2x.png, icon.png, icon.icns, icon.ico"
