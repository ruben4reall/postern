#!/bin/sh
systemctl --global disable postern.socket >/dev/null 2>&1 || true
exit 0
