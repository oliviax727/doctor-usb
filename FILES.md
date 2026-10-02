# File Reference

What each file under `system/` does and how it fits into the boot-to-RAM
setup. Paths below are given relative to `system/`, which mirrors the real
absolute path on `dr-usb` (e.g. `system/etc/fstab` == `/etc/fstab`).

This is a reference doc, not a tutorial — see `README.md` for the big-picture
overview and `deploy-doctor-usb.sh` for how changes get pushed back to disk.

## GRUB

### `etc/default/grub`
Global GRUB settings. Key values we changed from Arch defaults:
- `GRUB_TIMEOUT=-1` — the menu waits forever for a manual choice instead of
  auto-booting after a few seconds. There are 8+ meaningfully different boot
  modes now, so an accidental default-boot is worse than an extra keypress.
- `GRUB_TIMEOUT_STYLE=menu` — show the full menu immediately (not a countdown
  with "press Esc for menu").
- `GRUB_DISABLE_RECOVERY=true` — don't generate "recovery mode" entries for
  every kernel; we have our own rollback entry instead.

### `etc/grub.d/40_custom`
The hand-written menu entries. `grub-mkconfig` runs every executable script in
`/etc/grub.d/` in lexical order and concatenates their output into
`/boot/grub/grub.cfg`; this is the one script we fully own. It defines 4
submenus (No RAM, Overlay RAM, Full RAM, Rollback RAM), each containing a
**Desktop (GUI)** and **Terminal only (no GUI)** entry — 8 entries total.

The only difference between a Desktop and Terminal entry is the
`systemd.unit=multi-user.target` kernel parameter appended to the `linux`
line. That tells systemd to stop at the multi-user (text) target instead of
pulling in `graphical.target`, so `lightdm` never starts — no display manager
runs at all on the Terminal entries, which is why they're faster and lighter.

The four modes map to kernel/initramfs image combinations:

| Mode | `ramroot` param | initrd image |
|---|---|---|
| No RAM | absent | `initramfs-linux.img` |
| Overlay RAM | present | `initramfs-linux-overlay.img` |
| Full RAM | present | `initramfs-linux.img` |
| Rollback RAM | present | `initramfs-linux.img.pre-monotonic-boot` |

Note Full RAM and No RAM use the *same* initrd image — the `ramroot` kernel
parameter is what the hook inside that image checks for at runtime (see
`etc/initcpio/hooks/ramroot` below) to decide whether to copy the root into
RAM or just mount it normally.

**Previously** this file also shipped as `40_custom.pre-overlay`, a stale
duplicate that was still executable in `/etc/grub.d/` and silently doubled up
menu entries every time `grub-mkconfig` ran. That duplicate has been removed
(backed up under `/home/spot/grub-backup-*/` on the live system). Only one
`40_custom` should ever exist in `/etc/grub.d/`.

`etc/grub.d/30_uefi-firmware` and `etc/grub.d/31_efi_bootnext` are
intentionally **not** copied/tracked here — they were left in place but
`chmod -x`'d on the live system to stop them from injecting the firmware's
EFI boot entries (Ubuntu GRUB, Ubuntu Secure GRUB, onboard NIC, firmware
updater) into Arch's own GRUB menu. Those targets are still reachable from the
firmware's own boot menu (F12 / BIOS boot override) if ever needed.

## mkinitcpio (initramfs build config)

### `etc/mkinitcpio.conf`
Config for the **default** initramfs (`/boot/initramfs-linux.img`), used by
both the "No RAM" and "Full RAM" GRUB entries. `HOOKS=(... ramroot ...)` is
the custom addition — stock Arch doesn't have a `ramroot` hook.

### `etc/mkinitcpio-overlay.conf`
Same as above but with `HOOKS=(... ramroot-overlay ...)` instead, building
`/boot/initramfs-linux-overlay.img` for the "Overlay RAM" entries.

### `etc/mkinitcpio.d/linux.preset`
Tells `mkinitcpio` (when run as `mkinitcpio -P` after a kernel upgrade) to
build *two* presets — `default` and `overlay` — from the two config files
above, each producing its own named image. Without this, a kernel upgrade
would only rebuild the default image and silently leave the overlay image
stale.

