#!/bin/bash
# Stage 4: boot a locale-branch's provisioned VM and run
# provisioning/experimental/remaster-live-stick.sh *inside* it (it must run
# on the machine being snapshotted, per its own header), then pull the
# resulting live ISO back out to output/. Deletes the provisioned.qcow2
# afterward -- its last consumer (the stick builds have their own provisioned
# disks, separate from the VM image's, see 02-provision.sh). Keeps disk usage on the 59GB workspace partition to roughly
# "one provisioned VM disk + outputs" at a time instead of all of them at
# once.
#
# Usage: bash 04-remaster.sh en|de
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

LOCALE_CODE="${1:?Usage: $0 en|de}"
case "$LOCALE_CODE" in en|de) ;; *) echo "Unknown locale code: $LOCALE_CODE" >&2; exit 1 ;; esac

STAGE="$LOCALE_CODE-remaster"
rb_skip_if_done "$STAGE"
rb_log "$STAGE"

rb_done "$LOCALE_CODE-provision" || { echo "$LOCALE_CODE-provision hasn't completed yet." >&2; exit 1; }

VM_NAME="cyberbeest-build-$LOCALE_CODE"
PROVISIONED_QCOW2="$WORKDIR/$LOCALE_CODE/provisioned.qcow2"
REMASTER_SCRIPT_LOCAL="$HOME/claude/provisioning/experimental/remaster-live-stick.sh"
REMASTER_SCRIPT_LOCAL_TOWER="$HOME/provisioning-bleeding/experimental/remaster-live-stick.sh"
OUT_ISO="$OUT_DIR/cyberbeest-$LOCALE_CODE-live-remastered.iso"

# On tower this repo lives at ~/provisioning-bleeding (dev-machine copies
# use ~/claude/provisioning); pick whichever exists.
if [ -f "$REMASTER_SCRIPT_LOCAL_TOWER" ]; then
	REMASTER_SCRIPT="$REMASTER_SCRIPT_LOCAL_TOWER"
elif [ -f "$REMASTER_SCRIPT_LOCAL" ]; then
	REMASTER_SCRIPT="$REMASTER_SCRIPT_LOCAL"
else
	echo "Can't find remaster-live-stick.sh in either ~/provisioning-bleeding or ~/claude/provisioning" >&2
	exit 1
fi

rb_ensure_default_network

echo "--- Booting $VM_NAME from its already-provisioned disk ---"
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
	virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
	virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
fi
virt-install \
	--name "$VM_NAME" \
	--memory 4096 \
	--vcpus 4 \
	--disk "path=$PROVISIONED_QCOW2,format=qcow2,bus=virtio,discard=unmap" \
	--network network=default,model=virtio \
	--os-variant debian12 \
	--boot uefi \
	--import \
	--graphics spice,listen=127.0.0.1 \
	--video qxl \
	--noautoconsole
rb_open_viewer "$VM_NAME"

# script 99-remove-openssh-server.sh (part of the real provisioning
# sequence, already run in 02-provision.sh) purges sshd and wipes
# authorized_keys -- by design, matching what real shipped machines get.
# So this stage can't just SSH in like the earlier stages did. Instead:
# qemu-guest-agent (installed into base.qcow2/en's overlay specifically for
# this, see cyberbeest_release_build_pipeline memory -- virtio-serial,
# host-only, never network-exposed, kept in shipped artifacts by product
# decision) drives the actual remaster run with zero network exposure.
# SSH only comes back, briefly, at the very end -- purely to pull out the
# already-finished multi-GB ISO, which guest-agent's tiny chunked file API
# can't handle. That's timing-safe: remaster-live-stick.sh builds its
# squashfs from an EARLY rsync'd copy of the filesystem, so anything
# reinstalled after it finishes never gets captured into the shipped
# image -- and this whole disk gets deleted at the end of this script
# regardless, so its own final state (temporarily has sshd again) never
# ships anywhere.
rb_wait_for_ga "$VM_NAME"

echo "--- Writing remaster-live-stick.sh into the guest via guest-agent (no network needed) ---"
rb_ga_write_file "$VM_NAME" "/home/$BUILD_USER/remaster-live-stick.sh" "$REMASTER_SCRIPT"

