#!/bin/zsh
# Captures every pane of the control window, light and dark, with sample data. The window is placed outside every
# display, so nothing appears on screen. Usage: scripts/snapshot-control.sh <output folder>
set -euo pipefail
out=${1:?output folder}
mkdir -p "$out"
binary="build/Build/Products/Debug/Postern.app/Contents/MacOS/Postern"
for appearance in light dark; do
  for pane in welcome overview tools mailboxes clients activity security; do
    ids=$(mktemp)
    "$binary" --hold-control-window "$pane" "$appearance" > "$ids" 2>/dev/null &
    for i in {1..30}; do [ -s "$ids" ] && break; sleep 0.3; done
    sleep 1.5
    screencapture -l "$(head -1 "$ids")" -o -x "$out/control-$pane-$appearance.png"
    wait
    rm -f "$ids"
  done
done
for appearance in light dark; do
  for kind in email attachments trash erase; do
    ids=$(mktemp)
    "$binary" --hold-approval-panel "$appearance" "$kind" > "$ids" 2>/dev/null &
    for i in {1..30}; do [ -s "$ids" ] && break; sleep 0.3; done
    sleep 1.5
    screencapture -l "$(head -1 "$ids")" -o -x "$out/approval-$kind-$appearance.png"
    wait
    rm -f "$ids"
  done
done
ls "$out"
