#!/bin/bash
# Stage 2 of the release-build pipeline: branch base.qcow2 into a
# locale-specific overlay disk and run the full NN-*.sh provisioning
# sequence against it, non-interactively.
#
# Why this drives the NN-*.sh scripts directly over SSH instead of using
# run-gui.py (the normal way a human runs provisioning): run-gui.py is
# GUI-only (Gtk.main(), no headless mode) and needs a human to click "Run
# All" even when a .provisioning-profile.env makes every individual script
# non-interactive. Running each script directly, in the same numeric order
# run-gui.py itself would, gets the identical result without that click.
#
# Two kinds of build come out of this script, because a VM image and a live stick are
# different products (provisioning behaves differently inside a VM than on real hardware):
#   en-vm    the VM image's source: provisioned as a guest, no override, so the
#            VM-aware scripts (no welcome-screen autostart, no nested sandbox VM) act
#            as they would inside a VM. Consumed by 03-vm-image.sh.
#   en | de  a live stick's source: PROVISIONING_FORCE_VM_IMAGE_IN_VM=1, so those
#            scripts behave as on real hardware even though the build guest is a VM.
#            Consumed by 04-remaster.sh.
#
# Usage: bash 02-provision.sh en|de|en-vm
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

ARG="${1:?Usage: $0 en|de|en-vm}"
case "$ARG" in
	en-vm) LOCALE_CODE=en; KIND=vm; TAG=en-vm ;;
	en|de) LOCALE_CODE="$ARG"; KIND=stick; TAG="$ARG" ;;
	*) echo "Unknown build: $ARG (expected en, de or en-vm)" >&2; exit 1 ;;
esac
case "$LOCALE_CODE" in
	en) COUNTRY=US; LANG_CHOICE=en; LOCALE=en_US.UTF-8; KEYBOARD=us; TIMEZONE=UTC ;;
	de) COUNTRY=DE; LANG_CHOICE=de; LOCALE=de_DE.UTF-8; KEYBOARD=de; TIMEZONE=Europe/Berlin ;;
	*) echo "Unknown locale code: $LOCALE_CODE (expected en or de)" >&2; exit 1 ;;
esac

STAGE="$TAG-provision"
rb_skip_if_done "$STAGE"
rb_log "$STAGE"

rb_done base-install || { echo "base-install hasn't completed yet -- run 01-base-install.sh first." >&2; exit 1; }

VM_NAME="cyberbeest-build-$TAG"
LOCALE_DIR="$WORKDIR/$TAG"
PROVISIONED_QCOW2="$LOCALE_DIR/provisioned.qcow2"
RAM_MB=4096
VCPUS=4

# Same "product" repo/branch beestify.sh itself points real end-user
# machines at (see cyberbeest-bootstrap.sh's BEESTIFY_URL) -- building from
# `stable`, not tower's own bleeding-edge working copy, so this release
# build reflects what a real user's machine would actually receive right
# now.
PROVISIONING_REPO="https://github.com/cyberbeest/provisioning.git"
PROVISIONING_BRANCH="stable"

rb_ensure_default_network
rb_ensure_ssh_key

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
	echo "--- A stale '$VM_NAME' domain already exists -- undefining it (disk file is recreated below) ---"
	virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
	virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$LOCALE_DIR"
echo "--- Creating $PROVISIONED_QCOW2 as a copy-on-write overlay on base.qcow2 ---"
rm -f "$PROVISIONED_QCOW2"
qemu-img create -f qcow2 -b "$BASE_QCOW2" -F qcow2 "$PROVISIONED_QCOW2"

echo "--- Booting $VM_NAME ---"
virt-install \
	--name "$VM_NAME" \
	--memory "$RAM_MB" \
	--vcpus "$VCPUS" \
	--disk "path=$PROVISIONED_QCOW2,format=qcow2,bus=virtio,discard=unmap" \
	--network network=default,model=virtio \
	--os-variant debian12 \
	--boot uefi \
	--import \
	--graphics spice,listen=127.0.0.1 \
	--video qxl \
	--noautoconsole
rb_open_viewer "$VM_NAME"

IP="$(rb_wait_for_ip "$VM_NAME")"
UID_CYBERBEEST="$(rb_ssh "$IP" 'id -u cyberbeest')"
DBUS_ADDR="unix:path=/run/user/$UID_CYBERBEEST/bus"

