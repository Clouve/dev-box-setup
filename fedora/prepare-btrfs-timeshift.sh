#!/usr/bin/env bash
#
# prepare-btrfs-timeshift-fedora.sh
# -----------------------------------------------------------------------------
# Converts a fresh Fedora BTRFS install into the "Ubuntu-type" subvolume layout
# (@ for /, @home for /home) that Timeshift's BTRFS mode requires, then fixes
# /etc/fstab and the kernel command line so the system still boots.
#
# WHY: Fedora (since F33, through F43+) installs BTRFS with subvolumes named
# "root" (mounted /) and "home" (mounted /home), on a btrfs partition, with a
# SEPARATE ext4 /boot partition. Timeshift's BTRFS mode only recognises the
# Ubuntu-style @ / @home names, so it refuses to work on a stock Fedora layout.
# The fix is a subvolume RENAME (root -> @, home -> @home) plus updating fstab
# and the "rootflags=subvol=root" kernel argument that Fedora stores via grubby
# / BootLoaderSpec entries. No data is moved.
#
# Unlike the Ubuntu version, there is no swapfile to relocate: Fedora uses zram
# for swap by default, so there is no btrfs swapfile to worry about.
#
# RUN THIS FROM A LIVE USB (a Fedora live image is ideal, booted in UEFI mode)
# on the machine whose installed disk you want to convert. Do NOT run it against
# the disk you are currently booted from.
#
# Usage:
#   sudo ./prepare-btrfs-timeshift-fedora.sh <ROOT_BTRFS_PART> [BOOT_PART] [EFI_PART]
#
# Examples:
#   sudo ./prepare-btrfs-timeshift-fedora.sh /dev/nvme0n1p3 /dev/nvme0n1p2 /dev/nvme0n1p1
#   sudo ./prepare-btrfs-timeshift-fedora.sh /dev/sda3      # auto-detect /boot + ESP
#
# With no arguments it prints your disks and exits so you can choose.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- knobs ------------------------------------------------------------------
AUTORELABEL="${AUTORELABEL:-true}"   # touch /.autorelabel so SELinux relabels on
                                     # first boot (recommended after offline edits)
TOP="/mnt/btrfs-top"                 # mountpoint for the BTRFS top level (subvolid=5)
TGT="/mnt/btrfs-target"              # mountpoint for @ during the boot-config chroot
# -----------------------------------------------------------------------------

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_rst=$'\e[0m'
info()  { echo "${c_grn}==>${c_rst} $*"; }
warn()  { echo "${c_ylw}!! ${c_rst} $*"; }
die()   { echo "${c_red}ERROR:${c_rst} $*" >&2; exit 1; }

