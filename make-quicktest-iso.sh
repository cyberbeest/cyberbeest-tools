#!/bin/bash
# Makes a quick-test copy of a finished stick ISO whose scan entry also runs quicktest-hook.sh
# (minimal scan session, newest scan window, tap-to-click) -- for trying those on real
# hardware before a full image rebuild. Not shipped.
#
# Usage: make-quicktest-iso.sh IN.iso OUT.iso PATH/TO/cyberbeest_scanner_gui.py
# Note: the scan entry changes in grub.cfg, so the stick's signed manifest no longer matches;
# the installed machine's popup rejects such a stick, which is right for a test stick.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
IN="${1:?Usage: $0 IN.iso OUT.iso scanner_gui.py}"
OUT="${2:?Usage: $0 IN.iso OUT.iso scanner_gui.py}"
GUI="${3:?Usage: $0 IN.iso OUT.iso scanner_gui.py}"
[ -f "$GUI" ] || { echo "No such file: $GUI" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "$OUT exists, refusing to overwrite" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

xorriso -indev "$IN" -osirrox on -extract /boot/grub/grub.cfg "$WORK/grub.cfg" >/dev/null 2>&1
chmod u+w "$WORK/grub.cfg"
python3 - "$WORK/grub.cfg" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"^menuentry 'Scan this computer for malware'.*?^\}\n", s, re.S | re.M)
if not m:
    sys.exit("scan entry not found in grub.cfg")
e = re.sub(r"^(\s*linux\s+.*)$",
           r"\1 live-config.hooks=file:///run/live/medium/live/config-hooks/cyberbeest-quicktest.sh",
           m.group(0), count=1, flags=re.M)
open(p, "w").write(s[:m.start()] + e + s[m.end():])
PY
grep -c "cyberbeest-quicktest.sh" "$WORK/grub.cfg" | grep -qx 1 || { echo "failed to patch the scan entry" >&2; exit 1; }

install -d "$WORK/config-hooks"
install -m 755 "$DIR/quicktest-hook.sh" "$WORK/config-hooks/cyberbeest-quicktest.sh"
install -m 755 "$GUI" "$WORK/config-hooks/cyberbeest_scanner_gui.py"

xorriso -indev "$IN" -outdev "$OUT" \
	-map "$WORK/grub.cfg" /boot/grub/grub.cfg \
	-map "$WORK/config-hooks" /live/config-hooks \
	-boot_image any replay \
	-changes_pending yes \
	-commit
echo "Done: $OUT"
