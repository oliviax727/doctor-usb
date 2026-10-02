# Doctor USB

## Purpose

I wanted a live USB install of arch that didn't run like shit, so I changed the system config and put everything here to keep it in a safe place.

This repository is unlikely to be useful in the sense that it can just be immediately installed and used by whoever. But portions of this code are definitely useful for anyone trying to figure out how to install Linux on a live USB and/or use OverlayFS or customised Grub bootloader layouts.

### Statement of Originality

This code was partially written with GitHub Copilot despite my general disposition against AI. Such was used in situations where:
- The live USB GUI was so slow that I had to get a computer to diagnose the problems
- Searching for and figuring out how to pull off certain tricks I was unfamiliar with
- Diagnosing problems with boot behaviour
- Troubleshooting in the event of a catastrophic failure
- Understanding components of all of these systems

## Configuration and Deployment

Config and scripts for the `dr-usb` Arch Linux live-USB system: boots to RAM
in four ways:
<table>
<thead>
  <tr> GRUB Boot Mode </tr> Description | Root Filesystem | Pros | Cons |
</thead>
<tbody>
| No RAM mode | 
| Overlay mode/Partial RAM mode |
| Full RAM mode |
| Emergency RAM rollback mode |
</tbody>
</table>

GRUB menu offering both a Desktop (GUI) and Terminal-only entry for each mode.

- **`system/`** — mirrors the real system's file layout (e.g. `system/etc/fstab`
  is `/etc/fstab` on `dr-usb`). Edit these files and then deploy
- **`FILES.md`** — what each file does and why, in detail.
- **`deploy-doctor-usb.sh`** — pushes `system/` out to the live machine. Run
  `./deploy-doctor-usb.sh --dry-run` to preview, or `./deploy-doctor-usb.sh`
  to deploy with a diff + confirmation prompt. It also automatically reruns
  `mkinitcpio` and/or regenerates `grub.cfg` afterwards, whichever is needed
  based on which files changed (pass `--no-post` to skip that and do it
  yourself).
- **`backup_to_ubuntu.sh`** — backs up to the Ubuntu file system on `/dev/sda3`.

## How the deployment script decides what to rebuild

`dr-usb` normally boots with `/` as a `tmpfs` (RAM) or OverlayFS root, which
breaks `grub-mkconfig`'s device auto-detection (it can't resolve a device for
`/`). After deploying changes to `system/etc/grub.d/*` or
`system/etc/default/grub`, `deploy-doctor-usb.sh` detects the current root
filesystem type and regenerates `grub.cfg` the right way automatically:
- If the system is directly accessing the real root (No RAM mode, `ext4`): runs `grub-mkconfig` directly.
- RAM root (`tmpfs` or `overlay`): `chroot`s into the real USB root
  (`/dev/sdb3` by default, override with `DOCTOR_USB_ROOT_DEVICE=/dev/xxx`)
  to run `grub-mkconfig` there instead, since that's the only place the real
  root device can be resolved.

Deploying anything under `system/etc/initcpio/` or `system/etc/mkinitcpio*`
triggers `sudo mkinitcpio -p linux` afterwards, since those files only take
effect once they're rebuilt into `/boot/initramfs-linux*.img` — editing them
in place doesn't change an already-built image.

If you ever need to do either step manually (or after `--no-post`), the
commands are:

```bash
# initramfs (hooks, mkinitcpio.conf, presets)
sudo mkinitcpio -p linux

# grub.cfg, from RAM/overlay root
sudo mkdir -p /mnt/realroot
sudo mount /dev/sdb3 /mnt/realroot
for d in dev proc sys run; do sudo mount --bind /$d /mnt/realroot/$d; done
sudo mount --bind /boot /mnt/realroot/boot
sudo chroot /mnt/realroot grub-mkconfig -o /boot/grub/grub.cfg
sudo umount /mnt/realroot/boot /mnt/realroot/run /mnt/realroot/sys /mnt/realroot/proc /mnt/realroot/dev
sudo umount /mnt/realroot
sudo rmdir /mnt/realroot

# grub.cfg, from No RAM (real ext4) root
sudo grub-mkconfig -o /boot/grub/grub.cfg
```


