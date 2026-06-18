#!/usr/bin/env bash
#
# install-paru-nvidia.sh
# ----------------------
# One-shot Arch Linux bootstrap for the GTX 1050 Ti (Pascal / GP107).
#
# What this script does:
#   1. Enables [multilib].
#   2. Installs base-devel, git, kernel headers, dkms.
#   3. Builds & installs paru (AUR helper).
#   4. Adds the CachyOS third-party repo (keyring + mirrorlist from AUR,
#      then registers [cachyos] in pacman.conf).
#   5. Installs your extra apps:
#        - prismlauncher            (from [extra])
#        - helium-browser-bin       (AUR)
#        - zen-browser-bin          (AUR)
#        - localsend-bin            (AUR)
#        - spotify                  (AUR)
#   6. Installs BIOS / firmware tooling:
#        - fwupd                    (LVFS firmware + BIOS updates)
#        - dmidecode                (read SMBIOS / DMI tables)
#   7. Installs the NVIDIA 580xx legacy driver for Pascal (AUR):
#        - nvidia-580xx-dkms
#        - nvidia-580xx-utils
#        - lib32-nvidia-580xx-utils
#        - nvidia-settings
#   8. Configures mkinitcpio (early KMS) + nvidia_drm.modeset=1.
#   9. Regenerates initramfs for every installed kernel.
#
# Reference: https://wiki.archlinux.org/title/NVIDIA
#   Pascal/Maxwell/Volta are now on the nvidia-580xx legacy branch (AUR).
#
# NOTE: Run this as a NORMAL USER with sudo privileges.
#       paru MUST be built as a non-root user (makepkg refuses root).
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------- pretty logging ----------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[*]${NC} $*"; }
ok()      { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ---------- pre-flight checks -------------------------------------------------
[[ "$(id -u)" -eq 0 ]] && die "Do NOT run this script as root. Run as a normal user with sudo access."

if ! grep -qi 'arch' /etc/os-release 2>/dev/null; then
    warn "This doesn't appear to be Arch Linux. Continuing anyway, but expect breakage."
fi

command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed."
command -v git  >/dev/null 2>&1 || die "git is required but not installed."

# Confirm the GPU is actually a 1050 Ti (best-effort, non-fatal)
if command -v lspci >/dev/null 2>&1; then
    gpu_line="$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' || true)"
    echo -e "${BLUE}[*]${NC} Detected graphics device(s):"
    echo "$gpu_line"
    if ! echo "$gpu_line" | grep -qi '1050'; then
        warn "No '1050' string found in lspci. The 580xx branch will still be installed"
        warn "since it covers all Pascal (GP10x/GP100) and Maxwell/Volta chips."
    fi
fi

echo
log "This script will:"
echo "    - enable [multilib]"
echo "    - install base-devel, git, kernel headers, dkms"
echo "    - build & install paru (AUR helper)"
echo "    - add the CachyOS repo via the OFFICIAL CachyOS installer"
echo "      (imports their GPG key, installs their patched pacman, detects"
echo "       x86-64-v3/v4/znver4 ISA level, and runs 'pacman -Syu' at the end)"
echo "    - install apps: prismlauncher, helium-browser-bin, zen-browser-bin,"
echo "      localsend-bin, spotify"
echo "    - install BIOS/firmware tooling: fwupd, dmidecode"
echo "    - install NVIDIA 580xx legacy driver (Pascal) from AUR"
echo "    - configure mkinitcpio + bootloader for nvidia_drm.modeset=1"
echo "    - regenerate initramfs"
echo
read -rp "Proceed? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || { warn "Aborted by user."; exit 0; }

# ---------- 1. enable multilib ------------------------------------------------
log "Ensuring [multilib] is enabled in /etc/pacman.conf..."
if ! sudo grep -q '^\[multilib\]' /etc/pacman.conf; then
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    ok "multilib enabled."
else
    ok "multilib already enabled."
fi

# ---------- 2. sync & install base deps --------------------------------------
log "Syncing package databases and upgrading keyring..."
sudo pacman -Sy --noconfirm archlinux-keyring

log "Installing base dependencies (base-devel, git, headers)..."
# Detect which kernel is running and install matching headers.
KERNEL_PKGS=()
for k in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$k" >/dev/null 2>&1; then
        KERNEL_PKGS+=("${k}-headers")
    fi
done
[[ ${#KERNEL_PKGS[@]} -eq 0 ]] && KERNEL_PKGS+=("linux-headers")

sudo pacman -S --needed --noconfirm base-devel git "${KERNEL_PKGS[@]}" dkms

# ---------- 3. build & install paru ------------------------------------------
install_paru() {
    if command -v paru >/dev/null 2>&1; then
        ok "paru already installed ($(paru --version))."
        return 0
    fi

    local build_dir
    build_dir="$(mktemp -d /tmp/paru-build.XXXXXX)"
    log "Building paru in $build_dir ..."
    git clone --depth 1 https://aur.archlinux.org/paru.git "$build_dir"
    cd "$build_dir"
    # makepkg cannot run as root; it will invoke sudo internally for pacman.
    makepkg -si --noconfirm --needed
    cd - >/dev/null
    rm -rf "$build_dir"
    ok "paru installed: $(paru --version)"
}

install_paru

# ---------- 4. add CachyOS repo (official installer) -------------------------
# We use CachyOS's own installer script from
#     https://mirror.cachyos.org/cachyos-repo.tar.xz
# rather than building cachyos-keyring/cachyos-mirrorlist from the AUR.
#
# The official installer:
#   - imports CachyOS GPG key F3B607488DB35A47 via pacman-key
#   - installs cachyos-keyring + cachyos-mirrorlist (incl. v3/v4) + CachyOS's
#     patched pacman directly from their mirror via 'pacman -U'
#   - detects CPU ISA level (x86-64-v3, v4, or znver4/5) and adds the matching
#     repo block to /etc/pacman.conf via gawk scripts
#   - backs up /etc/pacman.conf to /etc/pacman.conf.bak
#   - runs 'pacman -Syu' at the end (full system refresh + upgrade)
#
# IMPORTANT side effects of using the official installer:
#   1. It REPLACES Arch's pacman with CachyOS's patched pacman (needed for
#      proper v3/v4 repo handling). This is a system-critical component.
#   2. It runs 'pacman -Syu' — a full system upgrade — at the end.
#   3. It requires a CPU that supports x86-64-v3 (Haswell 2013+, Excavator,
#      Zen+). If your CPU is older, no CachyOS repo block will be added
#      (silent skip) and the rest of the script continues normally.
#
# Reference: https://wiki.cachyos.org/ (the curl|tar|sudo pattern)
add_cachyos_repo() {
    # Detect if any cachyos repo block is already present (v1/v3/v4/znver4).
    if sudo grep -qE '\[(cachyos|cachyos-v3|cachyos-core-v3|cachyos-extra-v3|cachyos-v4|cachyos-core-v4|cachyos-extra-v4|cachyos-znver4|cachyos-core-znver4|cachyos-extra-znver4)\]' /etc/pacman.conf; then
        ok "[cachyos] repo already present in pacman.conf — skipping installer."
        return 0
    fi

    log "Downloading the official CachyOS repo installer..."
    local build_dir
    build_dir="$(mktemp -d /tmp/cachyos-repo.XXXXXX)"
    pushd "$build_dir" >/dev/null

    curl -fL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xf cachyos-repo.tar.xz
    cd cachyos-repo

    log "Running CachyOS installer (sudo required; will run 'pacman -Syu' at end)..."
    # The installer script must run as root; pass --install explicitly.
    sudo ./cachyos-repo.sh --install

    popd >/dev/null
    rm -rf "$build_dir"

    # Verify a repo block was actually added (the installer silently skips if
    # the CPU doesn't support x86-64-v3).
    if sudo grep -qE '\[(cachyos|cachyos-v3|cachyos-v4|cachyos-znver4)' /etc/pacman.conf; then
        ok "CachyOS repo installed via official installer."
    else
        warn "CachyOS installer did not add a repo block. Your CPU probably does"
        warn "not support x86-64-v3. CachyOS packages will not be available; the"
        warn "rest of the script will continue normally without them."
    fi
}

add_cachyos_repo

# ---------- 5. install additional apps ---------------------------------------
log "Installing additional applications..."

# prismlauncher is in [extra] — no AUR build needed.
log "  -> prismlauncher (from [extra])"
sudo pacman -S --needed --noconfirm prismlauncher

# AUR apps via paru. spotify needs GPG key retrieval — if it fails, install
# `spotify`'s required key manually per the AUR page, then re-run.
log "  -> AUR apps: helium-browser-bin, zen-browser-bin, localsend-bin, spotify"
paru -S --needed --noconfirm \
    helium-browser-bin \
    zen-browser-bin \
    localsend-bin \
    spotify

ok "All additional apps installed."

# ---------- 6. BIOS / firmware tooling ---------------------------------------
# fwupd   - LVFS client; can install firmware/BIOS updates on supported
#           hardware (Lenovo, Dell, HP, Logitech, 8bitdo, etc.).
# dmidecode - reads SMBIOS/DMI tables (BIOS version, motherboard model, etc.).
log "Installing BIOS / firmware update tooling (fwupd, dmidecode)..."
sudo pacman -S --needed --noconfirm fwupd dmidecode

# Make sure the fwupd daemon is enabled so `fwupdmgr update` works after reboot.
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now fwupd.service 2>/dev/null || \
        warn "Could not enable fwupd.service (it may be socket-activated only)."
    ok "fwupd service enabled."
fi

ok "BIOS/firmware tooling installed. After reboot, run:"
echo "    sudo fwupdmgr refresh        # fetch latest LVFS metadata"
echo "    sudo fwupdmgr get-updates    # list available firmware/BIOS updates"
echo "    sudo fwupdmgr update         # apply them"
echo "    sudo dmidecode -t bios       # show current BIOS version"

# ---------- 7. remove conflicting mainline nvidia packages -------------------
# nvidia-580xx conflicts with nvidia / nvidia-dkms / nvidia-utils / lib32-nvidia-utils.
# Remove them first to avoid paru refusing to install due to file conflicts.
log "Removing any conflicting mainline NVIDIA packages..."
CONFLICT_PKGS=(
    nvidia
    nvidia-dkms
    nvidia-lts
    nvidia-utils
    lib32-nvidia-utils
    nvidia-open
    nvidia-open-dkms
    nvidia-open-lts
)
to_remove=()
for p in "${CONFLICT_PKGS[@]}"; do
    if pacman -Qq "$p" >/dev/null 2>&1; then
        to_remove+=("$p")
    fi
done
if [[ ${#to_remove[@]} -gt 0 ]]; then
    warn "Removing: ${to_remove[*]}"
    sudo pacman -Rdds --noconfirm "${to_remove[@]}" || \
        warn "Some packages could not be removed; paru will report conflicts if any remain."
else
    ok "No conflicting mainline NVIDIA packages present."
fi

# ---------- 8. NVIDIA 580xx driver for the 1050 Ti (Pascal) ------------------
# GTX 1050 Ti = GP107 (Pascal). Per Arch Wiki (NVIDIA page), Pascal/Maxwell/Volta
# are now on the nvidia-580xx legacy branch, available in the AUR.
log "Installing NVIDIA 580xx legacy driver (Pascal) from AUR..."
NVIDIA_PKGS=(
    nvidia-580xx-dkms          # kernel module, auto-rebuilds on kernel upgrade
    nvidia-580xx-utils         # userspace utilities (nvidia-smi, etc.)
    lib32-nvidia-580xx-utils   # 32-bit OpenGL/Vulkan for Steam/Wine
    nvidia-settings            # GUI control panel (from [extra], still compatible)
)

paru -S --needed --noconfirm "${NVIDIA_PKGS[@]}"

# ---------- 9. initramfs / mkinitcpio ----------------------------------------
log "Configuring mkinitcpio for NVIDIA early loading..."

MKINITCPIO="/etc/mkinitcpio.conf"

# The kernel module is still named 'nvidia' (the -580xx suffix is only on the
# Arch package name, not the .ko file). Add nvidia + submodules to MODULES so
# they load early in the initramfs.
MODULES_LINE="MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)"

if sudo grep -q '^MODULES=()' "$MKINITCPIO" 2>/dev/null; then
    sudo sed -i "s|^MODULES=()|${MODULES_LINE}|" "$MKINITCPIO"
elif sudo grep -q '^MODULES=' "$MKINITCPIO" 2>/dev/null; then
    # MODULES already has entries; append nvidia ones if missing.
    if ! sudo grep -q 'nvidia_drm' "$MKINITCPIO"; then
        sudo sed -i 's|^MODULES=(|MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm |' "$MKINITCPIO"
    fi
else
    echo "$MODULES_LINE" | sudo tee -a "$MKINITCPIO" >/dev/null
fi
ok "mkinitcpio MODULES updated."

# nvidia_drm.modeset=1 is needed for Wayland & proper DRM KMS.
log "Adding nvidia_drm.modeset=1 to kernel command line..."
if sudo grep -q 'nvidia_drm.modeset=1' /etc/default/grub 2>/dev/null; then
    ok "GRUB already has nvidia_drm.modeset=1."
elif [[ -f /etc/default/grub ]]; then
    sudo sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia_drm.modeset=1"|' /etc/default/grub
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    ok "GRUB updated."
elif command -v systemd-boot >/dev/null 2>&1; then
    warn "systemd-boot detected. Please add 'nvidia_drm.modeset=1' to your boot entry manually:"
    warn "    /boot/loader/entries/*.conf  or  /boot/efi/loader/entries/*.conf"
fi

# /etc/modprobe.d/nvidia.conf - ensure modeset is on even if cmdline is missed.
echo "options nvidia_drm modeset=1" | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null

# Regenerate initramfs for every installed kernel preset.
log "Regenerating initramfs..."
for preset in /etc/mkinitcpio.d/*.preset; do
    [[ -f "$preset" ]] || continue
    kname="$(basename "$preset" .preset)"
    log "  -> $kname"
    sudo mkinitcpio -P "$kname" || warn "mkinitcpio failed for $kname (review manually)."
done

# ---------- 10. summary ------------------------------------------------------
echo
ok "All done!"
echo
echo -e "${GREEN}Installed:${NC}"
echo "    - paru                       $(paru --version 2>/dev/null | head -n1 || echo '?')"
echo "    - CachyOS repo               (via official installer;"
echo "                                  /etc/pacman.conf.bak saved)"
echo "      - CachyOS patched pacman   $(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo '?')"
echo "      - cachyos-keyring          $(pacman -Q cachyos-keyring 2>/dev/null | awk '{print $2}' || echo '?')"
echo "      - cachyos-mirrorlist       $(pacman -Q cachyos-mirrorlist 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - prismlauncher              $(pacman -Q prismlauncher 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - helium-browser-bin         $(paru -Q helium-browser-bin 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - zen-browser-bin            $(paru -Q zen-browser-bin 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - localsend-bin              $(paru -Q localsend-bin 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - spotify                    $(paru -Q spotify 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - fwupd                      $(pacman -Q fwupd 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - dmidecode                  $(pacman -Q dmidecode 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - nvidia-580xx-dkms          $(pacman -Q nvidia-580xx-dkms 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - nvidia-580xx-utils         $(pacman -Q nvidia-580xx-utils 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    - lib32-nvidia-580xx-utils   $(pacman -Q lib32-nvidia-580xx-utils 2>/dev/null | awk '{print $2}' || echo '?')"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "    1. REBOOT your machine."
echo "    2. Verify the GPU:"
echo "         nvidia-smi"
echo "         glxinfo | grep 'OpenGL renderer'"
echo "    3. Check for BIOS/firmware updates:"
echo "         sudo fwupdmgr refresh"
echo "         sudo fwupdmgr get-updates"
echo "         sudo fwupdmgr update"
echo "    4. Keep everything updated:"
echo "         paru -Syu"
echo
echo -e "${YELLOW}Optional - CachyOS kernel:${NC}"
echo "    The [cachyos] repo is now available but the script did NOT swap your kernel."
echo "    If you want the BORE-scheduler CachyOS kernel, run manually:"
echo "         sudo pacman -S linux-cachyos linux-cachyos-headers"
echo "         sudo grub-mkconfig -o /boot/grub/grub.cfg"
echo "    (then reboot into it and remove the old kernel if you no longer want it)"
echo
warn "The nvidia-580xx branch is a 'legacy, still supported' branch per the Arch"
warn "wiki. It continues to receive security/critical fixes from NVIDIA but lags"
warn "behind the mainline branch (which is now Turing+ only)."
warn ""
warn "If Wayland gives you a black screen, ensure 'nvidia_drm.modeset=1' is present"
warn "in your bootloader config and reboot again."
warn ""
warn "If 'spotify' failed to build due to GPG key issues, see its AUR page:"
warn "    https://aur.archlinux.org/packages/spotify"