echo "--- Running it via guest-agent as root (this takes a while -- squashfs + ISO build) ---"
# guest-exec already runs as root (the qemu-guest-agent service's own
# privilege level) -- remaster-live-stick.sh insists on $SUDO_USER being
# set (it checks this is being run via `sudo`, not a raw root shell, so it
# knows which real user to chown the output ISO to); we're not actually
# going through sudo here, so just set the var it's really checking for.
# Output goes to a log file in the guest, the exit code to a marker file: the agent
# reply (a whole live-build log) can exceed virsh's 10MB response cap, which made a
# successful remaster look like a failure (2026-10-17). The marker also lets a
# re-run after a pipeline crash skip a remaster that already finished in the guest.
RC_FILE="/home/$BUILD_USER/remaster.rc"
GA_EXEC_CMD="env SUDO_USER=$BUILD_USER http_proxy=$APT_PROXY https_proxy=$APT_PROXY bash /home/$BUILD_USER/remaster-live-stick.sh >/home/$BUILD_USER/remaster.log 2>&1; echo \$? >$RC_FILE"
FINISHED_TEST="grep -q ': done ===' /home/$BUILD_USER/remaster.log && test -s /home/$BUILD_USER/cyberbeest-live-remastered-amd64.iso"
if [ "$(rb_ga_exec "$VM_NAME" "cat $RC_FILE 2>/dev/null || true" 60 2>/dev/null | tr -d '[:space:]')" = "0" ] || rb_ga_exec "$VM_NAME" "$FINISHED_TEST" 60 >/dev/null 2>&1; then
	echo "--- Remaster already finished in this guest (remaster.rc = 0, or its log and ISO show it completed) -- skipping it ---"
else
	rb_ga_exec "$VM_NAME" "rm -f $RC_FILE" 60 >/dev/null
	rb_ga_exec "$VM_NAME" "$GA_EXEC_CMD" 3600 >/dev/null || true
	RC="$(rb_ga_exec "$VM_NAME" "cat $RC_FILE 2>/dev/null || echo missing" 60 | tr -d '[:space:]')"
	# remaster-live-stick.sh used to exit non-zero after finishing (its EXIT-trap umount
	# failing under set -e), so a finished ISO plus its "done" line counts as success.
	if [ "$RC" != "0" ] && rb_ga_exec "$VM_NAME" "$FINISHED_TEST" 60 >/dev/null 2>&1; then
		echo "--- remaster-live-stick.sh exited rc=$RC but its log shows it finished and the ISO exists -- continuing ---"
		RC=0
	fi
	if [ "$RC" != "0" ]; then
		echo "FAILED: remaster-live-stick.sh via guest-agent (rc=$RC) -- leaving $VM_NAME running for inspection. Log tail:" >&2
		rb_ga_exec "$VM_NAME" "tail -n 40 /home/$BUILD_USER/remaster.log" 60 >&2 || true
		exit 1
	fi
fi

echo "--- Reinstalling openssh-server (guest-agent) purely to pull the finished ISO out -- timing-safe, see comment above ---"
rb_ga_exec "$VM_NAME" "apt-get -o DPkg::Lock::Timeout=60 install -y openssh-server" 300 >/dev/null
# rb_ga_exec has no stdin-piping support (guest-exec's own input-data field
# isn't wired up here) -- the authorized_keys content travels via
# guest-file-write, same mechanism as the script upload above, not shell
# redirection into a guest-agent command.
rb_ga_write_file "$VM_NAME" "/home/$BUILD_USER/.ssh/authorized_keys.tmp" "$SSH_KEY.pub"
rb_ga_exec "$VM_NAME" "mkdir -p /home/$BUILD_USER/.ssh && mv /home/$BUILD_USER/.ssh/authorized_keys.tmp /home/$BUILD_USER/.ssh/authorized_keys && chown -R $BUILD_USER:$BUILD_USER /home/$BUILD_USER/.ssh && chmod 700 /home/$BUILD_USER/.ssh && chmod 600 /home/$BUILD_USER/.ssh/authorized_keys && systemctl enable --now ssh" 60

IP="$(rb_wait_for_ip "$VM_NAME")"

echo "--- Pulling the resulting ISO back to $OUT_ISO ---"
rb_scp_from "$IP" "/home/$BUILD_USER/cyberbeest-live-remastered-amd64.iso" "$OUT_ISO"

echo "--- Shutting down and discarding the provisioned VM disk ---"
rb_shutdown_and_wait "$VM_NAME"
virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
rm -f "$PROVISIONED_QCOW2"

rb_mark_done "$STAGE"
echo "=== $(date) : $STAGE done: $OUT_ISO ==="
