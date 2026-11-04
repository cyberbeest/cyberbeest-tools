#!/bin/bash
# Makes a support copy of a finished stick ISO with a first menu entry "DIAGNOSE" that
# (plus a second entry that boots into a minimal scan-only X session instead of XFCE) boots like
# the scan entry but also runs diag-hook.sh (by file:// path: live-config's own
# 'medium' hook source looks at the old /lib/live/mount/medium and finds nothing) (shows a diagnostics page on VT 9
# after ~80 s; also a root shell on tty9 via systemd.debug_shell). For finding out why a scan boot misbehaves on real hardware; not shipped.
#
# Usage: make-diag-iso.sh IN.iso OUT.iso
# Note: the entry changes grub.cfg, so the stick's signed manifest no longer matches --
# the installed machine's popup rejects such a stick, which is what you want from a debug stick.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
IN="${1:?Usage: $0 IN.iso OUT.iso}"
OUT="${2:?Usage: $0 IN.iso OUT.iso}"
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
e = m.group(0)
HOOK = "live-config.hooks=file:///run/live/medium/live/config-hooks/cyberbeest-diag.sh systemd.debug_shell"
def variant(title, ident, extra=""):
    v = e.replace("'Scan this computer for malware' --id cyberbeest-scan", f"'{title}' --id {ident}")
    return re.sub(r"^(\s*linux\s+.*)$", lambda mm: mm.group(1) + extra + " " + HOOK, v, count=1, flags=re.M)
e1 = variant("DIAGNOSE: scan boot + report (support)", "cyberbeest-diag")
e2 = variant("SCAN with minimal session (test)", "cyberbeest-scan-min", " cyberbeest-scan-minimal")
# the plain live desktop (no cyberbeest-scan, so XFCE and not the minimal scan session) + report
ml = re.search(r'^menuentry "Live system \(amd64\)".*?^\}\n', s, re.S | re.M)
if not ml:
    sys.exit("live entry not found in grub.cfg")
e3 = re.sub(r"^(\s*linux\s+.*)$", lambda mm: mm.group(1) + " " + HOOK,
            ml.group(0).replace('"Live system (amd64)"', "'DIAGNOSE LIVE DESKTOP (support)' --id cyberbeest-diag-live"),
            count=1, flags=re.M)
# new entries first, in this order: live-desktop diagnosis, scan diagnosis, minimal-session scan
open(p, "w").write(s[:m.start()] + e3 + e1 + e2 + s[m.start():])
PY
grep -c "config-hooks/cyberbeest-diag.sh" "$WORK/grub.cfg" | grep -qx 3 || { echo "failed to build the diag entry" >&2; exit 1; }

install -d "$WORK/config-hooks"
install -m 755 "$DIR/diag-hook.sh" "$WORK/config-hooks/cyberbeest-diag.sh"

xorriso -indev "$IN" -outdev "$OUT" \
	-map "$WORK/grub.cfg" /boot/grub/grub.cfg \
	-map "$WORK/config-hooks" /live/config-hooks \
	-boot_image any replay \
	-changes_pending yes \
	-commit
echo "Done: $OUT"
