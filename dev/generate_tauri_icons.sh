#!/usr/bin/env bash
# Generates the Tauri app icon set from a single source image.
#
# Usage: dev/generate_tauri_icons.sh [--format png|jpg|jpeg|webp] path/to/source.image
#
# --format is optional; when omitted it is inferred from the source file's
# extension. It is used to tell ffmpeg explicitly how to decode the input,
# which is useful when the extension is missing/unusual.
#
# Resizes the source image (unmodified otherwise - no background removal,
# recoloring, or cropping) into the icon files Tauri expects at
# rel/app/src-tauri/icons/:
#   32x32.png, 128x128.png, 128x128@2x.png, icon.png, icon.ico, icon.icns
#
# All generated PNGs (and the pixel data backing icon.ico/icon.icns) are
# forced to RGBA, since Tauri requires icons to have an alpha channel -
# source formats without one (e.g. JPEG) would otherwise fail with:
#   "icon ... is not RGBA"
set -euo pipefail

usage() {
  echo "Usage: $0 [--format png|jpg|jpeg|webp] path/to/source.image" >&2
}

format=""
src_image=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      format="${2:-}"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "$src_image" ]; then
        echo "Unexpected extra argument: $1" >&2
        usage
        exit 1
      fi
      src_image="$1"
      shift
      ;;
  esac
done

if [ -z "$src_image" ]; then
  usage
  exit 1
fi

if [ ! -f "$src_image" ]; then
  echo "Source image not found: $src_image" >&2
  exit 1
fi

if [ -z "$format" ]; then
  ext="${src_image##*.}"
  format="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
fi

# Maps the user/extension-facing format name to the ffmpeg demuxer name used
# to force decoding (via -f), and validates it's a supported format.
case "$format" in
  png)
    ffmpeg_format="png_pipe"
    ;;
  jpg|jpeg)
    ffmpeg_format="jpeg_pipe"
    ;;
  webp)
    ffmpeg_format="webp_pipe"
    ;;
  *)
    echo "Unsupported or undetected image format: '${format:-<empty>}'" >&2
    echo "Pass --format explicitly with one of: png, jpg, jpeg, webp" >&2
    exit 1
    ;;
esac

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
  ffmpeg -y -loglevel error -f "$ffmpeg_format" -i "$src_image" -update 1 \
    -vf "scale=${size}:${size}:flags=lanczos,format=rgba" \
    -pix_fmt rgba \
    "$out"
}

echo "Generating icons from $src_image (format: $format) into $icons_dir"

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

ffmpeg -y -loglevel error -f "$ffmpeg_format" -i "$src_image" \
  -vf "scale=256:256:flags=lanczos,format=rgba" \
  -pix_fmt bgra \
  "$icons_dir/icon.ico"

echo "Done. Wrote: 32x32.png, 128x128.png, 128x128@2x.png, icon.png, icon.icns, icon.ico"
