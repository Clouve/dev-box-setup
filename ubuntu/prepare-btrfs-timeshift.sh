#!/usr/bin/env bash
#
# prepare-btrfs-timeshift.sh
# -----------------------------------------------------------------------------
# Converts a fresh Ubuntu BTRFS install into the "Ubuntu-type" subvolume layout
# (@ for /, @home for /home, @swap for the swapfile) that Timeshift's BTRFS mode
# requires, then fixes /etc/fstab and reinstalls GRUB so the system still boots.
#
# WHY: The Ubuntu installer (24.04 LTS onward, including 26.04) creates a FLAT
# BTRFS root with NO subvolumes when you select BTRFS. Timeshift's BTRFS mode
# refuses to work without @ and @home. This script performs the one-time
# conversion that the installer no longer does for you.
#
# RUN THIS FROM A UBUNTU LIVE USB ("Try Ubuntu"), booted in UEFI mode, on the
# machine whose installed disk you want to convert. Do NOT run it against the
# disk you are currently booted from.
#
# Usage:
#   sudo ./prepare-btrfs-timeshift.sh <ROOT_BTRFS_PARTITION> [EFI_PARTITION]
#
# Examples:
#   sudo ./prepare-btrfs-timeshift.sh /dev/nvme0n1p2 /dev/nvme0n1p1
#   sudo ./prepare-btrfs-timeshift.sh /dev/sda2          # auto-detect ESP
#
# With no arguments it prints your disks and exits so you can choose.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- knobs ------------------------------------------------------------------
HANDLE_SWAP="${HANDLE_SWAP:-true}"   # move the swapfile into its own @swap subvol
SWAP_SIZE="${SWAP_SIZE:-}"           # e.g. 8G; empty = reuse size of existing swapfile
TOP="/mnt/btrfs-top"                 # mountpoint for the BTRFS top level (subvolid=5)
TGT="/mnt/btrfs-target"              # mountpoint for @ during the GRUB chroot
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

mnt() { mount "$@"; MOUNTED+=("${@: -1}"); }   # track the last arg (mountpoint)

# ---- preconditions ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run with sudo / as root."

