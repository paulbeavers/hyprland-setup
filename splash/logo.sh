#!/usr/bin/env bash
# The mark over the wordmark.
#
# Sized for a 1080p panel and no larger. Plymouth draws the watermark at its
# native size — it does not fit it to the screen — so an image sized "large
# enough for anything" simply fills the display. It does double images on a
# hidpi output, which is why designing for 1080p is the right call rather than
# a compromise.
set -euo pipefail
bash mark.sh mark.png

# Mono, because the whole desktop is mono, letterspaced so it reads as a mark
# rather than as a word someone typed.
magick -background none -fill '#cdd6f4' \
  -font 'JetBrains-Mono-ExtraBold' -pointsize 190 -kerning 26 \
  label:'starch' -trim +repage PNG32:word.png

magick -background none -fill '#6c7086' \
  -font 'JetBrains-Mono-Medium' -pointsize 46 -kerning 16 \
  label:'ARCH LINUX' -trim +repage PNG32:tag.png

# Gaps between the three come from a transparent border on each, so -append
# does not have to be told about spacing.
magick mark.png -resize x420 -bordercolor none -border 30x36 PNG32:a.png
magick word.png -resize x140 -bordercolor none -border 30x22 PNG32:b.png
magick tag.png                -bordercolor none -border 30x14 PNG32:c.png

magick a.png b.png c.png -background none -gravity center -append +repage \
  -resize x440 PNG32:logo.png
identify -format '  %f %wx%h\n' a.png b.png c.png logo.png
rm -f a.png b.png c.png word.png tag.png
