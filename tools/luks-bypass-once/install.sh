#!/bin/bash
# Installs the one-boot LUKS bypass for automated testing: patched keyscript,
# luks-bypass-once tool, reboot-staging and cleanup services, and rebuilds the
# initramfs for the RUNNING kernel only (older kernels keep their old initrd
# as a known-good GRUB fallback).
set -euo pipefail
LOG="${LOG:-/var/log/install-luks-bypass-once.log}"
exec > "$LOG" 2>&1

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
KVER="$(uname -r)"
INITRD="/boot/initrd.img-$KVER"

echo "--- backing up $INITRD ---"
cp -a "$INITRD" "$INITRD.pre-bypass-backup"

echo "--- installing files ---"
install -m 755 "$SRC/cyberbeest-askpass-boot-fresh" /lib/cryptsetup/cyberbeest-askpass-boot-fresh
install -m 755 "$SRC/luks-bypass-once" /usr/local/sbin/luks-bypass-once
install -m 755 "$SRC/cyberbeest-luks-bypass-stage" /usr/local/sbin/cyberbeest-luks-bypass-stage
install -m 755 "$SRC/cyberbeest-luks-bypass-cleanup" /usr/local/sbin/cyberbeest-luks-bypass-cleanup
install -m 755 "$SRC/cyberbeest-luks-bypass-autologin-cleanup" /usr/local/sbin/cyberbeest-luks-bypass-autologin-cleanup
install -m 644 "$SRC/cyberbeest-luks-bypass-stage.service" /etc/systemd/system/cyberbeest-luks-bypass-stage.service
install -m 644 "$SRC/cyberbeest-luks-bypass-cleanup.service" /etc/systemd/system/cyberbeest-luks-bypass-cleanup.service
install -m 644 "$SRC/cyberbeest-luks-bypass-autologin-cleanup.service" /etc/systemd/system/cyberbeest-luks-bypass-autologin-cleanup.service
systemctl daemon-reload
systemctl enable cyberbeest-luks-bypass-cleanup.service cyberbeest-luks-bypass-autologin-cleanup.service
systemctl enable --now cyberbeest-luks-bypass-stage.service

echo "--- rebuilding initramfs for $KVER ---"
update-initramfs -u -k "$KVER"

echo "--- verifying the new initrd contains the bypass block ---"
T="$(mktemp -d)"
unmkinitramfs "$INITRD" "$T"
grep -rl "cyberbeest-bypass.key" "$T" | grep -q cyberbeest-askpass-boot-fresh
rm -rf "$T"
echo "OK: keyscript in initrd has the bypass block"
echo "=== $(date): done. Fallback if boot breaks: pick an older kernel in GRUB (Advanced options). ==="