echo "--- Confirming the autologin XFCE session is actually up (needed for xfconf/gsettings-touching scripts) ---"
for _ in $(seq 1 24); do
	rb_ssh "$IP" "test -S /run/user/$UID_CYBERBEEST/bus" && break
	sleep 5
done
rb_ssh "$IP" "test -S /run/user/$UID_CYBERBEEST/bus" || {
	echo "Session D-Bus socket never appeared -- autologin likely didn't reach a desktop session." >&2
	exit 1
}

echo "--- Cloning provisioning ($PROVISIONING_BRANCH) into the guest ---"
rb_ssh "$IP" "rm -rf ~/provisioning && git clone --branch '$PROVISIONING_BRANCH' --depth 1 '$PROVISIONING_REPO' ~/provisioning"

echo "--- Writing .provisioning-profile.env (locale=$LOCALE_CODE) ---"
# PROVISIONING_VM_IMAGE=no: skips script 56 (sandbox-VM download+register)
# entirely. Registering it here would need to boot a VM inside this
# already-nested build VM, which reliably fails (cgroup-delegation issue,
# unresolved) -- see cyberbeest_release_build_pipeline memory. The donor
# VM stays a follow-up; this run just gets the base product up to date.
rb_ssh "$IP" "cat > ~/provisioning/.provisioning-profile.env" <<-EOF
	PROVISIONING_PROFILE=1
	PROVISIONING_COUNTRY=$COUNTRY
	PROVISIONING_LANG=$LANG_CHOICE
	PROVISIONING_LOCALE=$LOCALE
	PROVISIONING_KEYBOARD=$KEYBOARD
	PROVISIONING_MENU_KEY_REMAP=no
	PROVISIONING_TIMEZONE=$TIMEZONE
	PROVISIONING_TOUCHPAD_TUNING=no
	PROVISIONING_VM_IMAGE=no
EOF

# A stick is for real hardware: the VM-aware scripts must not mistake the build guest for
# the product's environment (see 56-cyberbeest-sandbox-vm-kvm.sh, 72-welcome-screen.sh).
EXTRA_ENV=""
[ "$KIND" = stick ] && EXTRA_ENV="PROVISIONING_FORCE_VM_IMAGE_IN_VM=1"

# The VM image is the Cyberbeest sandbox VM's base (published as the donor image), so
# stamp the sandbox-VM marker before the scripts run: 91-sandbox-vm.sh then installs the
# VM session settings (auto-lock off, no KITT scanner, ...) and sandbox-vm-system.sh the
# root-side ones. Without it the image carries laptop-only panel items.
if [ "$KIND" = vm ]; then
	rb_ssh "$IP" "sudo touch /etc/cyberbeest-sandbox-vm"
fi

echo "--- Running every NN-*.sh in order ---"
# LC_ALL=C for correct 00 < 00a < 01 < ... < 13 < 13a < 14 ordering (see
# cyberbeest_provisioning_nn_letter_suffix_scheme memory).
SCRIPTS="$(rb_ssh "$IP" "cd ~/provisioning && LC_ALL=C ls -1 [0-9][0-9]-*.sh [0-9][0-9][a-z]-*.sh 2>/dev/null | LC_ALL=C sort")"
if [ -z "$SCRIPTS" ]; then
	echo "No NN-*.sh scripts found in the cloned repo -- something's wrong with the clone." >&2
	exit 1
fi
while IFS= read -r script; do
	[ -z "$script" ] && continue
	echo "--- [$TAG] Running $script ---"
	if ! rb_ssh "$IP" "sudo env DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDR $EXTRA_ENV http_proxy=$APT_PROXY https_proxy=$APT_PROXY bash ~/provisioning/$script"; then
		echo "FAILED: $script -- leaving $VM_NAME running for inspection (ssh -i $SSH_KEY $BUILD_USER@$IP)." >&2
		exit 1
	fi
done <<<"$SCRIPTS"

echo "--- Provisioning sequence finished -- shutting down cleanly ---"
rb_shutdown_and_wait "$VM_NAME"

rb_mark_done "$STAGE"
echo "=== $(date) : $STAGE done: $PROVISIONED_QCOW2 ==="
