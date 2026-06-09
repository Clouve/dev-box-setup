#!/usr/bin/env bash
#
# add-fedora-to-grub.sh
# Adds Fedora to Ubuntu's GRUB menu by chainloading Fedora's own EFI bootloader,
# placed at the TOP of the menu (above Ubuntu). Ubuntu remains the default that
# auto-boots after the timeout.
#
# Layout produced:
#     Fedora                          <- from /etc/grub.d/09_fedora (this script)
#     Ubuntu                          * default (auto-boots)   [from 10_linux]
#     Advanced options for Ubuntu                              [from 10_linux]
#     UEFI Firmware Settings                                   [from 30_uefi-firmware]
#
# Why this layout: "Advanced options" is emitted by 10_linux immediately after
# "Ubuntu", so a custom entry cannot sit between them without editing 10_linux.
# Numbering Fedora's generator 09_* puts it just before the Ubuntu block instead.
#
# Safe: does NOT touch UEFI vars, partitions, bootloader binaries, or 10_linux.
#
# Usage:  sudo ./add-fedora-to-grub.sh
#
set -euo pipefail

# --- configuration ---------------------------------------------------------
FEDORA_ESP_UUID="0B55-F3E3"                 # Fedora's EFI System Partition (vfat) UUID
FEDORA_EFI_PATH="/EFI/fedora/shimx64.efi"   # Fedora's bootloader inside that ESP
MENU_TITLE="Fedora"                         # capital F
DEFAULT_OS="Ubuntu"                         # entry that auto-boots after timeout
GRUB_TIMEOUT_SECS=10                        # normal menu timeout
RECORDFAIL_TIMEOUT_SECS=10                  # timeout when previous boot didn't record success

GRUB_DEFAULT_FILE="/etc/default/grub"
FEDORA_GRUBD="/etc/grub.d/09_fedora"        # runs before 10_linux -> Fedora on top
CUSTOM_FILE="/etc/grub.d/40_custom"         # old location (cleaned up if present)
GRUB_CFG="/boot/grub/grub.cfg"
BACKUP_DIR="/var/backups/add-fedora-to-grub" # backups live OUTSIDE /etc/grub.d/ on purpose
MARK_BEGIN="### >>> add-fedora-to-grub BEGIN (managed) >>>"
MARK_END="### <<< add-fedora-to-grub END (managed) <<<"

# --- helpers ---------------------------------------------------------------
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'  "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

# backup_file PATH -- copy PATH into $BACKUP_DIR (never into /etc/grub.d/, where
# update-grub would execute it). Prints the backup path.
backup_file() {
    local src="$1" dst
    mkdir -p "$BACKUP_DIR"
    dst="$BACKUP_DIR/$(basename "$src").bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$src" "$dst"
    printf '%s\n' "$dst"
}

# set_grub_kv KEY VALUE -- idempotently set KEY=VALUE in $GRUB_DEFAULT_FILE
set_grub_kv() {
    local key="$1" val="$2"
    if grep -q "^[[:space:]]*${key}=" "$GRUB_DEFAULT_FILE"; then
        sed -i "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$GRUB_DEFAULT_FILE"
    elif grep -q "^[[:space:]]*#[[:space:]]*${key}=" "$GRUB_DEFAULT_FILE"; then
        sed -i "s|^[[:space:]]*#[[:space:]]*${key}=.*|${key}=${val}|" "$GRUB_DEFAULT_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$GRUB_DEFAULT_FILE"
    fi
}

# --- preconditions ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo $0"
command -v update-grub >/dev/null 2>&1 || die "update-grub not found (Debian/Ubuntu GRUB system expected)."
[ -f "$GRUB_DEFAULT_FILE" ] || die "$GRUB_DEFAULT_FILE not found."

bold "==> Checking that Fedora's EFI partition (UUID $FEDORA_ESP_UUID) is present..."
if command -v blkid >/dev/null 2>&1 && blkid -U "$FEDORA_ESP_UUID" >/dev/null 2>&1; then
    green "Found: $(blkid -U "$FEDORA_ESP_UUID")"
elif lsblk -rno UUID | grep -qiw "$FEDORA_ESP_UUID"; then
    green "Found Fedora ESP UUID via lsblk."
else
    die "No filesystem with UUID $FEDORA_ESP_UUID found. Re-check with: lsblk -f"
fi
echo

