#!/usr/bin/env bash
# make-wallpaper.sh <design> <width> <height> <out>
#
# Every design is built from the same mark the boot splash uses, so the
# wallpaper, the splash and the installer are visibly one thing. Positions are
# fractions of the canvas, so 16:9 and ultrawide come from one source.
#
# The shipped renders are the `lattice` design; `range` and `glow` are kept
# because they are how those renders came to be rejected, and regenerating an
# alternative is one command. To re-render what install.sh deploys:
#
#     ./make-wallpaper.sh lattice 3840 2160 starch-lattice-3840x2160.png
#     ./make-wallpaper.sh lattice 5120 2160 starch-lattice-5120x2160.png
#
# mark.sh is vendored next to this script rather than read out of ~/starch:
# hyprland-setup installs on its own, with no ISO builder present. It is a copy
# of starch/splash/mark.sh and the two have to be changed together.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DESIGN="$1"; W="$2"; H="$3"; OUT="$4"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# mark.sh writes its scratch files into the current directory, so run it in
# the temp dir rather than wherever the caller happened to be.
( cd "$WORK" && bash "${MARK_SH:-$HERE/mark.sh}" "$WORK/mark.png" )

peak() {  # peak <height> <hex> <opacity> <out>
    local h="$1" hex="$2" op="$3" out="$4" w
    magick "$WORK/mark.png" -resize "x$h" -alpha extract "PNG24:$WORK/m.png"
    w=$(identify -format %w "$WORK/m.png")
    magick -size "${w}x${h}" "xc:#$hex" "$WORK/m.png" -compose CopyOpacity -composite \
           -alpha set -channel A -evaluate multiply "$op" +channel "PNG32:$out"
}
at() {  # at <canvas> <layer> <x> <y>
    local lw; lw=$(identify -format %w "$2")
    magick "$1" "$2" -geometry "+$(( $3 - lw/2 ))+$4" -composite "$1"
}

case "$DESIGN" in
range)
    magick -size ${W}x${H} gradient:'#1a1a2b-#0a0a11' "$WORK/c.png"
    magick -size ${W}x${H} radial-gradient:'#233455-#0a0a1100' \
        -alpha set -channel A -evaluate multiply 0.45 +channel "$WORK/g.png"
    magick "$WORK/c.png" "$WORK/g.png" -composite "$WORK/c.png"
    # Back row: smaller, paler, and standing further up the frame, which is
    # what gives the range depth rather than making it a row of shapes.
    while read -r fx fh op tint fbase; do
        h=$(awk -v H="$H" -v f="$fh" 'BEGIN{printf "%d", H*f}')
        x=$(awk -v W="$W" -v f="$fx" 'BEGIN{printf "%d", W*f}')
        b=$(awk -v H="$H" -v f="$fbase" 'BEGIN{printf "%d", H*f}')
        peak "$h" "$tint" "$op" "$WORK/p.png"
        at "$WORK/c.png" "$WORK/p.png" "$x" "$(( H - h - b ))"
    done <<'PEAKS'
0.13 0.16 0.09 74c7ec 0.30
0.34 0.20 0.11 89b4fa 0.28
0.56 0.17 0.09 74c7ec 0.30
0.77 0.22 0.11 89b4fa 0.27
0.95 0.15 0.08 74c7ec 0.30
0.05 0.30 0.17 74c7ec 0.09
0.27 0.42 0.25 89b4fa 0.07
0.52 0.35 0.20 74c7ec 0.08
0.74 0.47 0.29 89b4fa 0.06
0.95 0.32 0.18 74c7ec 0.08
PEAKS
    ;;
lattice)
    magick -size ${W}x${H} gradient:'#191929-#0b0b13' "$WORK/c.png"
    t=$(awk -v H="$H" 'BEGIN{printf "%d", H*0.07}')
    peak "$t" 74c7ec 0.07 "$WORK/tm.png"
    tw=$(awk -v t="$t" 'BEGIN{printf "%d", t*2.3}')
    th=$(awk -v t="$t" 'BEGIN{printf "%d", t*1.35}')
    magick -size ${tw}x${th} xc:none "$WORK/tm.png" -geometry +0+0 -composite \
        "$WORK/tm.png" -geometry +$((tw/2))+$((th/2)) -composite "PNG32:$WORK/tile.png"
    magick "$WORK/c.png" \( -size ${W}x${H} tile:"$WORK/tile.png" \) -composite "$WORK/c.png"
    # No large mark in the middle. The pattern is the wallpaper; a logo sitting
    # on top of it is a poster, and it lands exactly where the windows go.
    ;;
glow)
    magick -size ${W}x${H} gradient:'#16162b-#08080e' "$WORK/c.png"
    magick -size ${W}x${H} radial-gradient:'#223a5e-#08080e00' \
        -alpha set -channel A -evaluate multiply 0.55 +channel "$WORK/g.png"
    magick "$WORK/c.png" "$WORK/g.png" -composite "$WORK/c.png"
    mh=$(awk -v H="$H" 'BEGIN{printf "%d", H*0.46}')
    # The glow is the mark's own alpha, blurred alone. Blurring the RGBA
    # smears the bounding box and leaves a visible rectangle.
    magick "$WORK/mark.png" -resize "x$mh" -alpha extract \
        -blur "0x$(( mh / 18 ))" -evaluate multiply 0.55 "$WORK/gm.png"
    gw=$(identify -format %w "$WORK/gm.png"); gh=$(identify -format %h "$WORK/gm.png")
    magick -size ${gw}x${gh} xc:'#74c7ec' "$WORK/gm.png" -compose CopyOpacity -composite "PNG32:$WORK/glow.png"
    peak "$mh" cfe6f7 0.92 "$WORK/m2.png"
    at "$WORK/c.png" "$WORK/glow.png" $((W/2)) $(( (H-gh)/2 ))
    at "$WORK/c.png" "$WORK/m2.png"  $((W/2)) $(( (H-mh)/2 ))
    ;;
*) echo "unknown design: $DESIGN" >&2; exit 2 ;;
esac

magick "$WORK/c.png" -quality 92 "$OUT"
identify -format '  %f  %wx%h  %b\n' "$OUT"
