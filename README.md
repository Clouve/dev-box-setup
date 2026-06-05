# dev-box-setup

Helper scripts that prepare a freshly‑installed Linux dev box so that
[**Timeshift**](https://github.com/linuxmint/timeshift)'s **BTRFS snapshot mode**
works out of the box.

Two scripts, one per distribution:

| Script | For | What it does |
|--------|-----|--------------|
| [`ubuntu/prepare-btrfs-timeshift.sh`](ubuntu/prepare-btrfs-timeshift.sh) | Ubuntu 24.04 LTS → 26.04+ | **Creates** `@` / `@home` (and optional `@swap`) subvolumes and **moves** your data into them |
| [`fedora/prepare-btrfs-timeshift.sh`](fedora/prepare-btrfs-timeshift.sh) | Fedora 33 → 43+ | **Renames** the stock `root` / `home` subvolumes to `@` / `@home` (no data moved) |

Both scripts are **run once**, from a **Live USB**, against the *installed* disk — never against the disk you are currently booted from.

---

## Why this is needed

Timeshift's BTRFS mode is hard‑coded to look for two subvolumes named **`@`** (mounted at `/`) and **`@home`** (mounted at `/home`). If they aren't there, Timeshift simply refuses to use BTRFS mode. Neither Ubuntu nor Fedora gives you that exact layout out of the box:

- **Ubuntu** creates a **flat** BTRFS filesystem — your whole root lives at the top level with **no subvolumes at all**. Timeshift sees nothing it recognizes.
- **Fedora** *does* use subvolumes, but names them **`root`** and **`home`** (its native convention). Timeshift doesn't recognize those names.

These scripts perform the one‑time conversion to the `@` / `@home` layout and then repair `/etc/fstab` and the bootloader so the machine still boots afterward.

> **Note on Fedora:** the *idiomatic* Fedora tool for snapshots is `snapper` + `grub-btrfs`, which works happily with Fedora's native `root`/`home` names. Use the Fedora script here only if you specifically want **Timeshift**. (The script prints this same reminder at the end.)

### How the two differ

| | Ubuntu | Fedora |
|---|--------|--------|
| Stock BTRFS layout | Flat (no subvolumes) | Subvolumes `root`, `home` |
| Conversion | Create `@`/`@home`, **move** data | **Rename** `root`→`@`, `home`→`@home` |
| `/boot` location | Inside the BTRFS root | **Separate ext4 partition** |
| Bootloader fix | `grub-install` + `update-grub` | `grubby --update-kernel=ALL` + `grub2-mkconfig` |
| Swap | btrfs swapfile relocated to `@swap` | none needed (Fedora uses **zram**) |
| SELinux | n/a | Triggers a relabel on first boot |
| Script arguments | `<ROOT> [EFI]` | `<ROOT> [BOOT] [EFI]` |

---

## Safety first — read before you run

- ⚠️ **Back up anything important.** The Ubuntu script moves data between subvolumes and rewrites the bootloader. The Fedora script is lighter (a rename), but still edits boot config. Both ask you to type `YES` before doing anything.
- 🔌 **Boot from a Live USB.** The scripts refuse to run against the partition the live session itself is mounted on. Do **not** try to convert a system from inside itself.
- 🖥️ **Use UEFI.** Boot the Live USB in UEFI mode (the scripts auto‑detect UEFI vs. BIOS, but UEFI is the tested path on modern hardware).
- 🔋 **Stay on AC power** during the conversion.
- 🧪 **Dry run for free:** run either script with **no arguments** and it just prints your disks (`lsblk`) and exits — nothing is changed. Use this to discover your partition names safely.

---

## Part A — Install the base OS (with BTRFS)

You need a working install *first*; the scripts convert it afterward. The only thing that matters here is that your **root (`/`) filesystem ends up on BTRFS**.

### A1. Ubuntu

Ubuntu's installer does **not** use BTRFS by default — you must choose it.

1. **Download** the Ubuntu Desktop ISO (24.04 LTS or newer) from <https://ubuntu.com/download/desktop>.
2. **Write it to a USB stick** (≥ 4 GB):
   - Linux/macOS: `sudo dd if=ubuntu-24.04-desktop-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync` (replace `/dev/sdX` with your USB device — double‑check with `lsblk`!)
   - Cross‑platform GUI: [balenaEtcher](https://etcher.balena.io/) or [Rufus](https://rufus.ie/) (Windows).
3. **Boot the USB in UEFI mode** and pick **"Try or Install Ubuntu."**
4. In the installer, choose **Manual / "Something else"** partitioning (this is the reliable way to force BTRFS). Create:
   - an **EFI System Partition** — ~512 MB–1 GB, **FAT32**, mount point `/boot/efi`;
   - a **root partition** filling the rest, formatted **btrfs**, mount point `/`.
   > Some Ubuntu releases also expose BTRFS under *Erase disk → Advanced features*. Either path is fine — the result is the same flat BTRFS that this script fixes.
5. Finish the install and reboot **once** into Ubuntu to confirm it works. You now have a *flat* BTRFS root — exactly what the Ubuntu script expects.

**Resulting partitions (typical UEFI install):**

```
/dev/nvme0n1p1   vfat    EFI System Partition   ← EFI arg
/dev/nvme0n1p2   btrfs   /  (flat, no subvols)  ← ROOT arg
```

### A2. Fedora

Fedora Workstation uses **BTRFS by default** since F33 — automatic partitioning already gives you the `root`/`home` subvolumes the Fedora script expects, so there's nothing special to configure.

1. **Download** Fedora Workstation (F33+; tested through F43+) from <https://fedoraproject.org/workstation/>.
2. **Write it to USB** with [Fedora Media Writer](https://fedoraproject.org/workstation/download/) (recommended), balenaEtcher, or `dd` (same command as above).
3. **Boot the USB in UEFI mode** and choose **"Install to Hard Drive."**
4. At the storage step, just use **Automatic** partitioning. Fedora will create a BTRFS root with `root` and `home` subvolumes, a separate ext4 `/boot`, and an EFI System Partition.
5. Finish and reboot **once** into Fedora to confirm it works.

**Resulting partitions (typical UEFI install):**

```
/dev/nvme0n1p1   vfat    EFI System Partition           ← EFI arg
/dev/nvme0n1p2   ext4    /boot (separate)               ← BOOT arg
/dev/nvme0n1p3   btrfs   /  (subvols: root, home)       ← ROOT arg
```

---

## Part B — Boot a Live USB and find your partitions

The conversion must happen while the target system is **offline**, so boot a Live USB again (for Ubuntu use an Ubuntu live image; for Fedora a Fedora live image is ideal) and choose **"Try"** rather than "Install."

Open a terminal and identify the partitions:

```bash
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINT
```

Look for:

- the **btrfs** partition → your **ROOT** argument;
- the **vfat** partition → the **EFI** argument (auto‑detected if omitted);
- *(Fedora only)* the small **ext4** partition → the **BOOT** argument (auto‑detected if omitted).

Then copy this repo onto the live session (e.g. `git clone https://github.com/Clouve/dev-box-setup.git`, or from a second USB stick).

---

## Part C — Run the conversion

### C1. Ubuntu

```bash
cd dev-box-setup/ubuntu
sudo ./prepare-btrfs-timeshift.sh <ROOT_BTRFS_PARTITION> [EFI_PARTITION]
```

**Examples**

```bash
# Explicit root + EFI
sudo ./prepare-btrfs-timeshift.sh /dev/nvme0n1p2 /dev/nvme0n1p1

# Let it auto-detect the EFI System Partition on the same disk
sudo ./prepare-btrfs-timeshift.sh /dev/sda2

# No arguments → just print the disk list and exit (safe)
sudo ./prepare-btrfs-timeshift.sh
```

**Tunable environment variables**

| Variable | Default | Effect |
|----------|---------|--------|
| `HANDLE_SWAP` | `true` | Move the swapfile into a dedicated `@swap` subvolume (kept out of snapshots). Set `false` to skip swap entirely. |
| `SWAP_SIZE` | reuse existing `swap.img` size, else `4G` | Size of the new NOCOW swapfile, e.g. `8G`. |

```bash
# Skip swap handling
sudo HANDLE_SWAP=false ./prepare-btrfs-timeshift.sh /dev/nvme0n1p2

# Force an 8 GB swapfile
sudo SWAP_SIZE=8G ./prepare-btrfs-timeshift.sh /dev/nvme0n1p2 /dev/nvme0n1p1
```

**What it does, step by step**

1. Mounts the BTRFS *top level* (`subvolid=5`).
2. Creates `@` and moves the entire root filesystem into it; creates `@home` and moves `/home` into it.
3. *(If `HANDLE_SWAP=true`)* creates `@swap` with a **NOCOW** swapfile (`chattr +C` — required so BTRFS doesn't corrupt swap).
4. Backs up `/etc/fstab` to `/etc/fstab.bak-timeshift` and rewrites it for the new `subvol=@` / `subvol=@home` (and `@swap`) mounts.
5. Chroots into `@` and reinstalls GRUB (`grub-install` + `update-grub`, UEFI or BIOS as detected).

### C2. Fedora

```bash
cd dev-box-setup/fedora
sudo ./prepare-btrfs-timeshift.sh <ROOT_BTRFS_PART> [BOOT_PART] [EFI_PART]
```

**Examples**

```bash
# Explicit root + /boot + EFI
sudo ./prepare-btrfs-timeshift.sh /dev/nvme0n1p3 /dev/nvme0n1p2 /dev/nvme0n1p1

# Let it auto-detect the separate /boot and the EFI System Partition
sudo ./prepare-btrfs-timeshift.sh /dev/sda3

# No arguments → just print the disk list and exit (safe)
sudo ./prepare-btrfs-timeshift.sh
```

**Tunable environment variables**

| Variable | Default | Effect |
|----------|---------|--------|
| `AUTORELABEL` | `true` | Touch `/.autorelabel` so SELinux relabels the filesystem on first boot (recommended after any offline edit). First boot will be slower. Set `false` to skip. |

**What it does, step by step**

1. Mounts the BTRFS top level (`subvolid=5`).
2. **Renames** subvolumes `root` → `@` and `home` → `@home` (no data is moved).
3. Backs up `/etc/fstab` to `/etc/fstab.bak-timeshift` and rewrites `subvol=root`/`subvol=home` to `subvol=@`/`subvol=@home`.
4. *(If `AUTORELABEL=true`)* creates `/.autorelabel`.
5. Chroots into `@` and rewrites the kernel command line on every boot entry with
   `grubby --update-kernel=ALL` (`rootflags=subvol=root` → `subvol=@`), with belt‑and‑suspenders `sed` fallbacks on the BLS entries, `/etc/kernel/cmdline`, `/etc/default/grub`, and `grubenv`, then regenerates `grub.cfg`.

---

## Part D — After conversion: turn on Timeshift

Reboot, remove the Live USB, and let the system start normally.
*(Fedora's first boot will be slower while SELinux relabels — this is expected.)*

```bash
# Ubuntu
sudo apt install timeshift

# Fedora
sudo dnf install timeshift
```

Launch **Timeshift → choose "BTRFS" as the snapshot type.** It should now detect `@` and `@home` and let you take snapshots.

**Optional — boot directly into snapshots from the GRUB menu:**

- **Ubuntu:** install `grub-btrfs` and `timeshift-autosnap-apt`.
- **Fedora:** install `grub-btrfs` (auto‑snapshot on `dnf` is available via `timeshift-autosnap`‑style hooks, or use snapper's own integration).

---

## Verifying success

After rebooting into the converted system:

```bash
# Subvolumes should now include @ and @home
sudo btrfs subvolume list /

# The active root should be mounted with subvol=@
findmnt /            # SOURCE should show [/@]
findmnt /home        # SOURCE should show [/@home]

# fstab should reference subvol=@ / subvol=@home
grep btrfs /etc/fstab
```

If Timeshift's BTRFS option is still greyed out, double‑check the subvolume **names** are exactly `@` and `@home`.

---

## Idempotency & re‑running

Both scripts are safe to re‑run:

- **Ubuntu** — if an `@` subvolume already exists, it skips the destructive move and only verifies `@home` and re‑fixes fstab/GRUB.
- **Fedora** — if `@` exists and `root` doesn't, it reports "already converted" and only verifies fstab/boot config. If **both** `root` and `@` exist, it stops (ambiguous) and asks you to inspect manually with `btrfs subvolume list`.

---

## Troubleshooting / recovery

**The system won't boot after conversion.**
Boot the Live USB again and inspect the boot config:

- *Ubuntu:* re‑run the script (idempotent) — it will re‑fix fstab and reinstall GRUB.
- *Fedora:* check the BLS entries — `cat /boot/loader/entries/*.conf` should show `subvol=@`. If any still say `subvol=root`, re‑run the script.

**"`X` is not a BTRFS partition."**
You passed the wrong partition. Run with no arguments and re‑read the `lsblk` output — the ROOT argument must be the **btrfs** row.

**"`X` is the running root. Boot a Live USB instead."**
You're trying to convert the disk you booted from. Boot a Live USB and target the *installed* disk.

**"No vfat/EFI partition found."** *(or, Fedora, no `/boot`)*
Auto‑detection failed (e.g. ESP on a different disk). Pass the partition explicitly as the trailing argument.

**Restore the old fstab.**
A backup is always saved at `/etc/fstab.bak-timeshift` inside the `@` subvolume.

---

## Repository layout

```
dev-box-setup/
├── ubuntu/
│   └── prepare-btrfs-timeshift.sh   # flat → @/@home/@swap (move data)
└── fedora/
    └── prepare-btrfs-timeshift.sh   # root/home → @/@home (rename only)
```

Both scripts are self‑contained Bash (`set -euo pipefail`), require **root**, track every mount they make and unmount it on exit (even on failure), and print a colored plan you must confirm with `YES` before any change is made.