### `etc/initcpio/hooks/ramroot`
The **legacy/full-copy** hook. Runs inside the initramfs, before the real
root is mounted. If `ramroot` is not on the kernel command line, it does
nothing (normal boot). If present: mounts the USB root read-only, creates a
`tmpfs`, and `rsync`s the *entire* filesystem into it before switching root.
This is why "Full RAM" and "Rollback RAM" boots are slow — they copy
everything (several GB) over USB at every single boot, by design. It's kept
as the simple, well-understood fallback/recovery path, not the daily driver.

### `etc/initcpio/hooks/ramroot-overlay`
The **fast** hook used by "Overlay RAM". Instead of copying anything, it
mounts the persistent ext4 USB root read-write, finds the most recent
snapshot directory under `.ramroot-state/snapshots/` (written by
`ramroot-checkpoint`, see below), bind-mounts that snapshot read-only as the
OverlayFS lower layer, and creates a `tmpfs` upper layer on top. No bulk copy
happens at boot — this is why Overlay RAM boots in roughly the same time as
No RAM, while still getting a RAM-backed, disposable-by-default root.

### `etc/initcpio/install/ramroot` and `etc/initcpio/install/ramroot-overlay`
`mkinitcpio` build-time scripts (not runtime hooks). They tell `mkinitcpio`
which binaries/modules to pull into the initramfs image for each hook.
`ramroot-overlay`'s install script also copies `/usr/bin/mount` into the
image under the name `mount-util` — this is a renamed copy that only exists
*inside* the built initramfs, not on the live filesystem, so busybox's
built-in `mount` applet (which doesn't support all the bind/private/overlay
options the hook needs) isn't picked up by mistake.

## Systemd units

### `etc/systemd/system/save-to-usb.service`
Runs `/usr/local/bin/save-to-usb` on shutdown (`ExecStop`/shutdown target
ordering) when booted in **Full RAM** or **Rollback RAM** mode, to flush the
RAM-resident root back to the USB before power-off. For **Overlay RAM** it
just delegates to `ramroot-checkpoint --final` (see the script itself) since
the overlay's upper layer needs a proper checkpoint commit, not a raw rsync.
Not involved at all for **No RAM**, since nothing lives only in RAM there.

### `etc/systemd/system/ramroot-checkpoint.service` / `.timer`
The timer fires the service every 10 minutes while Overlay RAM is active
(and once more at shutdown, via `save-to-usb.service`). Each run takes a new
hard-linked snapshot of the current merged (lower+upper) tree onto the
persistent ext4 USB, prunes old generations, and syncs the "base" tree so the
No RAM entry always sees reasonably current data too.

## Scripts

### `usr/local/bin/save-to-usb`
Shutdown-time sync script. For Full RAM/Rollback RAM, `rsync`s the tmpfs root
back onto `/dev/sdb3`, excluding caches/junk (`/var/cache`, `.cache`, GPU
shader caches, etc.) and printing live progress so you know not to pull the
USB stick early. For Overlay RAM it just calls `ramroot-checkpoint --final`.

### `usr/local/sbin/ramroot-checkpoint`
The snapshot engine for Overlay RAM. Modes: `--seed` (first-ever snapshot,
run manually once), periodic (called by the timer), and `--final` (called at
shutdown). Builds a new snapshot generation via hard-linked rsync against the
previous generation (so unchanged files cost no extra disk space), verifies
the result looks like a real root (`/sbin/init`, `/etc`, your home directory
all present) before committing, then atomically flips the "current" pointer
and prunes old generations. Also re-syncs the committed snapshot onto the
*base* ext4 tree so the No RAM entry stays in parity.

## fstab

### `etc/fstab`
Only mounts `/boot` (vfat) and swap. The real root is intentionally **not**
listed — it's mounted directly by the initramfs hooks above (tmpfs copy, or
OverlayFS), and re-mounting it "normally" via fstab would conflict with that.
The comment in the file is a deliberate warning against re-adding it.
