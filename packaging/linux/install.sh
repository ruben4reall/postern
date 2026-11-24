#!/bin/sh
# Installs Postern from this archive, for distributions without a .deb or .rpm. Run it with sudo: the programs go in
# /usr/local, where only an administrator can change them, and polkit's actions in /usr/share/polkit-1.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
if [ "$(id -u)" -ne 0 ]; then
    echo "Run it with sudo: sudo $0" >&2
    exit 1
fi
install -d /usr/local/libexec/postern /usr/local/bin /usr/lib/systemd/user /usr/share/polkit-1/actions \
    /usr/share/applications /usr/share/icons/hicolor/scalable/apps /usr/share/icons/hicolor/symbolic/apps
install -m 0755 "$here/bin/postern-core" "$here/bin/postern-parser" "$here/bin/postern-app" /usr/local/libexec/postern/
install -m 0755 "$here/bin/postern-mcp" "$here/bin/postern" /usr/local/bin/
sed 's#/usr/libexec/postern#/usr/local/libexec/postern#' "$here/share/postern.service" > /usr/lib/systemd/user/postern.service
install -m 0644 "$here/share/postern.socket" /usr/lib/systemd/user/
install -m 0644 "$here/share/ch.rubencatalao.postern.policy" /usr/share/polkit-1/actions/
sed 's#/usr/libexec/postern#/usr/local/libexec/postern#' "$here/share/ch.rubencatalao.postern.desktop" > /usr/share/applications/ch.rubencatalao.postern.desktop
install -m 0644 "$here/share/ch.rubencatalao.postern.svg" /usr/share/icons/hicolor/scalable/apps/
install -m 0644 "$here/share/ch.rubencatalao.postern-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/
systemctl --global enable postern.socket >/dev/null 2>&1 || true
echo "Postern is installed. Sign out and in again (or run: systemctl --user start postern.socket), then open Postern or run: postern setup"
