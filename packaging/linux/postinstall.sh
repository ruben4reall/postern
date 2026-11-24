#!/bin/sh
# Every user's session starts Postern's socket at sign-in; the core itself starts on the first connection.
systemctl --global enable postern.socket >/dev/null 2>&1 || true
gtk-update-icon-cache -q /usr/share/icons/hicolor >/dev/null 2>&1 || true
exit 0