# --- 0. relocate any stray backups left inside /etc/grub.d/ ----------------
# update-grub EXECUTES every executable file in /etc/grub.d/. A leftover *.bak
# that still contains a menuentry would emit a duplicate (this is exactly the
# bug that produced an extra Fedora entry). Move any such files out.
bold "==> Checking for stray backup files inside /etc/grub.d/ ..."
shopt -s nullglob
stray=(/etc/grub.d/*.bak.* /etc/grub.d/*.bak)
if [ "${#stray[@]}" -gt 0 ]; then
    mkdir -p "$BACKUP_DIR"
    for f in "${stray[@]}"; do
        mv -f "$f" "$BACKUP_DIR/"
        red "  moved out of grub.d: $(basename "$f") -> $BACKUP_DIR/"
    done
    green "Stray backups relocated (they will no longer be run by update-grub)."
else
    green "None found."
fi
shopt -u nullglob
echo

# --- 1. /etc/default/grub: timeout + keep Ubuntu as default ----------------
bold "==> Updating $GRUB_DEFAULT_FILE (timeout=${GRUB_TIMEOUT_SECS}s, default=${DEFAULT_OS})"
BACKUP_DEF="$(backup_file "$GRUB_DEFAULT_FILE")"
set_grub_kv GRUB_TIMEOUT "$GRUB_TIMEOUT_SECS"
set_grub_kv GRUB_TIMEOUT_STYLE menu
# Ubuntu uses GRUB_RECORDFAIL_TIMEOUT (default 30) when the previous boot didn't
# record success -- which happens every time you boot Fedora instead of Ubuntu.
set_grub_kv GRUB_RECORDFAIL_TIMEOUT "$RECORDFAIL_TIMEOUT_SECS"
# Fedora is now menu index 0; pin the default to Ubuntu by title so it still
# auto-boots after the countdown.
set_grub_kv GRUB_DEFAULT "\"${DEFAULT_OS}\""
green "Set: $(grep '^GRUB_TIMEOUT='            "$GRUB_DEFAULT_FILE")"
green "Set: $(grep '^GRUB_TIMEOUT_STYLE='      "$GRUB_DEFAULT_FILE")"
green "Set: $(grep '^GRUB_RECORDFAIL_TIMEOUT=' "$GRUB_DEFAULT_FILE")"
green "Set: $(grep '^GRUB_DEFAULT='            "$GRUB_DEFAULT_FILE")"
echo

# --- 2. remove any old Fedora entry from 40_custom -------------------------
if [ -f "$CUSTOM_FILE" ] && grep -qF "$MARK_BEGIN" "$CUSTOM_FILE"; then
    bold "==> Removing previous Fedora entry from $CUSTOM_FILE (moving it to $FEDORA_GRUBD)"
    backup_file "$CUSTOM_FILE" >/dev/null
    sed -i "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$CUSTOM_FILE"
    green "Old entry removed."
    echo
fi

# --- 3. write /etc/grub.d/09_fedora (Fedora on top) ------------------------
bold "==> Writing $FEDORA_GRUBD (Fedora entry, runs before 10_linux)"
[ -f "$FEDORA_GRUBD" ] && backup_file "$FEDORA_GRUBD" >/dev/null
cat > "$FEDORA_GRUBD" <<EOF
#!/bin/sh
exec tail -n +3 "\$0"
# Custom Fedora chainload entry (managed by add-fedora-to-grub.sh). Lines 1-2 are
# consumed by grub-mkconfig; everything below is copied verbatim into grub.cfg.
menuentry "$MENU_TITLE" --class fedora --class gnu-linux --class os {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root $FEDORA_ESP_UUID
    chainloader $FEDORA_EFI_PATH
}
EOF
chmod 0755 "$FEDORA_GRUBD"
green "Wrote and made executable: $FEDORA_GRUBD"
echo

# --- 4. regenerate grub.cfg ------------------------------------------------
bold "==> Regenerating GRUB configuration (update-grub)..."
update-grub
echo

# --- 5. verify -------------------------------------------------------------
bold "==> Verifying menu entries and order..."
if [ ! -f "$GRUB_CFG" ]; then
    die "$GRUB_CFG not found after update-grub."
fi
fed_count=$(grep -c "^menuentry .${MENU_TITLE}." "$GRUB_CFG" || true)
fed_line=$(grep -n "^menuentry .${MENU_TITLE}." "$GRUB_CFG" | head -1 | cut -d: -f1 || true)
ubu_line=$(grep -n "^menuentry .${DEFAULT_OS}." "$GRUB_CFG" | head -1 | cut -d: -f1 || true)

if [ "${fed_count:-0}" -gt 1 ]; then
    red "WARNING: found $fed_count '$MENU_TITLE' entries (expected 1). Duplicate(s) still present."
    red "Check for extra executable files in /etc/grub.d/:  ls -la /etc/grub.d/"
else
    green "Exactly one '$MENU_TITLE' entry (good, no duplicates)."
fi

if [ -z "$fed_line" ]; then
    red "WARNING: '$MENU_TITLE' entry not found in $GRUB_CFG. Check update-grub output above."
    red "Revert default config with: sudo cp '$BACKUP_DEF' '$GRUB_DEFAULT_FILE' && sudo update-grub"
    exit 1
fi
green "Found '$MENU_TITLE' at grub.cfg line $fed_line."
if [ -n "$ubu_line" ]; then
    green "Found '$DEFAULT_OS' at grub.cfg line $ubu_line."
    if [ "$fed_line" -lt "$ubu_line" ]; then
        green "ORDER OK: $MENU_TITLE appears above $DEFAULT_OS."
    else
        red "NOTE: $MENU_TITLE is below $DEFAULT_OS (unexpected). Check grub.d ordering."
    fi
fi
echo
green "Done. Reboot: menu shows '$MENU_TITLE' on top; '$DEFAULT_OS' auto-boots after ${GRUB_TIMEOUT_SECS}s."
bold  "Backup of $GRUB_DEFAULT_FILE: $BACKUP_DEF"
