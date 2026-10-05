#!/bin/zsh
# Generates Quill's whole brand from QuillBrand.swift and generate.py: the vector assets
# (SVG), the rasters for the web and documents (png/), the favicon and the share images.
# The app's AppIcon.icns is not kept here: make-app.sh renders it into every build.
# usage: assets/brand/make-brand.sh [path to Geist-Regular.ttf]
set -euo pipefail
here=${0:A:h}
cd $here
# Geist ships inside Next.js (@vercel/og); a worktree has no node_modules, so look in the
# main checkout too.
main=$(cd "$(git -C $here rev-parse --git-common-dir)/.." && pwd)
geist=templates/apps/forge-starter/node_modules/next/dist/compiled/@vercel/og/Geist-Regular.ttf
font=${1:-}
for candidate in "$here/../../../../$geist" "$main/$geist"; do
  [[ -z $font && -f $candidate ]] && font=$candidate
done
[[ -n $font && -f $font ]] || { echo "✗ Geist-Regular.ttf not found (pass its path)" >&2; exit 1 }

python3 generate.py $font

bin=$(mktemp -d)/quill-brand
swiftc -O QuillBrand.swift -o $bin
out=$here/png
mkdir -p $out
for size in 1024 512 256 128 64 32 16; do $bin icon $out/app-icon-$size.png $size; done
$bin icon-light $out/app-icon-light-1024.png 1024
for name in mark mono mono-white; do $bin $name $out/$name-512.png 512; done
$bin og-es $out/og-image-es.png $font
$bin og-en $out/og-image-en.png $font

# The web set: favicon (SVG for modern browsers, ICO for the rest) and the iOS home-screen icon.
web=$here/web
mkdir -p $web
cp favicon.svg $web/favicon.svg
tmp=$(mktemp -d)
for size in 16 32 48; do $bin icon $tmp/favicon-$size.png $size; done
cp $tmp/favicon-32.png $web/favicon-32.png
magick $tmp/favicon-16.png $tmp/favicon-32.png $tmp/favicon-48.png $web/favicon.ico
$bin icon-bleed $web/apple-touch-icon.png 180
cp $out/og-image-es.png $web/og-image.png
echo "✓ brand regenerated in $here"
