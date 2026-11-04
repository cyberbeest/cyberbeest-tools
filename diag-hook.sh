#!/bin/sh
# Support/diagnostic hook, not part of the shipped stick. Run by live-config when the
# kernel command line has live-config.hooks=file:///run/live/medium/live/config-hooks/cyberbeest-diag.sh
# (see make-diag-iso.sh; live-config's own "medium" hook source looks at an old path).
#
# 1. Installs a command "diag" (type it in the debug shell: Ctrl+Alt+F9) that collects what
#    is needed to see why a session did or did not start; "diag 2" prints a second, deeper
#    page. It also runs by itself once, after the desktop has had time to start, and puts
#    page 1 on VT 9 and page 2 on VT 10, then switches to VT 9 -- nothing to type at all.
#    The automatic run is its own transient systemd unit: a background job started here
#    would die with live-config.service (systemd cleans up a finished unit's cgroup).
# 2. With "cyberbeest-scan-minimal" on the command line, replaces the full XFCE desktop by a
#    minimal X session (window manager + the scan window) for the autologin user.
cat > /usr/local/bin/diag <<'COLLECTOR'
#!/bin/sh
# diag        page 1, now          diag 2 / diag 3     page 2 / page 3, now
# diag auto   wait 80 s, collect both pages, show them on VT 9 / VT 10, switch to VT 9
[ "$1" = auto ] && sleep 80
LL=/var/log/lightdm
page1() {
	echo "=== Cyberbeest stick diagnostics, page 1 ($(date +%T), up $(cut -d. -f1 /proc/uptime)s) ==="
	echo "--- cmdline"; cat /proc/cmdline
	echo "--- lightdm autologin settings"
	grep -rhv '^#' /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/ 2>/dev/null | grep -iE "autologin" | sort -u
	echo "--- accounts"; getent passwd cyberbeest user
	echo "--- login sessions"; loginctl list-sessions --no-pager 2>&1 | head -6
	echo "--- lightdm.log (autologin / session lines)"
	grep -inE "autologin|unknown user|user session|Session pid.*(Started|exited)|Greeter session|Switching|Locking" $LL/lightdm.log | cut -c1-150 | head -9
	echo "--- processes"
	ps -eo pid,user,tty,cmd | grep -v '\[' | grep -E 'xfce4-session|xfwm4|cyberbeest|lightdm|scanner' | grep -v grep | cut -c1-120 | head -7
	echo "--- ~/.xsession-errors (tail)"
	grep -v '^$' /home/cyberbeest/.xsession-errors 2>/dev/null | tail -n 5 | cut -c1-120
	echo "--- journal warnings (tail)"
	journalctl -b -p warning --no-pager 2>/dev/null | tail -n 4 | cut -c1-120
	echo "(page 2: Ctrl+Alt+F10 / 'diag 2'; page 3: Ctrl+Alt+F11 / 'diag 3'; Ctrl+Alt+F7 = desktop)"
}
page2() {
	echo "=== Cyberbeest stick diagnostics, page 2 ==="
	echo "--- lightdm.log around the session start/exit"
	grep -nE "Session pid|display server|Seat seat0: (Creating|Starting|Stopping|Session)" $LL/lightdm.log | cut -c1-120 | head -12
	echo "--- X log of the FIRST X server (x-0.log.old): errors"
	grep -E "\(EE\)|Fatal|rash|Segmentation|Backtrace" $LL/x-0.log.old 2>/dev/null | tail -n 6 | cut -c1-120
	echo "--- x-0.log.old (last lines)"; tail -n 4 $LL/x-0.log.old 2>/dev/null | cut -c1-120
	echo "--- kernel: graphics / memory / crashes"
	dmesg 2>/dev/null | grep -iE "i915|drm.*(error|fail)|out of memory|oom|segfault|killed process|xfce|Xorg" | tail -n 8 | cut -c1-120
	echo "--- journal: session manager"
	journalctl -b --no-pager 2>/dev/null | grep -iE "xfce4-session|xfwm4|segfault|coredump" | tail -n 6 | cut -c1-120
	echo "--- ~/.xsession-errors (first lines)"
	grep -v '^$' /home/cyberbeest/.xsession-errors 2>/dev/null | head -n 8 | cut -c1-120
	echo "--- memory"; free -m | head -2
	echo "--- crash records"; coredumpctl list --no-pager 2>&1 | tail -n 3 | cut -c1-120
}
page3() {
	echo "=== Cyberbeest stick diagnostics, page 3 (the desktop session) ==="
	echo "--- ~/.xsession-errors (first 14 lines)"
	grep -v '^$' /home/cyberbeest/.xsession-errors 2>/dev/null | head -n 14 | cut -c1-130
	echo "--- journal: xfce4-session / xfwm4 / xfsettingsd / Xorg"
	journalctl -b --no-pager 2>/dev/null | grep -E "xfce4-session|xfwm4|xfsettingsd|Xorg|x-0|trap|segfault" | tail -n 8 | cut -c1-130
	echo "--- saved XFCE sessions (a stale one is restored at login)"
	ls -la /home/cyberbeest/.cache/sessions 2>&1 | tail -n 4 | cut -c1-110
	echo "--- xfwm4 compositing setting"
	grep -E "use_compositing|vblank_mode" /home/cyberbeest/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml 2>&1 | cut -c1-110
	echo "--- kernel errors / warnings (tail)"
	dmesg -l err,warn 2>/dev/null | tail -n 8 | cut -c1-130
	echo "--- crash records"; ls /var/lib/systemd/coredump /var/crash 2>&1 | head -n 4
}
case "$1" in
	2) page2 ;;
	3) page3 ;;
	auto)
		page1 > /run/cyberbeest-diag.txt 2>&1
		page2 > /run/cyberbeest-diag2.txt 2>&1
		page3 > /run/cyberbeest-diag3.txt 2>&1
		{ clear; cat /run/cyberbeest-diag3.txt; } > /dev/tty11 2>/dev/null
		{ clear; cat /run/cyberbeest-diag2.txt; } > /dev/tty10 2>/dev/null
		{ clear; cat /run/cyberbeest-diag.txt; } > /dev/tty9 2>/dev/null
		chvt 9 2>/dev/null ;;
	*) page1 ;;
esac
COLLECTOR
chmod 755 /usr/local/bin/diag
systemd-run --unit=cyberbeest-diag --no-block /usr/local/bin/diag auto >/dev/null 2>&1 \
	|| { setsid /usr/local/bin/diag auto >/dev/null 2>&1 & }

if grep -qw cyberbeest-scan-minimal /proc/cmdline; then
	cat > /usr/local/bin/cyberbeest-scan-session <<'SESSION'
#!/bin/sh
# Minimal X session for the boot-stick scan: a window manager and the scan window, nothing else.
exec dbus-run-session -- /bin/sh -c '
	xsetroot -solid "#000000" 2>/dev/null
	xfwm4 --compositor=off >/dev/null 2>&1 &
	sleep 1
	exec /usr/local/lib/cyberbeest/cyberbeest-stick-scan-launch.sh
'
SESSION
	chmod 755 /usr/local/bin/cyberbeest-scan-session
	cat > /usr/share/xsessions/cyberbeest-scan.desktop <<'DESKTOP'
[Desktop Entry]
Name=Cyberbeest scan
Exec=/usr/local/bin/cyberbeest-scan-session
Type=Application
DESKTOP
	cat > /etc/lightdm/lightdm.conf.d/99-cyberbeest-scan-session.conf <<'CONF'
[Seat:*]
autologin-session=cyberbeest-scan
CONF
fi
exit 0
