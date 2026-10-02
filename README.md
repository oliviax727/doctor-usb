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

### Components of the Project

### Boot Options

The `dr-usb` Arch Linux live-USB system boots in four ways:

<table>
	<thead>
		<tr>
			<th rowspan=2> GRUB Boot Mode </th>
			<th rowspan=2> Description </th>
			<th rowspan=2> Filesystem Mounted as Active Root </th>
			<th colspan=2> Approximate Mean Best-Case Boot Time </th>
			<th rowspan=2> Pros </th>
			<th rowspan=2> Cons </th>
		</tr>
		<tr>
			<th> Startup </th>
			<th> Shutdown </th>
		</tr>
	</thead>
	<tbody>
		<tr>
			<th> Non-RAM mode </th>
			<td> Treats the USB like a proper OS installation. </td>
			<td> <code>ext4</code> on <code>/dev/sdb3</code> </td>
			<td> 00:00.00 </td>
			<td> 00:00.00 </td>
			<td>
				<ul>
					<li> Fast startup and shutdown </li>
					<li> Stable boot state </li>
					<li> Consistent file saving </li>
				</ul>
			</td>
			<td>
				<ul>
					<li> Extremely slow/laggy GUI/OS </li>
					<li> Services and Applications may fail due to speed issues </li>
				</ul>
			</td>
		</tr>
		<tr>
			<th> Overlay mode/Partial RAM mode </th>
			<td> Uses Linux's hybrid Overlay Filesystem to efficiently load the OS to RAM while not copying the whole filesystem to RAM.</td>
			<td> <code>tmpfs</code> on RAM (or <code>/.ramroot-private/upper/upper</code>) </td>
			<td> 6 </td>
			<td> 00:00.00 </td>
			<td>
				<ul>
					<li> A proper compromise between startup/shutdown speed and active-RAM speed </li>
					<li> Efficient allocation of RAM </li>
					<li> Regular snapshots that save to disk regularly </li>
				</ul>
			</td>
			<td>
				<ul>
					<li> Moderately Unstable </li>
					<li> Moderately slow startup/shutdown </li>
					<li> Potential data loss if a shutdown is prematurely triggered </li>
					<li> RAM usage spikes on 10-minute intervals (but does not take priority) </li>
				</ul>
			</td>
		</tr>
		<tr>
			<th> Full-RAM mode/RAM-only mode </th>
			<td> Copies (almost) all of the contents of the USB to RAM. </td>
			<td> <code>tmpfs</code> on RAM </td>
			<td> 6 </td>
			<td> 1.5 </td>
			<td>
				<ul>
					<li> Runs the OS near-independently of the USB connection </li>
					<li> Low computational complexity </li>
					<li> Will not write to USB if disconnected, but will still run </li>
				</ul>
			</td>
			<td>
				<ul>
					<li> Slightly Unstable </li>
					<li> Very slow startup/shutdown </li>
					<li> Potential data loss if a shutdown is prematurely triggered </li>
					<li> Requires a computer with enough memory (8 GB or more) </li>
				</ul>
			</td>
		</tr>
		<tr>
			<th> Emergency Full-RAM Rollback mode </th>
			<td> Uses Linux's hybrid Overlay Filesystem to efficiently load the OS to RAM while not copying the whole filesystem to RAM.</td>
			<td> <code>tmpfs</code> on RAM (or <code>/.ramroot-private/upper/upper</code>) </td>
			<td colspan=4>
				This mode is similar in operation to Full-RAM mode but is done with the intent to have a fallback in the case of failiure, using a previous stable version of initramfs from a previous iteration of the code.
			</td>
		</tr>
  </tbody>
</table>

Notes:

- RAM-only mode does not save cached data marked as temporary e.g. `/tmp`, `/proc`, and `~/.cache`
- The "Filesystem Mounted as Active Root" is meant to mean "If you ran the command `sudo -- bash -c 'echo "hi" > /test.txt'`, where on the system would the `test.txt` file be initially saved to?"
- The startup/shutdown time was tested to be from the GRUB menu entry selection to the login screen appearing and the Xfce GUI disappearing to the computer power button turning off/true screen blank. Testing was done on a run with no direct filesystem changes i.e. login -> load Desktop -> select restart -> trigger restart
- The GRUB menu offers both a Desktop (GUI) and Terminal-only entry for each mode

## Configuration and Deployment

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