if [ $# -lt 1 ]; then
  echo "No partition given. Here are your block devices:"
  echo
  lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINT
  echo
  echo "Re-run: sudo $0 <ROOT_BTRFS_PARTITION> [EFI_PARTITION]"
  exit 1
fi

ROOT_PART="$1"
EFI_PART="${2:-}"

[ -b "$ROOT_PART" ] || die "$ROOT_PART is not a block device."
[ "$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null)" = "btrfs" ] \
  || die "$ROOT_PART is not a BTRFS partition."

# Refuse to touch the disk the live session itself is running from.
LIVE_SRC="$(findmnt -rno SOURCE / || true)"
[ "$LIVE_SRC" = "$ROOT_PART" ] && die "$ROOT_PART is the running root. Boot a Live USB instead."

DISK="/dev/$(lsblk -no pkname "$ROOT_PART")"
[ -b "$DISK" ] || die "Could not determine parent disk for $ROOT_PART."

# Auto-detect the EFI System Partition on the same disk if not supplied.
if [ -z "$EFI_PART" ]; then
  EFI_PART="$(lsblk -lnpo NAME,FSTYPE "$DISK" | awk '$2=="vfat"{print $1; exit}')"
  [ -n "$EFI_PART" ] || die "No vfat/EFI partition found on $DISK. Pass it as the 2nd argument."
fi
[ -b "$EFI_PART" ] || die "$EFI_PART is not a block device."

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
[ -d /sys/firmware/efi ] && FIRMWARE="UEFI" || FIRMWARE="BIOS"

# ---- show the plan and confirm ---------------------------------------------
cat <<EOF

${c_ylw}This will MODIFY the installed system on $ROOT_PART.${c_rst}

  Target disk ......... $DISK   ($FIRMWARE firmware)
  Root partition ...... $ROOT_PART   (UUID=$ROOT_UUID)
  EFI partition ....... $EFI_PART
  Create subvolumes ... @  @home$([ "$HANDLE_SWAP" = true ] && echo "  @swap")
  Will rewrite ........ /etc/fstab  (a .bak is saved) and reinstall GRUB

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

# ---- decide: already-subvolumed vs. flat ------------------------------------
if [ -d "$TOP/@" ]; then
  warn "An '@' subvolume already exists — this install is NOT flat."
  warn "Skipping the destructive conversion. Will only verify @home and fix GRUB/fstab."
  ALREADY=true
else
  ALREADY=false
fi

if [ "$ALREADY" = false ]; then
  info "Creating @ subvolume and moving the root filesystem into it..."
  btrfs subvolume create "$TOP/@"

  shopt -s dotglob nullglob
  for entry in "$TOP"/*; do
    base="$(basename "$entry")"
    case "$base" in @|@home|@swap) continue ;; esac
    mv "$entry" "$TOP/@/"
  done
  shopt -u dotglob nullglob

  info "Creating @home subvolume and moving /home into it..."
  btrfs subvolume create "$TOP/@home"
  mkdir -p "$TOP/@/home"
  shopt -s dotglob nullglob
  for entry in "$TOP"/@/home/*; do
    mv "$entry" "$TOP/@home/"
  done
  shopt -u dotglob nullglob
fi

# Ensure @home exists even on the "already subvolumed" path.
if [ ! -d "$TOP/@home" ]; then
  info "Creating missing @home subvolume..."
  btrfs subvolume create "$TOP/@home"
  if [ -d "$TOP/@/home" ]; then
    shopt -s dotglob nullglob
    for entry in "$TOP"/@/home/*; do mv "$entry" "$TOP/@home/"; done
    shopt -u dotglob nullglob
  fi
fi
mkdir -p "$TOP/@/home"

# ---- swapfile -> @swap ------------------------------------------------------
SWAP_LINE=""
if [ "$HANDLE_SWAP" = true ]; then
  # Determine target size: reuse the existing swapfile's size unless overridden.
  if [ -z "$SWAP_SIZE" ] && [ -f "$TOP/@/swap.img" ]; then
    SWAP_SIZE="$(stat -c %s "$TOP/@/swap.img")"   # bytes
  fi
  [ -z "$SWAP_SIZE" ] && SWAP_SIZE="4G"

  info "Setting up @swap subvolume with a NOCOW swapfile (size: $SWAP_SIZE)..."
  rm -f "$TOP/@/swap.img"
  [ -d "$TOP/@swap" ] || btrfs subvolume create "$TOP/@swap"

  if btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
    btrfs filesystem mkswapfile --size "$SWAP_SIZE" "$TOP/@swap/swapfile"
  else
    # Fallback for older btrfs-progs: NOCOW must be set on the empty file first.
    truncate -s 0 "$TOP/@swap/swapfile"
    chattr +C "$TOP/@swap/swapfile"
    dd if=/dev/zero of="$TOP/@swap/swapfile" bs=1M \
       count="$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1048576)}')" status=progress
    chmod 600 "$TOP/@swap/swapfile"
    mkswap "$TOP/@swap/swapfile"
  fi
  mkdir -p "$TOP/@/swap"
  SWAP_LINE=1
fi

# ---- rewrite /etc/fstab -----------------------------------------------------
FSTAB="$TOP/@/etc/fstab"
[ -f "$FSTAB" ] || die "No /etc/fstab found in @ — refusing to continue."
cp -a "$FSTAB" "${FSTAB}.bak-timeshift"
info "Backed up fstab to /etc/fstab.bak-timeshift"

# Preserve the installer's root mount options, just clean out any subvol* and
# guarantee subvol=@ (re-used for @home).
ROOT_OPTS="$(awk -v u="$ROOT_UUID" '
  $1 ~ ("UUID="u) && $2=="/" && $3=="btrfs" {print $4; exit}' "$FSTAB")"
[ -z "$ROOT_OPTS" ] && ROOT_OPTS="defaults"
ROOT_OPTS="$(echo "$ROOT_OPTS" | tr ',' '\n' | grep -viE '^subvol(id)?=' | paste -sd, -)"
[ -z "$ROOT_OPTS" ] && ROOT_OPTS="defaults"

# Strip the old btrfs root line, any /home btrfs line, and all swap lines.
awk -v u="$ROOT_UUID" '
  $3=="swap" { next }
  $1 ~ ("UUID="u) && $2=="/"     && $3=="btrfs" { next }
  $1 ~ ("UUID="u) && $2=="/home" && $3=="btrfs" { next }
  { print }
' "$FSTAB" > "${FSTAB}.new"

{
  echo ""
  echo "# --- subvolume layout written by prepare-btrfs-timeshift.sh ---"
  echo "UUID=$ROOT_UUID  /       btrfs  ${ROOT_OPTS},subvol=@      0 1"
  echo "UUID=$ROOT_UUID  /home   btrfs  ${ROOT_OPTS},subvol=@home  0 2"
  if [ -n "$SWAP_LINE" ]; then
    echo "UUID=$ROOT_UUID  /swap   btrfs  defaults,subvol=@swap   0 0"
    echo "/swap/swapfile   none    swap   sw                      0 0"
  fi
} >> "${FSTAB}.new"

mv "${FSTAB}.new" "$FSTAB"
info "fstab rewritten:"
sed 's/^/    /' "$FSTAB"

# Top-level work is done; unmount it before the chroot.
umount "$TOP"; MOUNTED=("${MOUNTED[@]/$TOP}")

# ---- reinstall GRUB from a chroot on @ --------------------------------------
info "Chrooting into @ to reinstall GRUB..."
mkdir -p "$TGT"
mnt -o subvol=@ "$ROOT_PART" "$TGT"
mnt "$EFI_PART" "$TGT/boot/efi"
for b in /dev /dev/pts /proc /sys /run; do mnt --bind "$b" "$TGT$b"; done
if [ "$FIRMWARE" = "UEFI" ] && [ -d /sys/firmware/efi/efivars ]; then
  mnt --bind /sys/firmware/efi/efivars "$TGT/sys/firmware/efi/efivars"
fi

if [ "$FIRMWARE" = "UEFI" ]; then
  chroot "$TGT" /bin/bash -e <<'CHROOT'
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub
update-initramfs -u || true
CHROOT
else
  chroot "$TGT" /bin/bash -e <<CHROOT
grub-install --target=i386-pc --recheck "$DISK"
update-grub
update-initramfs -u || true
CHROOT
fi

info "Done. The cleanup trap will unmount everything."
echo
cat <<EOF
${c_grn}Conversion complete.${c_rst} Reboot, remove the Live USB, and let the system
start normally. Then:

  1. sudo apt install timeshift   (if not already installed)
  2. Launch Timeshift, choose BTRFS as the snapshot type.
     It should now detect @ and @home and let you take snapshots.

Optional, for booting directly into snapshots from the GRUB menu, install
grub-btrfs and timeshift-autosnap-apt on the running system afterwards.
EOF
