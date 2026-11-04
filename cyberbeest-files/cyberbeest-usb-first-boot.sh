#!/bin/bash
# Puts the USB / removable-device entries first in the UEFI boot order, so a Cyberbeest stick
# starts by itself when it is plugged in at power-on (the stick's own menu then decides:
# scan, try or install, or "Boot from hard disk").
#
# Run once at install time from the installer's late_command (see preseed.cfg), or by hand on
# a unit as root. It never fails its caller: some firmware refuses NVRAM writes (the normal
# grub-install NVRAM write failed hard on a real unit's AMI Aptio firmware, 2026-09-09, which is
# why the installer runs with grub-installer/update-nvram off). Only BootOrder is rewritten, an
# existing variable; no entries are created or deleted. The result is checked by reading the
# order back and logged to /var/log/cyberbeest-usb-first-boot.log.
#
# Not run on updates: a user who changed the order on purpose keeps their choice.
#
# Test hooks: CB_EFIBOOTMGR=<command> replaces efibootmgr, CB_LOG=<file> replaces the log.
EFIBOOTMGR="${CB_EFIBOOTMGR:-efibootmgr}"
LOG="${CB_LOG:-/var/log/cyberbeest-usb-first-boot.log}"

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; echo "cyberbeest-usb-first-boot: $*"; }

[ -n "${CB_EFIBOOTMGR:-}" ] || [ -d /sys/firmware/efi ] || { log "not booted in UEFI mode: nothing to do"; exit 0; }
command -v "$EFIBOOTMGR" >/dev/null 2>&1 || { log "efibootmgr not installed: boot order left as it is"; exit 0; }

before="$(LC_ALL=C $EFIBOOTMGR 2>&1)" || { log "could not read the boot entries: $before"; exit 0; }
order="$(sed -n 's/^BootOrder: *//p' <<<"$before" | head -n1)"
[ -n "$order" ] || { log "no BootOrder variable: left as it is"; exit 0; }

# entries whose name says USB or removable device, in their current relative order
usb=""
rest=""
IFS=',' read -ra ids <<<"$order"
for id in "${ids[@]}"; do
	name="$(sed -n "s/^Boot${id}\*\? *//p" <<<"$before" | head -n1)"
	if grep -qiE 'usb|removable' <<<"$name"; then usb="$usb${usb:+,}$id"; else rest="$rest${rest:+,}$id"; fi
done

[ -n "$usb" ] || { log "no USB / removable-device entry in the boot order ($order): left as it is"; exit 0; }
if [ "${order#"$usb"}" != "$order" ]; then log "USB is already first ($order)"; exit 0; fi

new="$usb${rest:+,$rest}"
log "boot order $order -> $new"
if ! out="$($EFIBOOTMGR -o "$new" 2>&1)"; then
	log "the firmware refused the change: $(tr '\n' ' ' <<<"$out" | cut -c1-200). Set USB first in the BIOS setup instead."
	exit 0
fi
after="$(LC_ALL=C $EFIBOOTMGR 2>&1 | sed -n 's/^BootOrder: *//p' | head -n1)"
if [ "$after" = "$new" ]; then log "done: $after"; else log "written, but reads back as '$after', not '$new'. Check in the BIOS setup."; fi
exit 0
