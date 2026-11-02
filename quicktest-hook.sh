#!/bin/sh
# Quick-test hook, not part of the shipped stick: layers the newest scan-mode pieces over an
# existing image at boot, so they can be tried on real hardware without waiting for a full
# rebuild (see make-quicktest-iso.sh). live-config runs it (as root, before LightDM starts)
# when the scan entry's kernel line has
#   live-config.hooks=file:///run/live/medium/live/config-hooks/cyberbeest-quicktest.sh
# The final image gets the same things at build time (experimental/remaster-live-stick.sh).
MEDIUM=/run/live/medium/live/config-hooks

# newest scan window (unlock dialog: focus, show password, keyboard layout)
[ -f "$MEDIUM/cyberbeest_scanner_gui.py" ] && install -m 755 "$MEDIUM/cyberbeest_scanner_gui.py" /usr/local/lib/cyberbeest/cyberbeest_scanner_gui.py

# minimal X session: window manager + scan window, instead of the XFCE desktop
cat > /usr/local/lib/cyberbeest/cyberbeest-scan-session <<'SESSION'
#!/bin/sh
# Minimal X session for the boot-stick scan: a window manager and the scan window.
exec dbus-run-session -- /bin/sh -c '
	xsetroot -solid "#000000" 2>/dev/null
	xfwm4 --compositor=off >/dev/null 2>&1 &
	sleep 1
	exec /usr/local/lib/cyberbeest/cyberbeest-stick-scan-launch.sh
'
SESSION
chmod 755 /usr/local/lib/cyberbeest/cyberbeest-scan-session
cat > /usr/share/xsessions/cyberbeest-scan.desktop <<'DESKTOP'
[Desktop Entry]
Name=Cyberbeest scan
Exec=/usr/local/lib/cyberbeest/cyberbeest-scan-session
Type=Application
DESKTOP
cat > /etc/lightdm/lightdm.conf.d/99-cyberbeest-scan-session.conf <<'CONF'
[Seat:*]
autologin-session=cyberbeest-scan
CONF

# tap-to-click
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/90-touchpad-tap.conf <<'TOUCHPAD'
Section "InputClass"
    Identifier "libinput touchpad tap-to-click"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
    Option "Tapping" "on"
EndSection
TOUCHPAD
exit 0