MOUNTED=()
cleanup() {
  set +e
  for ((i=${#MOUNTED[@]}-1; i>=0; i--)); do
    umount "${MOUNTED[$i]}" 2>/dev/null || umount -l "${MOUNTED[$i]}" 2>/dev/null
  done
}
trap cleanup EXIT
mnt() { mount "$@"; MOUNTED+=("${@: -1}"); }

# ---- preconditions ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run with sudo / as root."

if [ $# -lt 1 ]; then
  echo "No partition given. Here are your block devices:"
  echo
  lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINT
  echo
  echo "Re-run: sudo $0 <ROOT_BTRFS_PART> [BOOT_PART] [EFI_PART]"
  exit 1
fi

ROOT_PART="$1"
BOOT_PART="${2:-}"
EFI_PART="${3:-}"

[ -b "$ROOT_PART" ] || die "$ROOT_PART is not a block device."
[ "$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null)" = "btrfs" ] \
  || die "$ROOT_PART is not a BTRFS partition."

LIVE_SRC="$(findmnt -rno SOURCE / || true)"
[ "$LIVE_SRC" = "$ROOT_PART" ] && die "$ROOT_PART is the running root. Boot a Live USB instead."

DISK="/dev/$(lsblk -no pkname "$ROOT_PART")"
[ -b "$DISK" ] || die "Could not determine parent disk for $ROOT_PART."

# Auto-detect the EFI System Partition (vfat) on the same disk if not supplied.
if [ -z "$EFI_PART" ]; then
  EFI_PART="$(lsblk -lnpo NAME,FSTYPE "$DISK" | awk '$2=="vfat"{print $1; exit}')"
  [ -n "$EFI_PART" ] || die "No vfat/EFI partition found on $DISK. Pass it as the 3rd argument."
fi
[ -b "$EFI_PART" ] || die "$EFI_PART is not a block device."

# Auto-detect a separate /boot (ext4/ext3/xfs, not the root partition) if not supplied.
if [ -z "$BOOT_PART" ]; then
  BOOT_PART="$(lsblk -lnpo NAME,FSTYPE "$DISK" \
    | awk -v r="$ROOT_PART" '$1!=r && ($2=="ext4"||$2=="ext3"||$2=="xfs"){print $1; exit}')"
fi
if [ -n "$BOOT_PART" ]; then
  [ -b "$BOOT_PART" ] || die "$BOOT_PART is not a block device."
fi

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
[ -d /sys/firmware/efi ] && FIRMWARE="UEFI" || FIRMWARE="BIOS"

# ---- show the plan and confirm ---------------------------------------------
cat <<EOF

${c_ylw}This will MODIFY the installed Fedora system on $ROOT_PART.${c_rst}

  Target disk ........ $DISK   ($FIRMWARE firmware)
  Root (btrfs) ....... $ROOT_PART   (UUID=$ROOT_UUID)
  Separate /boot ..... ${BOOT_PART:-<none — /boot is inside the btrfs root>}
  EFI partition ...... $EFI_PART
  Rename subvolumes .. root -> @   and   home -> @home   (no data is moved)
  Will update ........ /etc/fstab, the kernel cmdline (rootflags=subvol=@),
                       and regenerate grub.cfg. fstab .bak is saved.
  SELinux relabel .... $([ "$AUTORELABEL" = true ] && echo "yes, on first boot (slower first boot)" || echo "no")

Make sure you have a backup of anything important on this disk.
EOF
read -rp "Type YES to proceed: " ans
[ "$ans" = "YES" ] || die "Aborted."

# ---- unmount any stray auto-mounts of the partition -------------------------
while read -r mp; do
  [ -n "$mp" ] && [ "$mp" != "/" ] && { info "Unmounting stray mount $mp"; umount "$mp" || umount -l "$mp"; }
done < <(findmnt -rno TARGET "$ROOT_PART" 2>/dev/null || true)

# ---- mount the BTRFS top level (subvolid=5) ---------------------------------
mkdir -p "$TOP"
mnt -o subvolid=5 "$ROOT_PART" "$TOP"

# ---- decide layout and rename ----------------------------------------------
if   [ -d "$TOP/@" ] && [ ! -d "$TOP/root" ]; then
  warn "An '@' subvolume already exists and 'root' does not — already converted."
  warn "Skipping rename; will only verify fstab and boot config."
  ALREADY=true
elif [ -d "$TOP/root" ] && [ ! -d "$TOP/@" ]; then
  ALREADY=false
elif [ -d "$TOP/root" ] && [ -d "$TOP/@" ]; then
  die "Both 'root' and '@' subvolumes exist — ambiguous. Inspect manually with: btrfs subvolume list $TOP"
else
  die "Neither 'root' nor '@' found at the btrfs top level. Unexpected layout — aborting."
fi

if [ "$ALREADY" = false ]; then
  info "Renaming subvolume  root  ->  @"
  mv "$TOP/root" "$TOP/@"
  if [ -d "$TOP/home" ]; then
    info "Renaming subvolume  home  ->  @home"
    mv "$TOP/home" "$TOP/@home"
  else
    warn "No separate 'home' subvolume found — leaving /home as-is."
  fi
fi

# ---- fix /etc/fstab ---------------------------------------------------------
FSTAB="$TOP/@/etc/fstab"
[ -f "$FSTAB" ] || die "No /etc/fstab found in @ — refusing to continue."
cp -a "$FSTAB" "${FSTAB}.bak-timeshift"
info "Backed up fstab to /etc/fstab.bak-timeshift"
sed -i -E 's/\bsubvol=root\b/subvol=@/g; s/\bsubvol=home\b/subvol=@home/g' "$FSTAB"
info "fstab updated:"
sed 's/^/    /' "$FSTAB"

# ---- mark SELinux relabel on first boot -------------------------------------
if [ "$AUTORELABEL" = true ]; then
  touch "$TOP/@/.autorelabel"
  info "Created /.autorelabel (SELinux will relabel on first boot)."
fi

# Done at top level; unmount before the chroot.
umount "$TOP"; MOUNTED=("${MOUNTED[@]/$TOP}")

# ---- fix the bootloader from a chroot on @ ----------------------------------
info "Chrooting into @ to fix the kernel command line and regenerate GRUB..."
mkdir -p "$TGT"
mnt -o subvol=@ "$ROOT_PART" "$TGT"
[ -n "$BOOT_PART" ] && mnt "$BOOT_PART" "$TGT/boot"
mnt "$EFI_PART" "$TGT/boot/efi"
for b in /dev /dev/pts /proc /sys /run; do mnt --bind "$b" "$TGT$b"; done
if [ "$FIRMWARE" = "UEFI" ] && [ -d /sys/firmware/efi/efivars ]; then
  mnt --bind /sys/firmware/efi/efivars "$TGT/sys/firmware/efi/efivars"
fi

chroot "$TGT" /bin/bash -e <<'CHROOT'
set -e
# Primary, Fedora-native fix: rewrite rootflags on every boot entry. grubby
# knows whether the args live in the BLS entries or in grubenv and updates the
# right place.
grubby --update-kernel=ALL --remove-args="rootflags=subvol=root" --args="rootflags=subvol=@"

# Belt-and-suspenders: catch any literal references grubby didn't touch, and the
# template that future kernels inherit from.
sed -i -E 's/\bsubvol=root\b/subvol=@/g' /boot/loader/entries/*.conf 2>/dev/null || true
[ -f /etc/kernel/cmdline ] && sed -i -E 's/\bsubvol=root\b/subvol=@/g' /etc/kernel/cmdline || true
[ -f /etc/default/grub ]   && sed -i -E 's/\bsubvol=root\b/subvol=@/g' /etc/default/grub   || true
if grub2-editenv /boot/grub2/grubenv list 2>/dev/null | grep -q 'subvol=root'; then
  ko="$(grub2-editenv /boot/grub2/grubenv list | sed -n 's/^kernelopts=//p' | sed -E 's/\bsubvol=root\b/subvol=@/g')"
  [ -n "$ko" ] && grub2-editenv /boot/grub2/grubenv set kernelopts="$ko"
fi

# Regenerate the main GRUB config (kernels live on the ext4 /boot, so this is light).
grub2-mkconfig -o /boot/grub2/grub.cfg

echo
echo "Resulting kernel args:"
grubby --info=ALL | grep -E '^(title|args)=' || true
CHROOT

info "Done. The cleanup trap will unmount everything."
echo
cat <<EOF
${c_grn}Conversion complete.${c_rst} Reboot, remove the Live USB, and let Fedora start
normally (first boot will be slower while SELinux relabels). Then:

  1. sudo dnf install timeshift     (if not already installed)
  2. Launch Timeshift, choose BTRFS as the snapshot type. It should now detect
     @ and @home and let you take snapshots.

Notes:
  * Fedora uses zram for swap by default, so there is no swapfile in your
    snapshots to worry about.
  * If the first boot fails to find root, boot the Live USB again and verify the
    BLS entries: cat /boot/loader/entries/*.conf  should show subvol=@.
  * The more idiomatic Fedora tool for the same job is snapper + grub-btrfs
    (which works with Fedora's native root/home names). Timeshift works fine
    after this conversion; just be aware future Fedora docs assume snapper.
EOF
