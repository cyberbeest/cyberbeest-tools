#!/bin/bash
# Creates the ed25519 key that signs the boot-stick scan manifest
# (combine-live-and-installer.sh) and prints the public half in the
# allowed_signers format the installed machines verify against
# (provisioning/lib/cyberbeest-scan-allowed-signers). Run once, on the
# machine that builds release sticks; keep the private key off the sticks.
set -euo pipefail
KEYDIR="$HOME/.config/cyberbeest-scan-signing"
KEY="$KEYDIR/id_ed25519"
if [ -e "$KEY" ]; then
	echo "Key already exists: $KEY" >&2
else
	mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
	ssh-keygen -q -t ed25519 -N '' -C 'cyberbeest-scan stick signing' -f "$KEY"
	echo "Created $KEY" >&2
fi
echo "cyberbeest-scan namespaces=\"cyberbeest-scan\" $(cut -d' ' -f1,2 "$KEY.pub")"
