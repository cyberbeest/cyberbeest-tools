# luks-bypass-once

Skips the LUKS passphrase prompt **and** the LightDM login for exactly one
reboot, so a script can test a full reboot on a live machine without anyone at
the keyboard. **For test machines only.** It deliberately weakens full-disk
encryption for that one boot.

## Use

    sudo ./install.sh                       # once; rebuilds the initrd of the running kernel
    echo "$MASTER" | sudo luks-bypass-once --stdin --reboot
    sudo luks-bypass-once --status | --cancel

Options: `--minutes N` (how long after the reboot starts the key is honored,
default 10), `--luks-only` (no autologin), `--reboot`, `--stdin`.

## How it works

1. Arming adds a random 256-bit key to LUKS slot 7 and stores it, plus the
   login user, in `/etc/cyberbeest-bypass.pending` (inside the encrypted root).
2. On a **reboot** (never poweroff), `cyberbeest-luks-bypass-stage.service`
   copies the key to `/boot` and writes a one-shot LightDM autologin drop-in.
   A powered-off disk therefore never holds a usable key.
3. The crypttab keyscript (`cyberbeest-askpass-boot-fresh`) moves the key into
   `/run`, deletes it from `/boot`, and, if it has not expired, answers the
   unlock instead of prompting. Anything unexpected falls back to the prompt.
4. After boot, `cyberbeest-luks-bypass-cleanup` removes slot 7 using the key in
   `/run`, and `...-autologin-cleanup` removes the autologin file once the
   session is up (at the latest after 180 s; the stage service also deletes any
   leftover at the next shutdown).

## Notes

- Assumes a single LUKS device in `/etc/crypttab` whose keyscript is
  `/lib/cryptsetup/cyberbeest-askpass-boot-fresh` (copy included here; it is the
  Boot Fresh keyscript from `provisioning/experimental/lib` plus the bypass
  block) and `/boot` mounted in the initramfs (`cyberbeest-mount-boot`).
- Master password is normalized with `cyberbeest-passphrase-filter` if present.
- Fallback if a boot breaks: pick an older kernel in GRUB; the installer leaves
  their initrds untouched and backs up the rebuilt one as
  `initrd.img-<ver>.pre-bypass-backup`.
- While armed, anyone who can reboot the machine gets in. Do not arm a machine
  you do not control.
