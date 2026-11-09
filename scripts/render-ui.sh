#!/bin/zsh
# Draws every pane of the control window and every approval panel, light and dark, with sample data, into PNG
# files, without putting anything on screen or needing screen recording. Usage: scripts/render-ui.sh <output folder>
set -euo pipefail
out=${1:?output folder}
mkdir -p "$out"
binary="build/Build/Products/Debug/Postern.app/Contents/MacOS/Postern"
save() { while IFS=$'\t' read -r name data; do [ -n "$data" ] && print -r -- "$data" | base64 -d > "$out/$name"; done }
for appearance in light dark; do
  for pane in welcome overview tools mailboxes clients activity security; do
    "$binary" --render-control-window "$pane" "$appearance" 2>/dev/null | save
  done
  for kind in email attachments batch trash erase; do
    "$binary" --render-approval-panel "$appearance" "$kind" 2>/dev/null | save
  done
done
ls "$out"
