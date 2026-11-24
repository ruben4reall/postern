#!/bin/sh
# Pictures the Linux app with sample data, light and dark, under a virtual screen. Nothing talks to a core.
# Usage: scripts/linux-screenshots.sh <path to postern-app> <output folder>
set -u
app=$1
out=$2
mkdir -p "$out"
export GSK_RENDERER=cairo
gtk4-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
shoot() {
    name=$1
    size=$2
    shift 2
    dbus-run-session -- xvfb-run -a -s "-screen 0 ${size}x24" sh -c "\"$app\" $* & pid=\$!; sleep 4; import -window root \"$out/$name.png\"; kill \$pid" || true
}
for scheme in light dark; do
    if [ "$scheme" = dark ]; then export ADW_DEBUG_COLOR_SCHEME=prefer-dark; else export ADW_DEBUG_COLOR_SCHEME=prefer-light; fi
    for pane in overview tools mailboxes apps activity security; do
        shoot "$scheme-$pane" 1100x780 --demo "$pane"
    done
    shoot "$scheme-approval" 1100x900 --demo overview --demo-approval
done
ls -la "$out"
