#!/bin/bash
# Pushes the repo's system/ files out to their real locations on dr-usb.
#
# Usage:
#   ./deploy-doctor-usb.sh            # deploy everything, with diff preview + confirmation
#   ./deploy-doctor-usb.sh --yes      # deploy everything, skip confirmation
#   ./deploy-doctor-usb.sh --dry-run  # show what would change, deploy nothing
#   ./deploy-doctor-usb.sh etc/grub.d/40_custom   # deploy just one file (path relative to system/)
#
# After deploying, this script automatically:
#   - rebuilds the initramfs (mkinitcpio -p linux) if anything under
#     system/etc/initcpio/ or system/etc/mkinitcpio* was deployed
#   - regenerates /boot/grub/grub.cfg (via a chroot into the real USB root if
#     booted from RAM/overlay) if system/etc/grub.d/* or
#     system/etc/default/grub was deployed
# Pass --no-post to skip both and do it yourself later.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/system"
ROOT_DEVICE="${DOCTOR_USB_ROOT_DEVICE:-/dev/sdb3}"
DRY_RUN=0
ASSUME_YES=0
NO_POST=0
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        --no-post) NO_POST=1 ;;
        --help|-h)
            sed -n '2,17p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) TARGETS+=("$arg") ;;
    esac
done

if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: $SRC_DIR not found (run this from inside the doctor-usb repo)" >&2
    exit 1
fi

# Build the file list: either everything under system/, or just the requested paths.
mapfile -t FILES < <(
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        (cd "$SRC_DIR" && find . -type f | sed 's#^\./##')
    else
        printf '%s\n' "${TARGETS[@]}"
    fi
)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Nothing to deploy."
    exit 0
fi

echo "doctor-usb deploy: ${#FILES[@]} file(s)"
echo

changed=()
for rel in "${FILES[@]}"; do
    src="$SRC_DIR/$rel"
    dest="/$rel"
    if [[ ! -f "$src" ]]; then
        echo "skip (not in repo): $rel" >&2
        continue
    fi
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        continue
    fi
    changed+=("$rel")
    echo "--- $dest ---"
    if [[ -f "$dest" ]]; then
        diff -u "$dest" "$src" || true
    else
        echo "(new file)"
    fi
    echo
done

if [[ ${#changed[@]} -eq 0 ]]; then
    echo "Already up to date; nothing to deploy."
    exit 0
fi

echo "${#changed[@]} file(s) differ from what's on disk."

if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run: no changes written."
    exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Deploy these ${#changed[@]} file(s) to the live system with sudo? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

for rel in "${changed[@]}"; do
    src="$SRC_DIR/$rel"
    dest="/$rel"
    sudo mkdir -p "$(dirname "$dest")"
    # Preserve the executable bit the repo copy has, and ownership/mode of scripts.
    if [[ -x "$src" ]]; then
        sudo install -o root -g root -m 0755 "$src" "$dest"
    else
        sudo install -o root -g root -m 0644 "$src" "$dest"
    fi
    echo "deployed: $dest"
done

needs_mkinitcpio=0
needs_grub=0
for rel in "${changed[@]}"; do
    case "$rel" in
        etc/initcpio/*|etc/mkinitcpio.conf|etc/mkinitcpio-overlay.conf|etc/mkinitcpio.d/*)
            needs_mkinitcpio=1 ;;
        etc/grub.d/*|etc/default/grub)
            needs_grub=1 ;;
    esac
done

if [[ $NO_POST -eq 1 ]]; then
    echo
    echo "--no-post: skipping initramfs rebuild / grub.cfg regeneration."
    exit 0
fi

if [[ $needs_mkinitcpio -eq 1 ]]; then
    echo
    echo "mkinitcpio-related file(s) changed; rebuilding initramfs images (mkinitcpio -p linux)..."
    sudo mkinitcpio -p linux
    echo "initramfs rebuild done."
fi

if [[ $needs_grub -eq 1 ]]; then
    echo
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
    if [[ "$root_fstype" != "tmpfs" && "$root_fstype" != "overlay" ]]; then
        echo "GRUB file(s) changed; regenerating grub.cfg directly (root is $root_fstype, not RAM)..."
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    else
        echo "GRUB file(s) changed; root is $root_fstype, regenerating grub.cfg via chroot into $ROOT_DEVICE..."
        sudo mkdir -p /mnt/realroot
        sudo mount "$ROOT_DEVICE" /mnt/realroot
        for d in dev proc sys run; do sudo mount --bind "/$d" "/mnt/realroot/$d"; done
        sudo mount --bind /boot /mnt/realroot/boot
        sudo chroot /mnt/realroot grub-mkconfig -o /boot/grub/grub.cfg
        sudo umount /mnt/realroot/boot /mnt/realroot/run /mnt/realroot/sys /mnt/realroot/proc /mnt/realroot/dev
        sudo umount /mnt/realroot
        sudo rmdir /mnt/realroot
    fi
    echo "grub.cfg regeneration done."
fi

echo
echo "Done."
