#!/usr/bin/env bash
#
# install.sh — add Hyprland + a working desktop to a fresh Arch Linux or
# Fedora install. Fedora includes aarch64, and Fedora Asahi Remix on Apple
# silicon in particular.
#
# Designed to be re-run. On a second run it works out that packages and
# services are already in place and becomes a fast config refresh: only files
# that actually changed are touched, and anything you edited by hand is backed
# up before it is replaced.
#
#   ./install.sh              install, or refresh configs if already installed
#   ./install.sh --help       all options
#
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_SRC="$SCRIPT_DIR/config"
CONFIG_DST="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"

# Default fractional scale for generated monitor lines. Hyprland requires the
# scaled resolution to land on a whole pixel, so a scale is only used when it
# divides that display cleanly; otherwise the script falls back to 1 for that
# monitor and says so. 5120x2160 / (4/3) = 3840x1620, which is exact.
#
# DEFAULT_SCALE is the literal written into monitors.lua. Hyprland stores
# scales as multiples of 1/120 and canonicalises 4/3 to 1.3333334, so use that
# spelling and `hyprctl monitors` reads back byte-identical.
#
# NUM/DEN carry the same value as an exact fraction. They are what the
# divisibility maths uses: a repeating fraction has no finite decimal form, so
# rounding the literal and testing that would wrongly reject every resolution.
DEFAULT_SCALE=1.3333334
DEFAULT_SCALE_NUM=4
DEFAULT_SCALE_DEN=3

# Colour scheme applied on a first install. A re-run keeps whatever was last
# picked with SUPER+SHIFT+T instead, so this only ever decides the starting
# point. Must match a filename in config/hypr/themes/ without the extension.
DEFAULT_THEME=catppuccin-mocha

# Wallpaper applied on a first install, on the same terms as DEFAULT_THEME: a
# re-run keeps whatever was last picked with SUPER+W. One of the images the
# hyprland package ships, so nothing has to be generated or downloaded. If it
# is missing — a hyprland release that ships a different set — the generated
# gradient is used instead.
DEFAULT_WALLPAPER=/usr/share/hypr/wall2.png

# Fedora does not package Hyprland. When nothing on the machine provides it
# yet, this COPR is enabled; an existing build or COPR is always kept.
# HYPRLAND_MIN is the first release that reads the Lua config.
HYPRLAND_COPR=nett00n/hyprland
HYPRLAND_MIN=0.55

# Set by --for-user. Normally this script runs as you and calls sudo; an
# installer runs it as root inside a chroot, where there is no "you" and no
# sudo to call. FOR_USER names the account the desktop is being set up for.
FOR_USER=""
SUDO=sudo

# ── options ───────────────────────────────────────────────────────────────────
DO_PACKAGES=auto        # auto | yes | no  — "auto" skips when already provisioned
DO_CONFIGS=1
DO_AUR=0            # opt-in: nothing this script installs comes from the AUR
DO_GAMING=0            # opt-in: Steam and the 32-bit stack are a large,
                       # opinionated addition, and one command to add later
DO_BLUETOOTH=1
DO_GREETD=auto          # auto | yes | no — "auto" defers to a display manager
                        # that is already enabled, which on Fedora Workstation
                        # is GDM, rather than fighting it for the alias
REDETECT_MONITORS=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

By default the script decides for itself what still needs doing:
  · first run          → installs packages, enables services, deploys configs
  · every run after    → detects that is done and only refreshes changed configs

  --configs-only       Never touch packages or services.
  --packages-only      Never touch dotfiles.
  --force-packages     Re-run the package and service steps even if complete.
  --redetect-monitors  Regenerate monitors.lua (otherwise a run leaves your
                       existing one alone, so hand-tuned layouts survive).
  --dry-run            Show what would change; write nothing.

  --aur                Arch only. Also build paru, an AUR helper. Off by
                       default: every package this script installs is in the
                       official repos.
  --gaming             Also install Steam, gamemode and mangohud (on Arch,
                       multilib and the 32-bit drivers too). Off by default.
  --no-bluetooth       Skip bluez/blueman.
  --greetd             Use greetd + tuigreet even if another display manager
                       (GDM on Fedora Workstation) is enabled; that one is
                       disabled. By default an existing one is kept.
  --no-greetd          Skip the login manager.
  --for-user NAME      Run as root and configure the desktop for NAME instead
                       of the invoking user. For installers running this inside
                       a chroot, where sudo has nobody to ask for a password.
  -h, --help           Show this message.

Changed configs are backed up to ~/.config-backup-<timestamp>/ before being
replaced. Identical files are left alone entirely.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configs-only)      DO_PACKAGES=no ;;
        --packages-only)     DO_CONFIGS=0 ;;
        --force-packages)    DO_PACKAGES=yes ;;
        --redetect-monitors) REDETECT_MONITORS=1 ;;
        --dry-run)           DRY_RUN=1 ;;
        --aur)               DO_AUR=1 ;;
        --no-aur)            DO_AUR=0 ;;   # kept: it used to be the default
        --gaming)            DO_GAMING=1 ;;
        --no-gaming)         DO_GAMING=0 ;;   # kept: it used to be the default
        --no-bluetooth)      DO_BLUETOOTH=0 ;;
        --greetd)            DO_GREETD=yes ;;
        --no-greetd)         DO_GREETD=no ;;
        --for-user)          FOR_USER="${2:-}"; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

# ── output helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=; C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=
fi

step() { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '\n%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

trap 'die "failed at line $LINENO: ${BASH_COMMAND}"' ERR

# ── preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"

if [[ -n $FOR_USER ]]; then
    # Already root, so every sudo below is redundant and would fail anyway:
    # inside a chroot there is no tty to prompt on.
    [[ $EUID -eq 0 ]] || die "--for-user has to run as root."
    SUDO=""
    FOR_USER_HOME="$(awk -F: -v u="$FOR_USER" '$1==u{print $6}' /etc/passwd)"
    [[ -n $FOR_USER_HOME ]] || die "no such user: $FOR_USER"
    export HOME="$FOR_USER_HOME"
    CONFIG_DST_OVERRIDE="$FOR_USER_HOME/.config"
    info "configuring the desktop for $FOR_USER ($FOR_USER_HOME)"
else
    [[ $EUID -ne 0 ]] || die "Run this as your normal user, not root, or pass --for-user NAME."
fi
[[ -n ${CONFIG_DST_OVERRIDE:-} ]] && CONFIG_DST="$CONFIG_DST_OVERRIDE"

# Arch or Fedora. Everything distro-specific below — package names, the package
# manager, the initramfs tool, where Hyprland comes from — branches on DISTRO;
# the configuration it deploys is identical on both.
DISTRO=""
DISTRO_NAME=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    DISTRO_NAME="$(. /etc/os-release; echo "${NAME:-}")"
    _os_ids="$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")"
    case " $_os_ids " in
        *" arch "*)   DISTRO=arch ;;
        *" fedora "*) DISTRO=fedora ;;
    esac
fi
[[ -z $DISTRO && -f /etc/arch-release ]] && DISTRO=arch
case "$DISTRO" in
    arch)   command -v pacman >/dev/null || die "pacman not found." ;;
    fedora) command -v dnf    >/dev/null || die "dnf not found." ;;
    *)      die "This script targets Arch Linux or Fedora." ;;
esac
[[ -n $DISTRO_NAME ]] || DISTRO_NAME="Arch Linux"
ARCH="$(uname -m)"

if [[ $DISTRO == fedora && $DO_AUR -eq 1 ]]; then
    warn "--aur is for Arch; ignoring it on Fedora"
    DO_AUR=0
fi
[[ -d "$CONFIG_SRC" ]] || die "config/ directory not found next to install.sh"

# Connectivity is checked where it is needed, not here — see require_network.
# A run with nothing to download does not need a network, and demanding one
# anyway is the difference between an install that works on a train and one
# that does not.
#
# A TCP connection rather than a ping: ICMP is filtered on plenty of networks
# that will happily serve packages, and what matters is whether the mirrors can
# be reached. It exercises DNS too, which a ping by IP would not.
require_network() {
    local host=archlinux.org
    [[ $DISTRO == fedora ]] && host=fedoraproject.org
    timeout 5 bash -c "exec 3<>/dev/tcp/$host/443" 2>/dev/null && return 0
    die "No network connectivity, and $1 needs it. Connect first (nmtui / iwctl)."
}
# $USER is not set inside arch-chroot, and `set -u` turns that into an abort
# rather than an empty string. id -un always works.
ok "$DISTRO_NAME ($ARCH), running as ${FOR_USER:-$(id -un)}"
[[ $DRY_RUN -eq 1 ]] && warn "dry run — nothing will be written"

# ── GPU detection ─────────────────────────────────────────────────────────────
# Read the PCI vendor ID straight out of sysfs rather than shelling out to
# lspci, so detection works on a minimal install with no pciutils.
#   0x1002 AMD/ATI   0x8086 Intel   0x10de NVIDIA
#   0x1af4 virtio    0x15ad VMware  0x1234 QEMU/bochs
#
# ARM machines mostly have no PCI GPU. The GPU there is a platform device with
# no vendor file, so it is identified by the kernel driver bound to it instead.
# On Apple silicon that is two cards: `asahi` renders and `apple-drm` only
# drives the displays. A display-only card is not a GPU and is skipped, or a
# Mac would be written up as an unknown device and put on software rendering.
GPU_VENDORS=()
GPU_NAMES=()

# ── Broadcom wireless ─────────────────────────────────────────────────────────
# Some Broadcom cards need a driver the kernel does not carry, and the two
# candidates cannot both drive the same card — loading the wrong one is the
# classic way to end up with a laptop that has no wifi at all.
#
# The install medium ships both, because it cannot know where it will be
# installed. This decides which one belongs on *this* machine, from the PCI ID.
#
# The driver is broadcom-wl-dkms — a proprietary module, and the only thing
# that drives a BCM4360, the card in a 2013 retina MacBook Pro, which brcmfmac
# does not support at all. It also handles the BCM4331 in the non-retina
# models, so one driver covers both and there is no second one to choose
# between. (The in-kernel b43 is the open alternative for the 4331 and is worth
# preferring on that card, but it needs firmware from the AUR that cannot be
# redistributed; anyone who wants it can install b43-firmware and invert the
# blacklist below.)
#
# Anything not listed is left alone: the in-kernel brcmfmac handles most
# modern Broadcom parts without help, and interfering would break them.
BCM_DRIVER=""
BCM_NAME=""

detect_broadcom_wifi() {
    local dev vendor id
    for dev in /sys/bus/pci/devices/*; do
        [[ -r $dev/vendor && -r $dev/device ]] || continue
        vendor="$(cat "$dev/vendor")"
        [[ $vendor == 0x14e4 ]] || continue          # Broadcom
        id="$(cat "$dev/device")"

        case "$id" in
            # 43a0 BCM4360   — 2013 retina MacBook Pro
            # 4331 BCM4331   — 2011-2012 MacBook Pro, and the non-retina 2013
            # 43b1 BCM4352   43ba BCM43602   43a3 BCM4350
            # 432b BCM4322   4353 BCM43224   4315 BCM4312
            0x43a0|0x4331|0x43b1|0x43ba|0x43a3|0x432b|0x4353|0x4315)
                BCM_DRIVER=wl ;;
            *)
                continue ;;
        esac

        if command -v lspci >/dev/null; then
            BCM_NAME="$(lspci -d "14e4:${id#0x}" 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ *//' || true)"
        fi
        [[ -n $BCM_NAME ]] || BCM_NAME="Broadcom device ${id#0x}"
        return 0
    done
    return 0
}

detect_gpus() {
    local dev card vendor id driver name v
    for dev in /sys/class/drm/card*/device; do
        card="$(basename "$(dirname "$dev")")"
        # Skip connector entries like card1-DP-3; we only want the device.
        [[ $card == *-* ]] && continue

        if [[ -r $dev/vendor ]]; then
            vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
            id="$(cat "$dev/device" 2>/dev/null || true)"

            case "$vendor" in
                0x1002) v=amd    ;;
                0x8086) v=intel  ;;
                0x10de) v=nvidia ;;
                0x1af4|0x15ad|0x1234) v=virtual ;;
                *)      v=unknown ;;
            esac

            if command -v lspci >/dev/null; then
                name="$(lspci -d "${vendor#0x}:${id#0x}" 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ *//' || true)"
            else
                name="$v device $id"
            fi
        else
            driver="$(basename "$(readlink -f "$dev/driver" 2>/dev/null)")"
            case "$driver" in
                asahi)                                   v=apple ;;
                panfrost|panthor|lima|v3d|msm|etnaviv)   v=soc ;;
                virtio_gpu|virtio-gpu)                   v=virtual ;;
                *) continue ;;   # display-only (apple-drm, simpledrm, ...)
            esac
            # The devicetree says what it is: apple,agx-t8112 on an M2.
            name="$(tr '\0' '\n' < "$dev/of_node/compatible" 2>/dev/null | head -1 || true)"
            name="${name:-$driver} ($driver driver)"
        fi

        # Do not list the same vendor twice on a multi-card system.
        gpu_has "$v" && continue

        GPU_VENDORS+=("$v")
        GPU_NAMES+=("$name")
    done

    if [[ ${#GPU_VENDORS[@]} -eq 0 ]]; then
        GPU_VENDORS=(unknown)
    fi
    return 0
}

gpu_has() {
    local want="$1" v
    for v in ${GPU_VENDORS[@]+"${GPU_VENDORS[@]}"}; do
        [[ $v == "$want" ]] && return 0
    done
    return 1
}

# Headers for every installed kernel — DKMS modules need them to build.
kernel_headers() {
    local k
    for k in $(pacman -Qq 2>/dev/null | grep -xE 'linux|linux-lts|linux-zen|linux-hardened' || true); do
        echo "${k}-headers"
    done
}

detect_gpus
detect_broadcom_wifi

# On Fedora the wl driver is RPM Fusion's akmod-wl, not something this script
# installs. Blacklisting the in-kernel drivers without it would leave no wifi
# at all, so on Fedora the card is only reported.
BCM_UNHANDLED=""
if [[ $DISTRO == fedora && -n $BCM_DRIVER ]]; then
    BCM_UNHANDLED="$BCM_NAME"
    BCM_DRIVER=""
fi

# ── login manager ─────────────────────────────────────────────────────────────
# display-manager.service is an alias that only one unit can hold, and Fedora
# Workstation ships with GDM holding it. GDM lists Hyprland's session files by
# itself, so by default an existing display manager is left in charge and
# greetd is not installed at all. --greetd replaces it.
OTHER_DM="$(readlink /etc/systemd/system/display-manager.service 2>/dev/null || true)"
OTHER_DM="${OTHER_DM##*/}"
[[ $OTHER_DM == greetd.service ]] && OTHER_DM=""
case "$DO_GREETD" in
    auto) if [[ -n $OTHER_DM ]]; then DO_GREETD=0; else DO_GREETD=1; fi ;;
    yes)  DO_GREETD=1 ;;
    no)   DO_GREETD=0 ;;
esac

# ── package sets ──────────────────────────────────────────────────────────────
# Grouped by purpose so it is obvious what to drop for a leaner system.
#
# The Arch lists come first and stay at column 0: starch's extract-packages.sh
# builds the ISO's package list by pulling `^PKGS_...=(` through `^)` out of
# this file with sed, so indenting them, or wrapping them in an `if`, silently
# empties the ISO. Fedora's lists replace them further down, indented so the
# extraction never sees them.

PKGS_BASE=(
    base-devel git curl wget man-db man-pages
    xdg-user-dirs xdg-utils
    unzip zip 7zip
    # rate-mirrors, not reflector: reflector left the official repos and is
    # AUR-only now, and this list has to install before any AUR helper exists.
    rate-mirrors pacman-contrib
    nano
)
# Vendor-neutral graphics base, present regardless of who made the card.
PKGS_GPU=(
    mesa vulkan-icd-loader vulkan-mesa-layers vulkan-tools
    libva libva-utils mesa-utils
    xorg-xwayland
)
# 32-bit counterparts, only used when --no-gaming is not passed.
PKGS_GPU32=( lib32-mesa lib32-vulkan-icd-loader )

NVIDIA_NOTES=0
for _v in "${GPU_VENDORS[@]}"; do
    case "$_v" in
        amd)
            PKGS_GPU+=( vulkan-radeon )
            PKGS_GPU32+=( lib32-vulkan-radeon )
            ;;
        intel)
            # intel-media-driver is the iHD VA-API driver, correct for Broadwell
            # (2014) and newer. Older chips need libva-intel-driver instead.
            PKGS_GPU+=( vulkan-intel intel-media-driver )
            PKGS_GPU32+=( lib32-vulkan-intel )
            ;;
        nvidia)
            # Arch's main NVIDIA packages now use the open kernel modules;
            # nvidia-open-dkms provides nvidia-dkms. DKMS builds for every
            # installed kernel, which is why the headers go in too.
            PKGS_GPU+=( nvidia-open-dkms nvidia-utils nvidia-settings egl-wayland libva-nvidia-driver )
            while read -r _h; do [[ -n $_h ]] && PKGS_GPU+=( "$_h" ); done < <(kernel_headers)
            PKGS_GPU32+=( lib32-nvidia-utils )
            NVIDIA_NOTES=1
            ;;
        virtual)
            PKGS_GPU+=( vulkan-virtio vulkan-swrast )
            ;;
        unknown)
            # Software rendering so the session at least comes up.
            PKGS_GPU+=( vulkan-swrast )
            ;;
    esac
done
PKGS_AUDIO=(
    pipewire pipewire-alsa pipewire-pulse pipewire-jack
    wireplumber pavucontrol playerctl
    alsa-utils alsa-firmware sof-firmware
)
PKGS_HYPRLAND=(
    hyprland uwsm
    hyprpaper hyprlock hypridle hyprpicker hyprsunset
    hyprpolkitagent
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
    qt5-wayland qt6-wayland
)
PKGS_DESKTOP=(
    waybar wofi mako libnotify
    kitty
    thunar thunar-volman thunar-archive-plugin tumbler file-roller
    gvfs gvfs-mtp udiskie
    network-manager-applet
    gnome-keyring
    swayosd brightnessctl
    grim slurp swappy wl-clipboard cliphist
    nwg-look nwg-displays
    imv mpv
    imagemagick jq
    # starch-config is GTK4 through PyGObject. gtk4 itself comes with
    # PKGS_THEME; this is the Python binding, and the only thing the settings
    # app adds to the image.
    python-gobject
)
PKGS_FONTS=(
    ttf-jetbrains-mono ttf-jetbrains-mono-nerd
    ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono
    otf-font-awesome
    noto-fonts noto-fonts-emoji noto-fonts-cjk
)
PKGS_THEME=( papirus-icon-theme adwaita-icon-theme gtk3 gtk4 )

# End-user applications. Firefox already gets MOZ_ENABLE_WAYLAND=1 from env.conf
# and a Picture-in-Picture window rule from rules.conf.
PKGS_APPS=( firefox neovim vim )
PKGS_SHELL=( fastfetch btop ripgrep fd bat eza fzf zoxide starship )
PKGS_GREETD=( greetd greetd-tuigreet )
PKGS_BLUETOOTH=( bluez bluez-utils blueman )
# The 32-bit graphics drivers come from PKGS_GPU32, which is vendor-aware.
PKGS_GAMING=( steam gamemode lib32-gamemode mangohud "${PKGS_GPU32[@]}" )

# Fedora names things differently and does not carry quite the same things, so
# on Fedora every list above is replaced, group for group.
#
# ${DISTRO:-}, not $DISTRO: the one-line arrays above make extract-packages.sh's
# sed range run on to the next column-0 `)`, which is WANTED's, so this block is
# evaluated there too — with set -u and no DISTRO.
if [[ ${DISTRO:-} == fedora ]]; then
    NVIDIA_NOTES=0
    PKGS_BASE=(
        git curl wget2-wget man-db man-pages
        xdg-user-dirs xdg-utils
        unzip zip 7zip
        nano
    )
    # Fedora's mesa-vulkan-drivers carries every Mesa Vulkan driver at once —
    # RADV, ANV, Honeykrisp for Apple silicon, PanVK, lavapipe — so unlike
    # Arch the vendor adds little. On Asahi the Asahi COPR supplies Mesa when
    # it is newer, and dnf picks that by itself.
    PKGS_GPU=(
        mesa-dri-drivers mesa-vulkan-drivers vulkan-loader vulkan-tools
        libva libva-utils glx-utils
        xorg-x11-server-Xwayland
    )
    PKGS_GPU32=()
    for _v in "${GPU_VENDORS[@]}"; do
        case "$_v" in
            amd)    PKGS_GPU+=( mesa-va-drivers ) ;;
            # The iHD driver is in RPM Fusion, not Fedora. Skipped with a
            # warning if that repository is not enabled.
            intel)  PKGS_GPU+=( intel-media-driver ) ;;
            # The driver is RPM Fusion's akmod-nvidia, which wants Secure Boot
            # handling this script should not guess at. See the notes at the end.
            nvidia) NVIDIA_NOTES=1 ;;
        esac
    done
    PKGS_AUDIO=(
        pipewire pipewire-alsa pipewire-pulseaudio pipewire-jack-audio-connection-kit
        wireplumber pavucontrol playerctl
        alsa-utils
    )
    # PC sound firmware. Apple silicon has its own stack (asahi-audio), which
    # the Remix installs.
    [[ $ARCH == x86_64 ]] && PKGS_AUDIO+=( alsa-firmware alsa-sof-firmware )
    # Fedora does not package Hyprland itself. These come from the nett00n
    # COPR, which the system phase enables if nothing already provides them.
    PKGS_HYPRLAND=(
        hyprland uwsm
        hyprpaper hyprlock hypridle hyprpicker hyprsunset
        hyprpolkitagent
        xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
        qt5-qtwayland qt6-qtwayland
    )
    # nwg-look and nwg-displays are not packaged for Fedora. starch-config
    # covers the display side; GTK theming is in settings.ini and dconf.
    PKGS_DESKTOP=(
        waybar wofi mako libnotify
        kitty
        Thunar thunar-volman thunar-archive-plugin tumbler file-roller
        gvfs gvfs-mtp udiskie
        network-manager-applet
        gnome-keyring
        swayosd brightnessctl
        grim slurp swappy wl-clipboard cliphist
        imv mpv
        ImageMagick jq
        python3-gobject
        dconf
    )
    # JetBrainsMono Nerd Font and the Nerd Font symbols are not packaged; the
    # system phase fetches them from the Nerd Fonts release instead.
    PKGS_FONTS=(
        jetbrains-mono-fonts-all
        fontawesome-fonts-all
        google-noto-sans-fonts google-noto-serif-fonts google-noto-sans-mono-fonts
        google-noto-color-emoji-fonts google-noto-sans-cjk-fonts
    )
    PKGS_THEME=( papirus-icon-theme adwaita-icon-theme gtk3 gtk4 )
    PKGS_APPS=( firefox neovim vim-enhanced )
    # starship is not packaged for Fedora, and nothing here depends on it.
    PKGS_SHELL=( fastfetch btop ripgrep fd-find bat eza fzf zoxide )
    # greetd-selinux: without its policy, SELinux stops greetd starting a session.
    PKGS_GREETD=( greetd greetd-selinux tuigreet )
    # bluetoothctl is part of bluez on Fedora.
    PKGS_BLUETOOTH=( bluez blueman )
    # On Fedora Asahi Remix, steam is the Asahi COPR's FEX-emulated build; on
    # x86_64 it comes from RPM Fusion. Skipped with a warning where neither is.
    PKGS_GAMING=( steam gamemode mangohud )
fi

# Everything this run is responsible for, honouring the feature flags.
WANTED=(
    "${PKGS_BASE[@]}" "${PKGS_GPU[@]}" "${PKGS_AUDIO[@]}" "${PKGS_HYPRLAND[@]}"
    "${PKGS_DESKTOP[@]}" "${PKGS_FONTS[@]}" "${PKGS_THEME[@]}" "${PKGS_SHELL[@]}"
    "${PKGS_APPS[@]}"
)
[[ $DO_GREETD    -eq 1 ]] && WANTED+=( "${PKGS_GREETD[@]}" )
[[ $DO_BLUETOOTH -eq 1 ]] && WANTED+=( "${PKGS_BLUETOOTH[@]}" )
[[ $DO_GAMING    -eq 1 ]] && WANTED+=( "${PKGS_GAMING[@]}" )
# The wireless driver this card needs, if it needs one the kernel lacks. On
# install media both are already present; this is what makes a plain run of
# this script on an existing Arch install fix the wifi too. On Fedora the
# driver is RPM Fusion's akmod-wl, which is left to the user.
[[ $DISTRO == arch && $BCM_DRIVER == wl ]] && WANTED+=( broadcom-wl-dkms )

# ── package helpers ───────────────────────────────────────────────────────────
# True when a package is installed. Also handles package groups (base-devel),
# which `pacman -Qq` never matches on their own name. On Fedora, anything that
# provides the name counts too.
pkg_installed() {
    if [[ $DISTRO == fedora ]]; then
        rpm -q --quiet "$1" 2>/dev/null || rpm -q --quiet --whatprovides "$1" 2>/dev/null
        return
    fi

    pacman -Qq "$1" &>/dev/null && return 0

    pacman -Sg "$1" &>/dev/null || return 1
    local _grp member
    while read -r _grp member; do
        pacman -Qq "$member" &>/dev/null || return 1
    done < <(pacman -Sg "$1")
    return 0
}

unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# Fedora packages none of the Nerd Fonts every config here names, so they are
# fetched from the upstream release instead: JetBrainsMono Nerd Font for text,
# Symbols Nerd Font for the icons waybar and wofi draw.
NERD_FONTS=( JetBrainsMono NerdFontsSymbolsOnly )
NERD_FONTS_DIR=/usr/local/share/fonts/nerd-fonts
nerd_fonts_present() {
    fc-list 'JetBrainsMono Nerd Font' family 2>/dev/null | grep -q . &&
        fc-list 'Symbols Nerd Font' family 2>/dev/null | grep -q .
}

# Hyprland's config is Lua as of 0.55; .conf is removed in 0.57. The GPU blocks
# below are still written in the old `env = NAME,value` shape because that is
# the readable form for a heredoc, and converted on the way out. Keeps one
# translation in one place rather than five vendor blocks in two dialects.
hyprlang_env_to_lua() {
    sed -e 's/^#/--/' \
        -e 's/^env = \([^,]*\),\(.*\)$/hl.env("\1", "\2")/'
}

# True when dividing `pixels` by the default scale lands on a whole pixel.
# Hyprland does not error on a scale that fails this — it silently snaps to the
# nearest legal value — so this decides whether DEFAULT_SCALE is usable on a
# given display before the value is ever written out.
#
# Uses the exact fraction, never the decimal literal: pixels / (num/den) is
# pixels * den / num, so the test is whether num divides pixels * den. All
# integer arithmetic, no float rounding. 5120 * 3 / 4 = 3840 is exact,
# 1366 * 3 / 4 = 1024.5 is not.
scale_divides() {
    local pixels="$1"
    [[ $pixels =~ ^[0-9]+$ ]] || return 1
    (( DEFAULT_SCALE_NUM > 0 )) || return 1
    (( pixels * DEFAULT_SCALE_DEN % DEFAULT_SCALE_NUM == 0 ))
}

# ── work out what is still outstanding ────────────────────────────────────────
step "Assessing current state"

for _i in "${!GPU_VENDORS[@]}"; do
    info "GPU:       ${GPU_VENDORS[$_i]}${GPU_NAMES[$_i]:+ — ${GPU_NAMES[$_i]}}"
done
[[ -n $BCM_DRIVER ]] && info "wireless:  $BCM_NAME — $BCM_DRIVER"

MISSING_PKGS=()
for p in "${WANTED[@]}"; do
    pkg_installed "$p" || MISSING_PKGS+=("$p")
done

# Not everything exists for every Fedora machine: steam only where the Asahi
# COPR or RPM Fusion carries it, the iHD driver only with RPM Fusion. Something
# no enabled repository offers is reported rather than counted as missing, or
# every re-run would decide the system phase is still needed and try again.
#
# Except while Hyprland itself is unavailable: that means its COPR is not
# enabled yet, and the system phase is what enables it. What is still
# unavailable after that is skipped by dnf and warned about there.
UNAVAILABLE_PKGS=()
if [[ $DISTRO == fedora && ${#MISSING_PKGS[@]} -gt 0 ]]; then
    # Offline the query fails, or answers from stale metadata with nothing at
    # all. Either way everything missing stays missing, the safe way round.
    if _avail="$(dnf repoquery --quiet --available --qf '%{name}\n' "${MISSING_PKGS[@]}" 2>/dev/null)" \
       && [[ -n $_avail ]]; then
        if ! pkg_installed hyprland && ! grep -qx hyprland <<<"$_avail"; then
            :   # the Hyprland COPR is not enabled yet; see above
        else
            _still=()
            for p in "${MISSING_PKGS[@]}"; do
                if grep -qxF "$p" <<<"$_avail"; then
                    _still+=("$p")
                else
                    UNAVAILABLE_PKGS+=("$p")
                fi
            done
            MISSING_PKGS=(${_still[@]+"${_still[@]}"})
        fi
    fi
fi

NERD_FONTS_READY=1
if [[ $DISTRO == fedora ]] && ! nerd_fonts_present; then
    NERD_FONTS_READY=0
fi

PENDING_UNITS=()
unit_enabled NetworkManager.service || PENDING_UNITS+=(NetworkManager.service)
[[ $DO_BLUETOOTH -eq 1 ]] && { unit_enabled bluetooth.service || PENDING_UNITS+=(bluetooth.service); }
[[ $DO_GREETD    -eq 1 ]] && { unit_enabled greetd.service    || PENDING_UNITS+=(greetd.service); }

GREETD_CONFIGURED=0
if [[ $DO_GREETD -eq 0 ]] || grep -qs 'Managed by hyprland-setup' /etc/greetd/config.toml; then
    GREETD_CONFIGURED=1
fi

MULTILIB_READY=1
if [[ $DISTRO == arch && $DO_GAMING -eq 1 ]] && ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
    MULTILIB_READY=0
fi

info "packages:  ${#MISSING_PKGS[@]} of ${#WANTED[@]} missing"
# Name them here, not only in the install step. When the install step is never
# reached — no network, and nothing to reach it with — the count on its own
# says something is wrong without saying what, and finding out afterwards means
# reconstructing the package list by hand from a machine that has already
# rebooted.
[[ ${#MISSING_PKGS[@]} -gt 0 ]] && info "           ${MISSING_PKGS[*]}"
[[ ${#UNAVAILABLE_PKGS[@]} -gt 0 ]] && info "unavailable here, skipped: ${UNAVAILABLE_PKGS[*]}"
[[ $DISTRO == fedora ]] && info "nerd fonts: $( ((NERD_FONTS_READY)) && echo installed || echo missing )"
info "services:  ${#PENDING_UNITS[@]} pending"
if [[ $DO_GREETD -eq 1 ]]; then
    info "greetd:    $( ((GREETD_CONFIGURED)) && echo configured || echo "not configured" )"
    [[ -n $OTHER_DM ]] && info "           replaces $OTHER_DM"
elif [[ -n $OTHER_DM ]]; then
    info "login:     keeping $OTHER_DM (--greetd to replace it)"
fi
[[ $DISTRO == arch && $DO_GAMING -eq 1 ]] && info "multilib:  $( ((MULTILIB_READY))    && echo enabled    || echo disabled )"

SYSTEM_COMPLETE=0
if [[ ${#MISSING_PKGS[@]} -eq 0 && ${#PENDING_UNITS[@]} -eq 0 \
      && $GREETD_CONFIGURED -eq 1 && $MULTILIB_READY -eq 1 \
      && $NERD_FONTS_READY -eq 1 ]]; then
    SYSTEM_COMPLETE=1
fi

# Decide whether the system phase runs at all.
RUN_SYSTEM=0
case "$DO_PACKAGES" in
    yes) RUN_SYSTEM=1; info "forced: re-running the package and service steps" ;;
    no)  RUN_SYSTEM=0; info "--configs-only: skipping packages and services" ;;
    auto)
        if [[ $SYSTEM_COMPLETE -eq 1 ]]; then
            RUN_SYSTEM=0
            ok "system already provisioned — this run only refreshes configs"
        else
            RUN_SYSTEM=1
            info "system phase needed"
        fi
        ;;
esac

# Only ask for sudo if something actually needs root.
if [[ $RUN_SYSTEM -eq 1 && $DRY_RUN -eq 0 && -z $FOR_USER ]]; then
    info "requesting sudo (needed for the package manager and systemd units)…"
    sudo -v || die "sudo is required."
    while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

run() {  # execute, or just narrate under --dry-run
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $*"
    else
        "$@"
    fi
}

# ── system phase ──────────────────────────────────────────────────────────────
if [[ $RUN_SYSTEM -eq 1 ]]; then
    if [[ $DISTRO == arch ]]; then
        step "Tuning /etc/pacman.conf"

        tweak_pacman() {
            local key="$1" line="$2"
            if grep -qE "^\s*${key}" /etc/pacman.conf; then
                ok "$key already set"
            elif grep -qE "^#\s*${key}" /etc/pacman.conf; then
                run $SUDO sed -i "s/^#\s*${key}.*/${line}/" /etc/pacman.conf
                ok "enabled $key"
            else
                run $SUDO sed -i "/^\[options\]/a ${line}" /etc/pacman.conf
                ok "enabled $key"
            fi
        }

        tweak_pacman "Color"             "Color"
        tweak_pacman "ParallelDownloads" "ParallelDownloads = 10"
        tweak_pacman "VerbosePkgLists"   "VerbosePkgLists"

        if [[ $DO_GAMING -eq 1 ]]; then
            if [[ $MULTILIB_READY -eq 1 ]]; then
                ok "multilib already enabled"
            else
                info "enabling [multilib] for 32-bit gaming libraries"
                run $SUDO sed -i '/^#\[multilib\]/,/^#Include = .*mirrorlist/ s/^#//' /etc/pacman.conf
                ok "multilib enabled"
            fi
        fi

        # Only sync when something actually has to come down the wire. Installing
        # from the ISO leaves every package already present, and the system phase
        # still runs — the services need enabling, and that needs no network.
        # Syncing anyway would make an otherwise entirely offline install fail on a
        # machine that has not been connected yet.
        if [[ ${#MISSING_PKGS[@]} -eq 0 && $DO_AUR -eq 0 && $DO_GAMING -eq 0 ]]; then
            step "Packages"
            ok "all ${#WANTED[@]} already installed; nothing to download"
        else
            step "Synchronising databases and updating the system"
            require_network "installing packages"
            run $SUDO pacman -Syu --noconfirm
            ok "system up to date"
        fi

        # ── drivers this machine has no use for ───────────────────────────────────
        # The install medium carries every vendor's driver, because it cannot know
        # what it will be installed onto. Once that is known, the rest can go: an
        # AMD laptop has no reason to keep 900MB of NVIDIA userspace, and a machine
        # with no Broadcom card has no reason to keep two Broadcom drivers.
        #
        # Only ever removes what this script itself would have installed, and only
        # what the detected hardware rules out. -Rn without the cascade: these are
        # explicitly installed packages, and following their dependencies out would
        # take shared libraries other things need.
        step "Drivers not needed here"
        unneeded=()

        has_vendor() {
            local want="$1" v
            for v in ${GPU_VENDORS[@]+"${GPU_VENDORS[@]}"}; do
                [[ $v == "$want" ]] && return 0
            done
            return 1
        }

        has_vendor nvidia || unneeded+=( nvidia-open-dkms nvidia-utils nvidia-settings
                                         libva-nvidia-driver lib32-nvidia-utils )
        has_vendor amd    || unneeded+=( vulkan-radeon lib32-vulkan-radeon )
        has_vendor intel  || unneeded+=( vulkan-intel intel-media-driver lib32-vulkan-intel )

        [[ $BCM_DRIVER == wl ]] || unneeded+=( broadcom-wl-dkms )

        # dkms and the kernel headers exist on the medium to build the two modules
        # above. With neither in use they are 310MB of build tooling for nothing —
        # and a plain Arch install would not have them unless something asked.
        if ! has_vendor nvidia && [[ $BCM_DRIVER != wl ]]; then
            unneeded+=( dkms linux-headers )
        fi

        present=()
        for _p in "${unneeded[@]}"; do
            pacman -Qq "$_p" &>/dev/null && present+=("$_p")
        done

        if [[ ${#present[@]} -eq 0 ]]; then
            ok "nothing to remove"
        elif [[ $DRY_RUN -eq 1 ]]; then
            info "[dry-run] would remove ${#present[@]}: ${present[*]}"
        else
            info "removing ${#present[@]} not needed on this hardware"
            info "    ${present[*]}"
            run $SUDO pacman -Rn --noconfirm "${present[@]}" || warn "some could not be removed"
            ok "removed"
        fi

        step "Installing packages"
        if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
            ok "all ${#WANTED[@]} packages already installed"
        else
            info "${#MISSING_PKGS[@]} to install: ${MISSING_PKGS[*]}"
            run $SUDO pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
            ok "packages installed"
        fi

        if [[ $DO_AUR -eq 1 ]]; then
            step "AUR helper (paru)"
            require_network "building paru"

            # Ask paru to run rather than merely checking it is on $PATH. paru links
            # libalpm, whose soname pacman bumps on major releases; a paru built
            # against the old one stays installed and executable-looking but dies at
            # startup with "libalpm.so.15: cannot open shared object file". Testing
            # for the file alone reports success and repairs nothing.
            paru_works() { command -v paru >/dev/null && paru --version >/dev/null 2>&1; }

            if paru_works; then
                ok "paru already installed"
            elif [[ $DRY_RUN -eq 1 ]]; then
                info "[dry-run] would build paru from the AUR"
            else
                if command -v paru >/dev/null; then
                    warn "paru is installed but will not run — rebuilding it"
                    info "$(ldd "$(command -v paru)" 2>/dev/null | grep 'not found' || echo 'broken install')"
                fi

                # Source package, not paru-bin. The -bin binary is compiled upstream
                # against whatever libalpm existed at release time and goes stale on
                # the next pacman bump; building here links against this machine's.
                info "building paru from source (a few minutes)"
                build_dir="$(mktemp -d)"
                git clone --depth 1 https://aur.archlinux.org/paru.git "$build_dir/paru"
                # -s fetch makedeps, -r drop them again after, -c clean the workdir.
                ( cd "$build_dir/paru" && makepkg -src --noconfirm )
                # pacman -U rather than makepkg -i, so replacing an older paru-bin
                # is an ordinary conflict resolution instead of an error.
                run $SUDO pacman -U --noconfirm "$build_dir"/paru/paru-*.pkg.tar.*
                rm -rf "$build_dir"
                paru_works && ok "paru installed" || warn "paru built but still will not run"
            fi
        fi

    else
        # No whole-system upgrade first, unlike pacman -Syu on Arch: Fedora
        # supports partial upgrades, and dnf updates whatever a new package
        # actually needs.
        step "Hyprland repository"
        # Fedora does not package Hyprland. Whatever already provides it is
        # kept, whether that is a build already installed or a COPR someone
        # enabled by hand. The default COPR is enabled only when nothing does.
        if pkg_installed hyprland; then
            ok "hyprland $(rpm -q --qf '%{version}' hyprland) already installed — keeping it"
        elif dnf repoquery --quiet --available hyprland 2>/dev/null | grep -q .; then
            ok "hyprland is available from an enabled repository"
        else
            require_network "enabling the Hyprland COPR"
            if ! dnf copr --help >/dev/null 2>&1; then
                run $SUDO dnf install -y 'dnf-command(copr)'
            fi
            run $SUDO dnf copr enable -y "$HYPRLAND_COPR"
            ok "enabled the $HYPRLAND_COPR COPR"
        fi

        step "Installing packages"
        if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
            ok "all wanted packages already installed"
        else
            require_network "installing packages"
            info "${#MISSING_PKGS[@]} to install: ${MISSING_PKGS[*]}"
            # --skip-unavailable, so that something no enabled repository has
            # for this machine — steam away from Asahi, the iHD driver without
            # RPM Fusion — is reported instead of failing the whole transaction.
            run $SUDO dnf install -y --skip-unavailable "${MISSING_PKGS[@]}"
            if [[ $DRY_RUN -eq 0 ]]; then
                skipped=()
                for _p in "${MISSING_PKGS[@]}"; do
                    pkg_installed "$_p" || skipped+=("$_p")
                done
                if [[ ${#skipped[@]} -eq 0 ]]; then
                    ok "packages installed"
                else
                    warn "not available here, skipped: ${skipped[*]}"
                fi
            fi
        fi

        # The configuration is Lua, which Hyprland reads from 0.55 on. An older
        # build would start with none of it applied.
        if pkg_installed hyprland; then
            hypr_ver="$(rpm -q --qf '%{version}' hyprland)"
            if [[ "$(printf '%s\n' "$HYPRLAND_MIN" "$hypr_ver" | sort -V | head -1)" != "$HYPRLAND_MIN" ]]; then
                warn "hyprland $hypr_ver is older than $HYPRLAND_MIN, which this Lua config needs"
            fi
        fi

        step "Nerd Fonts"
        if [[ $NERD_FONTS_READY -eq 1 ]]; then
            ok "JetBrainsMono and Symbols Nerd Fonts already installed"
        elif [[ $DRY_RUN -eq 1 ]]; then
            info "[dry-run] would install ${NERD_FONTS[*]} into $NERD_FONTS_DIR"
        else
            require_network "fetching the Nerd Fonts"
            nf_tmp="$(mktemp -d)"
            for _f in "${NERD_FONTS[@]}"; do
                curl -fsSL --retry 3 -o "$nf_tmp/$_f.tar.xz" \
                    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$_f.tar.xz"
                mkdir -p "$nf_tmp/$_f"
                tar -xJf "$nf_tmp/$_f.tar.xz" -C "$nf_tmp/$_f"
                # Only the family the configs name. The archive also carries
                # the Mono and Propo variants, which triple its size.
                case "$_f" in
                    JetBrainsMono) _glob='JetBrainsMonoNerdFont-*.ttf' ;;
                    *)             _glob='*.ttf' ;;
                esac
                run $SUDO install -d "$NERD_FONTS_DIR/$_f"
                find "$nf_tmp/$_f" -maxdepth 1 -name "$_glob" -print0 \
                    | xargs -0 -r $SUDO install -m644 -t "$NERD_FONTS_DIR/$_f/"
            done
            rm -rf "$nf_tmp"
            run $SUDO fc-cache -f "$NERD_FONTS_DIR" >/dev/null
            if nerd_fonts_present; then
                ok "installed into $NERD_FONTS_DIR"
            else
                warn "downloaded, but fontconfig does not see them yet"
            fi
        fi
    fi

    step "Enabling services"
    if [[ ${#PENDING_UNITS[@]} -eq 0 ]]; then
        ok "all system units already enabled"
    else
        for unit in "${PENDING_UNITS[@]}"; do
            # greetd is configured below; enable it only once that has happened.
            [[ $unit == greetd.service ]] && continue
            run $SUDO systemctl enable "$unit"
            ok "enabled $unit"
        done
    fi

    # `systemctl --user` talks to a session bus, which does not exist inside a
    # chroot — and under --for-user it would enable the units for root anyway,
    # not for the account being set up. --global writes the same symlinks into
    # /etc/systemd/user, which applies to every user and needs no session.
    if [[ -n $FOR_USER ]]; then
        if run $SUDO systemctl --global enable pipewire.service pipewire-pulse.service wireplumber.service >/dev/null 2>&1; then
            ok "PipeWire user services enabled for all users"
        else
            warn "PipeWire user services will start on first graphical login"
        fi
    elif systemctl --user enable pipewire.service pipewire-pulse.service wireplumber.service >/dev/null 2>&1; then
        ok "PipeWire user services enabled"
    else
        warn "PipeWire user services will start on first graphical login"
    fi

    run xdg-user-dirs-update
    ok "XDG user directories present"

    if [[ $DO_GREETD -eq 1 ]]; then
        step "Configuring greetd + tuigreet"
        # Prefer the uwsm session: a proper systemd user session, which makes
        # portals and user units behave. Fall back to launching Hyprland directly.
        if [[ -f /usr/share/wayland-sessions/hyprland-uwsm.desktop ]]; then
            session_cmd='uwsm start hyprland-uwsm.desktop'
            info "using the uwsm-managed Hyprland session"
        else
            session_cmd='Hyprland'
            info "uwsm session file not found; launching Hyprland directly"
        fi

        # Arch's package creates a `greeter` account, Fedora's a `greetd` one.
        greeter_user=greeter
        [[ $DISTRO == fedora ]] && greeter_user=greetd

        if [[ $DRY_RUN -eq 1 ]]; then
            info "[dry-run] would write /etc/greetd/config.toml"
        else
            $SUDO install -d -m 755 /etc/greetd
            $SUDO tee /etc/greetd/config.toml >/dev/null <<EOF
# Managed by hyprland-setup/install.sh
[terminal]
vt = 1

[default_session]
command = "tuigreet --remember --remember-user-session --asterisks --time --greeting '${DISTRO_NAME}' --cmd '${session_cmd}'"
user = "${greeter_user}"
EOF
            $SUDO install -d -o "$greeter_user" -g "$greeter_user" -m 755 /var/cache/tuigreet 2>/dev/null || true
            ok "wrote /etc/greetd/config.toml"
        fi

        # Only reached with another display manager enabled under --greetd.
        # It holds the display-manager.service alias greetd needs.
        if [[ -n $OTHER_DM ]]; then
            run $SUDO systemctl disable "$OTHER_DM"
            ok "disabled $OTHER_DM"
        fi

        unit_enabled greetd.service && ok "greetd.service already enabled" || {
            run $SUDO systemctl enable greetd.service
            ok "enabled greetd.service"
        }
    fi
else
    [[ $DO_PACKAGES != no ]] && info "nothing to install — skipping to configuration"
fi

# ── configuration ─────────────────────────────────────────────────────────────
if [[ $DO_CONFIGS -eq 1 ]]; then
    step "Syncing configuration files"

    N_ADDED=0; N_CHANGED=0; N_SAME=0
    CHANGED_FILES=()

    # File-by-file rather than directory-at-a-time. Identical files are left
    # untouched, changed ones are backed up first, and files that exist only in
    # ~/.config (monitors.lua, anything you added) are never removed.
    while IFS= read -r -d '' src; do
        rel="${src#"$CONFIG_SRC"/}"
        dst="$CONFIG_DST/$rel"

        if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
            N_SAME=$((N_SAME + 1))
            continue
        fi

        if [[ -e $dst ]]; then
            N_CHANGED=$((N_CHANGED + 1))
            CHANGED_FILES+=("$rel")
            if [[ $DRY_RUN -eq 0 ]]; then
                mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
                cp -p "$dst" "$BACKUP_DIR/$rel"
            fi
        else
            N_ADDED=$((N_ADDED + 1))
            CHANGED_FILES+=("$rel  (new)")
        fi

        if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p "$(dirname "$dst")"
            cp --preserve=mode "$src" "$dst"
            # Set the mode rather than inherit it. A .sh here is run directly
            # by a keybind, so it has to be executable whatever the copy came
            # from — and media that strips modes is the normal case, not an
            # odd one: mkarchiso lays the ISO payload down with
            # --no-preserve=mode, so from install media every one of these
            # arrives as 644 and every keybind that runs one does nothing at
            # all, silently.
            if [[ $src == *.sh ]]; then
                chmod 755 "$dst"
            fi
        fi
    done < <(find "$CONFIG_SRC" -type f -print0)

    if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
        ok "all $N_SAME config files already up to date"
    else
        for f in "${CHANGED_FILES[@]}"; do info "updated  $f"; done
        ok "$N_ADDED added, $N_CHANGED updated, $N_SAME unchanged"
        [[ $N_CHANGED -gt 0 && $DRY_RUN -eq 0 ]] && info "previous versions saved to $BACKUP_DIR"
    fi

    # ── the settings app ──────────────────────────────────────────────────────
    # starch-config is a GTK4 application, not a config file, so it does not go
    # through the sync above. It lands in /usr/local — the FHS home for software
    # the administrator installed rather than the package manager — with a
    # launcher on PATH and a desktop entry so the launcher and any menu can find
    # it.
    #
    # Copied whole rather than symlinked back at this repo: an installed system
    # should keep working after this checkout is deleted, which is exactly what
    # people do with a clone they used once.
    step "Settings app"
    app_src="$SCRIPT_DIR/starch-config"
    app_dst=/usr/local/lib/starch-config
    if [[ ! -d $app_src ]]; then
        warn "starch-config is missing from this checkout — skipping"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would install starch-config to $app_dst"
    else
        run $SUDO rm -rf "$app_dst"
        run $SUDO mkdir -p "$app_dst"
        run $SUDO cp -r "$app_src/starchconfig" "$app_src/starch-config" "$app_dst/"
        run $SUDO chmod 755 "$app_dst/starch-config"
        # Python bytecode from running it out of the checkout has no business
        # being shipped; it is regenerated and it names the old paths.
        $SUDO find "$app_dst" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

        # The launcher is a symlink, and the entry point resolves its own real
        # path before adding it to sys.path, so the package is found through it.
        run $SUDO ln -sfn "$app_dst/starch-config" /usr/local/bin/starch-config
        run $SUDO install -Dm644 "$app_src/starch-config.desktop" \
            /usr/share/applications/starch-config.desktop
        ok "starch-config installed — SUPER+I, or \"Settings\" in the launcher"
    fi

    # ── monitors ──────────────────────────────────────────────────────────────
    # Generated rather than shipped, because it is machine-specific. On a re-run
    # an existing file is left alone so hand-tuned layouts survive; pass
    # --redetect-monitors to regenerate it.
    step "Displays"
    monitors_conf="$CONFIG_DST/hypr/monitors.lua"

    max_w=1920; max_h=1080
    connected=()
    for status_file in /sys/class/drm/card*-*/status; do
        [[ -r $status_file ]] || continue
        [[ "$(cat "$status_file")" == "connected" ]] || continue
        conn="$(basename "$(dirname "$status_file")")"
        connected+=("${conn#card*-}")
    done
    for conn in "${connected[@]:-}"; do
        [[ -n $conn ]] || continue
        res="$(head -1 "/sys/class/drm/card"*"-${conn}/modes" 2>/dev/null || true)"
        w="${res%%x*}"; h="${res##*x}"
        [[ $w =~ ^[0-9]+$ && $w -gt $max_w ]] && max_w=$w
        [[ $h =~ ^[0-9]+$ && $h -gt $max_h ]] && max_h=$h
    done

    if [[ -f $monitors_conf && $REDETECT_MONITORS -eq 0 ]]; then
        ok "keeping your existing monitors.lua (--redetect-monitors to regenerate)"
        for conn in "${connected[@]:-}"; do
            [[ -n $conn ]] && info "connected: $conn"
        done
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would write monitors.lua for ${#connected[@]} display(s)"
    else
        [[ -f $monitors_conf ]] && {
            mkdir -p "$BACKUP_DIR/hypr"
            cp -p "$monitors_conf" "$BACKUP_DIR/hypr/monitors.lua"
            warn "backed up previous monitors.lua"
        }
        {
            echo "-- Generated by hyprland-setup on $(date -Iseconds)."
            echo "-- A re-run leaves this file alone; use --redetect-monitors to rebuild it."
            echo "-- \`hyprctl monitors\` lists modes, \`nwg-displays\` is a GUI for arranging them."
            echo "--"
            echo "-- Syntax: hl.monitor({ output, mode, position, scale })"
            echo "--   highrr = highest refresh rate the display advertises"
            echo "--   highres = highest resolution     preferred = the display's own default"
            echo "--"
            echo "-- Scale must land on a whole pixel: RESOLUTION / SCALE has to be an"
            echo "-- integer in BOTH axes, and the scale itself has to be a multiple of"
            echo "-- 1/120 (the Wayland fractional-scale step). Hyprland does not error on"
            echo "-- a bad value — it silently snaps to the nearest legal one, so always"
            echo "-- confirm with \`hyprctl monitors\` after editing."
            echo "--"
            echo "-- ${DEFAULT_SCALE} (= ${DEFAULT_SCALE_NUM}/${DEFAULT_SCALE_DEN}) was used below wherever it divides cleanly."
            echo "-- Legal scales depend on the resolution; on 5120x2160 the only ones"
            echo "-- between 1x and 2x are 1.0, 1.0666667, 1.25, 1.3333334, 1.6, 1.6666667"
            echo "-- and 2.0 — note that 1.4 and 1.5 are not available there."
            echo
        } > "$monitors_conf"

        if [[ ${#connected[@]} -eq 0 ]]; then
            echo 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })' >> "$monitors_conf"
            warn "no connected display detected; wrote the catch-all rule"
        else
            x_offset=0
            for conn in "${connected[@]}"; do
                res="$(head -1 "/sys/class/drm/card"*"-${conn}/modes" 2>/dev/null || true)"
                info "found $conn ${res:+(${res})}"

                # Parse the mode before deciding the scale.
                width="${res%%x*}"; height="${res##*x}"
                [[ $width  =~ ^[0-9]+$ ]] || width=""
                [[ $height =~ ^[0-9]+$ ]] || height=""

                scale="$DEFAULT_SCALE"
                if [[ -z $width || -z $height ]]; then
                    scale=1
                    warn "  could not read a mode for $conn; using scale 1"
                elif scale_divides "$width" && scale_divides "$height"; then
                    # Exact integer maths, matching scale_divides — dividing by
                    # the rounded literal would truncate 3840 down to 3839.
                    logical="$(( width * DEFAULT_SCALE_DEN / DEFAULT_SCALE_NUM ))x$(( height * DEFAULT_SCALE_DEN / DEFAULT_SCALE_NUM ))"
                    info "  scale $DEFAULT_SCALE -> ${logical} logical"
                else
                    scale=1
                    warn "  scale $DEFAULT_SCALE does not divide ${width}x${height} evenly; using 1"
                fi

                echo "hl.monitor({ output = \"${conn}\", mode = \"highrr\", position = \"${x_offset}x0\", scale = ${scale} })" >> "$monitors_conf"
                x_offset=$(( x_offset + ${width:-1920} ))
            done
            echo >> "$monitors_conf"
            echo "-- Catch-all for any display plugged in later. If a new monitor has a" >> "$monitors_conf"
            echo "-- resolution ${DEFAULT_SCALE} does not divide evenly, Hyprland will silently" >> "$monitors_conf"
            echo "-- snap to the nearest legal scale — set an explicit line for it above." >> "$monitors_conf"
            echo "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = ${DEFAULT_SCALE} })" >> "$monitors_conf"
            ok "wrote monitors.lua for ${#connected[@]} display(s)"
        fi
    fi

    # ── laptop lid ────────────────────────────────────────────────────────────
    # systemd's built-in default already suspends on lid close, but it lives in
    # a commented line in /etc/systemd/logind.conf, so nothing states it and a
    # package update could change it underneath you. Say it explicitly.
    #
    # A drop-in rather than editing logind.conf: that file belongs to systemd,
    # and an edited copy earns a .pacnew on every update that someone then has
    # to reconcile. Nothing here applies to a machine with no lid.
    step "Lid switch"
    lid_conf=/etc/systemd/logind.conf.d/10-starch-lid.conf
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would write $lid_conf"
    else
        lid_tmp="$(mktemp)"
        {
            echo "# Generated by hyprland-setup."
            echo "# Closing the lid suspends, on battery or plugged in. Docked to an"
            echo "# external display it does not, because the display is still usable."
            echo "[Login]"
            echo "HandleLidSwitch=suspend"
            echo "HandleLidSwitchExternalPower=suspend"
            echo "HandleLidSwitchDocked=ignore"
        } > "$lid_tmp"
        if [[ -f $lid_conf ]] && cmp -s "$lid_tmp" "$lid_conf"; then
            ok "lid already configured"
        else
            run $SUDO install -Dm644 "$lid_tmp" "$lid_conf"
            ok "closing the lid suspends"
        fi
        rm -f "$lid_tmp"
    fi

    # ── Broadcom wireless ─────────────────────────────────────────────────────
    # Which driver owns the card is decided here, by keeping the others out of
    # the kernel. Both are installed — the medium ships both because it cannot
    # know the hardware — and if two of them can claim the same device, which
    # one wins is a race that resolves differently between boots.
    step "Wireless"
    if [[ -n $BCM_UNHANDLED ]]; then
        warn "$BCM_UNHANDLED needs the proprietary wl driver, which Fedora does"
        warn "not carry. It is akmod-wl in RPM Fusion's nonfree repository."
    elif [[ -z $BCM_DRIVER ]]; then
        ok "no Broadcom card needing a driver the kernel does not have"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would configure the $BCM_DRIVER driver for: $BCM_NAME"
    else
        bcm_conf=/etc/modprobe.d/starch-broadcom.conf
        bcm_tmp="$(mktemp)"
        {
            echo "# Generated by hyprland-setup for: $BCM_NAME"
            echo "# Rewritten only when the detected wireless hardware changes."
            echo "#"
            echo "# This card is driven by the proprietary wl module. The in-kernel"
            echo "# drivers claim the same device and must stay out of the way; bcma"
            echo "# and ssb are the buses they attach through, so they go too."
            printf 'blacklist %s\n' b43 bcma brcmsmac brcmfmac ssb
        } > "$bcm_tmp"

        if [[ -f $bcm_conf ]] && cmp -s "$bcm_tmp" "$bcm_conf"; then
            ok "$BCM_DRIVER already configured for $BCM_NAME"
        else
            run $SUDO install -Dm644 "$bcm_tmp" "$bcm_conf"
            ok "$BCM_DRIVER selected for $BCM_NAME"
            info "a reboot is needed before wireless works"
        fi
        rm -f "$bcm_tmp"

        # Load it now as well as at boot, so a card that was not working
        # starts working without waiting for the reboot where possible.
        if [[ $BCM_DRIVER == wl ]] && [[ -z $FOR_USER ]]; then
            run $SUDO modprobe wl 2>/dev/null || true
        fi
    fi

    # ── GPU environment ───────────────────────────────────────────────────────
    # Vendor-specific Vulkan/VA-API variables. Generated rather than shipped,
    # because the right values depend entirely on which card is present.
    #
    # Built into a temp file and compared before writing, so a re-run on
    # unchanged hardware touches nothing. Deliberately carries no timestamp:
    # the content is a pure function of the detected GPUs, which is what makes
    # repeat runs a no-op.
    step "GPU environment"
    gpu_conf="$CONFIG_DST/hypr/gpu.lua"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would ensure gpu.lua matches: ${GPU_VENDORS[*]}"
    else
        gpu_tmp="$(mktemp)"
        {
            echo "# Generated by hyprland-setup — do not add a timestamp here; this file is"
            echo "# rewritten only when the detected hardware changes."
            echo "#"
            echo "# Detected: ${GPU_VENDORS[*]}"
            for _i in "${!GPU_VENDORS[@]}"; do
                [[ -n ${GPU_NAMES[$_i]:-} ]] && echo "#   ${GPU_VENDORS[$_i]}: ${GPU_NAMES[$_i]}"
            done
            echo
        } > "$gpu_tmp"
        for _v in "${GPU_VENDORS[@]}"; do
            case "$_v" in
                amd)
                    cat >> "$gpu_tmp" <<'EOF'
# ── AMD ───────────────────────────────────────────────────────────────────────
# RADV is Mesa's Vulkan driver and the right default on Arch (AMDVLK is the
# alternative, rarely faster). radeonsi handles VA-API/VDPAU video decode.
env = AMD_VULKAN_ICD,RADV
env = LIBVA_DRIVER_NAME,radeonsi
env = VDPAU_DRIVER,radeonsi

EOF
                    ;;
                intel)
                    cat >> "$gpu_tmp" <<'EOF'
# ── Intel ─────────────────────────────────────────────────────────────────────
# iHD is the modern VA-API driver (intel-media-driver, Broadwell/2014+).
# On older chips install libva-intel-driver and use i965 here instead.
env = LIBVA_DRIVER_NAME,iHD
env = VDPAU_DRIVER,va_gl

EOF
                    ;;
                nvidia)
                    cat >> "$gpu_tmp" <<'EOF'
# ── NVIDIA ────────────────────────────────────────────────────────────────────
# Only these are currently recommended by the Hyprland wiki. Older guides also
# set GBM_BACKEND and WLR_NO_HARDWARE_CURSORS — both are obsolete and can hurt.
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia

# Needed by libva-nvidia-driver for hardware video decode.
env = NVD_BACKEND,direct

EOF
                    ;;
                virtual)
                    cat >> "$gpu_tmp" <<'EOF'
# ── Virtual GPU ───────────────────────────────────────────────────────────────
# Running in a VM. virtio-gpu with venus, falling back to software rendering.
env = LIBVA_DRIVER_NAME,
env = WLR_RENDERER_ALLOW_SOFTWARE,1

EOF
                    ;;
                apple)
                    cat >> "$gpu_tmp" <<'EOF'
# ── Apple silicon ─────────────────────────────────────────────────────────────
# The Asahi GPU driver: Mesa's asahi for OpenGL, Honeykrisp for Vulkan. Nothing
# needs setting — Mesa finds both on its own. The media engine has no VA-API
# driver yet, so video decodes on the CPU and LIBVA_DRIVER_NAME stays unset.
#
# Rendering (asahi) and the displays (apple-drm) are separate DRM cards, and
# Hyprland pairs them without help.

EOF
                    ;;
                soc)
                    cat >> "$gpu_tmp" <<'EOF'
# ── ARM SoC GPU ───────────────────────────────────────────────────────────────
# Mali (panfrost/panthor), Adreno (msm), VideoCore (v3d) or Vivante (etnaviv).
# Mesa drives these without any variables. Hardware video decode, where there
# is any, goes through V4L2 rather than VA-API, so nothing is set for it.

EOF
                    ;;
                unknown)
                    cat >> "$gpu_tmp" <<'EOF'
# ── Unrecognised GPU ──────────────────────────────────────────────────────────
# The PCI vendor ID did not match AMD, Intel, NVIDIA or a known VM device.
# Software rendering is enabled so the session still starts. Set the correct
# LIBVA_DRIVER_NAME and Vulkan ICD by hand once you know the hardware.
env = WLR_RENDERER_ALLOW_SOFTWARE,1

EOF
                    ;;
            esac
        done

        if [[ ${#GPU_VENDORS[@]} -gt 1 ]]; then
            cat >> "$gpu_tmp" <<'EOF'
# ── Multiple GPUs detected ────────────────────────────────────────────────────
# LIBVA_DRIVER_NAME is set more than once above; the LAST assignment wins.
# Delete the block for the card you do not want handling video decode.
#
# To choose which GPU Hyprland renders on, set AQ_DRM_DEVICES to the card
# paths in priority order, for example:
#   hl.env("AQ_DRM_DEVICES", "/dev/dri/card1:/dev/dri/card0")
# List them with: ls -l /dev/dri/by-path/
EOF
            warn "multiple GPUs detected — review ~/.config/hypr/gpu.lua"
        fi

        # Convert the hyprlang-shaped scratch file into the Lua module.
        gpu_lua="$(mktemp)"
        hyprlang_env_to_lua < "$gpu_tmp" > "$gpu_lua"
        mv "$gpu_lua" "$gpu_tmp"

        if [[ -f $gpu_conf ]] && cmp -s "$gpu_tmp" "$gpu_conf"; then
            rm -f "$gpu_tmp"
            ok "gpu.lua already correct for: ${GPU_VENDORS[*]}"
        else
            if [[ -f $gpu_conf ]]; then
                mkdir -p "$BACKUP_DIR/hypr"
                cp -p "$gpu_conf" "$BACKUP_DIR/hypr/gpu.lua"
                warn "GPU config changed — previous version backed up"
            fi
            mkdir -p "$(dirname "$gpu_conf")"
            mv "$gpu_tmp" "$gpu_conf"
            ok "wrote gpu.lua for: ${GPU_VENDORS[*]}"
        fi
    fi

    # ── retire the legacy hyprlang config ─────────────────────────────────────
    # Hyprland picks hyprland.lua over hyprland.conf, so a leftover .conf is
    # inert — but on a machine upgrading from the old layout it is the previous
    # config, and leaving it invites editing the file that no longer applies.
    if [[ $DRY_RUN -eq 0 && -f "$CONFIG_DST/hypr/hyprland.conf" ]]; then
        mkdir -p "$BACKUP_DIR/hypr"
        for _legacy in hyprland env theme input keybinds rules autostart monitors gpu colors; do
            [[ -f "$CONFIG_DST/hypr/${_legacy}.conf" ]] || continue
            mv "$CONFIG_DST/hypr/${_legacy}.conf" "$BACKUP_DIR/hypr/${_legacy}.conf"
        done
        warn "moved the old .conf config to $BACKUP_DIR/hypr/"
        info "  Hyprland 0.57 removes hyprlang; hyprland.lua replaces it"
    fi

    # ── colour theme ──────────────────────────────────────────────────────────
    # Several configs are rendered rather than copied: waybar and wofi @import a
    # colors.css, hypr sources a colors.conf, kitty and mako include their own.
    # None of those exist until a theme is applied, so this has to run on every
    # install or waybar comes up unstyled.
    step "Colour theme"
    theme_script="$CONFIG_DST/hypr/scripts/theme.sh"
    theme_dir="$CONFIG_DST/hypr/themes"
    theme="$DEFAULT_THEME"

    # Keep the user's pick across a re-run, but only if that theme still exists.
    if [[ -r "$CONFIG_DST/hypr/.active-theme" ]]; then
        prev="$(<"$CONFIG_DST/hypr/.active-theme")"
        [[ -f "$theme_dir/${prev}.theme" ]] && theme="$prev"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would apply the $theme colour theme"
    elif [[ ! -x $theme_script ]]; then
        warn "theme.sh is missing from $theme_script"
    elif "$theme_script" --no-reload --set "$theme"; then
        # --no-reload because nothing is running yet on a fresh install; the
        # validation step below reloads Hyprland, and waybar starts clean.
        ok "applied the $theme colour theme"
        info "SUPER+SHIFT+T switches between $(find "$theme_dir" -name '*.theme' | wc -l) schemes"
    else
        warn "could not apply the $theme theme — try: theme.sh --list"
    fi

    # ── wallpaper ─────────────────────────────────────────────────────────────
    step "Wallpaper"
    wallpaper="$HOME/Pictures/wallpapers/default.png"
    # The directory is what SUPER+W lists, so create it even when there is
    # nothing to put in it yet — an empty picker beats one that errors out.
    [[ $DRY_RUN -eq 1 ]] || mkdir -p "$(dirname "$wallpaper")"
    if [[ -f $wallpaper ]]; then
        ok "wallpaper already present"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would generate a ${max_w}x${max_h} gradient"
    elif command -v magick >/dev/null; then
        magick -size "${max_w}x${max_h}" gradient:'#1e1e2e-#11111b' "$wallpaper"
        ok "generated ${max_w}x${max_h} gradient at $wallpaper"
    else
        warn "imagemagick not available; drop an image at $wallpaper"
    fi
    # hyprpaper.conf and hyprlock.conf both name the current wallpaper, and both
    # were just overwritten by the config sync. Put the recorded pick back.
    #
    # --restore is a no-op when nothing has been picked yet, which is exactly
    # the case on a first install — so the desktop came up with whatever the
    # freshly synced hyprpaper.conf happened to name, and nothing had ever been
    # applied. Fall back to a real image, and record it, so a new machine has a
    # wallpaper the first time it is logged into.
    wall_script="$CONFIG_DST/hypr/scripts/wallpaper.sh"
    active_file="$CONFIG_DST/hypr/.active-wallpaper"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would restore the recorded wallpaper"
    elif [[ ! -x $wall_script ]]; then
        warn "wallpaper.sh is not executable; wallpaper left as configured"
    elif [[ -r $active_file ]] && "$wall_script" --no-reload --restore; then
        ok "restored $(basename "$(<"$active_file")")"
    elif [[ -f $DEFAULT_WALLPAPER ]] && "$wall_script" --no-reload --set "$DEFAULT_WALLPAPER"; then
        ok "set the default wallpaper ($(basename "$DEFAULT_WALLPAPER"))"
    elif [[ -f $wallpaper ]] && "$wall_script" --no-reload --set "$wallpaper"; then
        ok "set $(basename "$wallpaper")"
    else
        warn "no wallpaper could be set"
    fi
    info "SUPER+W picks between these and the wallpapers Hyprland ships in /usr/share/hypr"

    # ── dark by default, for everything ───────────────────────────────────────
    # settings.ini themes GTK applications directly, and that is not the whole
    # story: anything asking xdg-desktop-portal what colour scheme to use —
    # Firefox above all — reads org.gnome.desktop.interface color-scheme out of
    # dconf, which settings.ini has nothing to do with. Installed from the ISO,
    # where the gsettings calls below cannot run, that left Firefox with a
    # light titlebar on an otherwise dark desktop.
    #
    # A system-wide dconf default fixes it without needing a session bus, so it
    # works in a chroot, and being a default rather than a user value it does
    # not fight anyone who later changes it.
    step "Dark theme defaults"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would write the system dconf defaults"
    elif command -v dconf >/dev/null; then
        run $SUDO install -d /etc/dconf/db/local.d /etc/dconf/profile
        # Fedora already has a profile, naming more databases than this one
        # (site, distro). Replacing it would drop those, so only add `local`
        # where it is missing.
        if [[ ! -f /etc/dconf/profile/user ]]; then
            printf '%s\n' \
                "user-db:user" \
                "system-db:local" \
                | run $SUDO tee /etc/dconf/profile/user >/dev/null
        elif ! grep -qx 'system-db:local' /etc/dconf/profile/user; then
            echo "system-db:local" | run $SUDO tee -a /etc/dconf/profile/user >/dev/null
        fi
        printf '%s\n' \
            "# Generated by hyprland-setup." \
            "[org/gnome/desktop/interface]" \
            "gtk-theme='Adwaita-dark'" \
            "icon-theme='Papirus-Dark'" \
            "color-scheme='prefer-dark'" \
            "font-name='Noto Sans 11'" \
            "cursor-theme='Adwaita'" \
            | run $SUDO tee /etc/dconf/db/local.d/00-starch-theme >/dev/null
        if run $SUDO dconf update; then
            ok "dark is the system default (portal-aware apps included)"
        else
            warn "dconf update failed; Firefox may come up light"
        fi
    else
        warn "dconf is not installed; portal-aware apps will not follow the theme"
    fi

    # And the same values as user settings, when there is a session bus to set
    # them on, so a running desktop changes immediately rather than at next
    # login. A chroot has no bus, which is why the defaults above exist.
    if [[ -n $FOR_USER ]]; then
        info "no session bus in a chroot; the dconf defaults cover it"
    elif [[ $DRY_RUN -eq 0 ]] && command -v gsettings >/dev/null; then
        gsettings set org.gnome.desktop.interface gtk-theme    'Adwaita-dark' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface icon-theme   'Papirus-Dark' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'  2>/dev/null || true
        gsettings set org.gnome.desktop.interface font-name    'Noto Sans 11' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'      2>/dev/null || true
        ok "applied dark GTK defaults"
    fi

    # Under --for-user everything above was written as root. Hand it back, or
    # the user logs into a desktop that cannot write its own config.
    if [[ -n $FOR_USER && $DRY_RUN -eq 0 ]]; then
        step "Handing files to $FOR_USER"
        chown -R "$FOR_USER:$FOR_USER" "$FOR_USER_HOME"
        ok "$FOR_USER_HOME"
    fi
fi

# ── NVIDIA follow-up ──────────────────────────────────────────────────────────
if [[ ${NVIDIA_NOTES:-0} -eq 1 && $DISTRO == fedora ]]; then
    step "NVIDIA notes"
    warn "Fedora does not carry the NVIDIA driver, so none was installed."
    info "It is akmod-nvidia in RPM Fusion's nonfree repository:"
    info "    https://rpmfusion.org/Howto/NVIDIA"
    info "With Secure Boot on, the module has to be signed and its key enrolled"
    info "before it will load — that page covers it."
elif [[ ${NVIDIA_NOTES:-0} -eq 1 ]]; then
    step "NVIDIA notes"
    info "Arch already ships 'options nvidia_drm modeset=1', and fbdev follows it"
    info "automatically on driver 570+, so no modprobe changes are needed."
    echo
    warn "nvidia-open-dkms supports Turing and newer (RTX 20xx / GTX 16xx and up)."
    warn "On Maxwell or Pascal (GTX 9xx / 10xx) driver 590 dropped support — you"
    warn "need a legacy branch from the AUR instead:"
    info "    paru -S nvidia-580xx-dkms nvidia-580xx-utils"
    info "    (this is the one case that needs the AUR: re-run with --aur to"
    info "     get paru, or clone the packages and makepkg -si by hand.)"
    echo
    info "Early KMS (adding nvidia modules to mkinitcpio MODULES) is optional. It"
    info "is NOT done automatically because it can break resume-from-hibernation."
    info "See https://wiki.hypr.land/Nvidia/ if you want it."
    info "After rebooting, confirm DRM modesetting with:"
    info "    cat /sys/module/nvidia_drm/parameters/modeset    # expect Y"
fi

# ── validation ────────────────────────────────────────────────────────────────
if [[ $DO_CONFIGS -eq 1 && $DRY_RUN -eq 0 ]]; then
    step "Validating configuration"

    if command -v jq >/dev/null; then
        if sed -e 's@^[[:space:]]*//.*@@' "$CONFIG_DST/waybar/config.jsonc" | jq -e . >/dev/null 2>&1; then
            ok "waybar config parses"
        else
            warn "waybar config.jsonc has a syntax error"
        fi
    fi

    # Ask the running compositor directly. Works from inside the session, and
    # also from a plain terminal by looking the instance up in the runtime dir.
    sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    [[ -z $sig ]] && sig="$(ls -1t "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" 2>/dev/null | head -1 || true)"

    # Verify the Lua config parses without needing a running compositor. This
    # is the only check that catches a broken config before you log in.
    if command -v Hyprland >/dev/null; then
        # Advisory only, so it must not be able to fail the install. The
        # verify needs no running compositor, but it still exits non-zero for
        # reasons that have nothing to do with the config — no seat, no DRM
        # device — which is the ordinary case inside a chroot. Without the
        # guard, set -e and the ERR trap turn this warning into a failed
        # install at the very last step, after everything has been written.
        result="$(Hyprland --verify-config -c "$CONFIG_DST/hypr/hyprland.lua" 2>&1 | tail -1 || true)"
        if [[ $result == *"config ok"* ]]; then
            ok "hyprland.lua parses"
        elif [[ -z ${XDG_RUNTIME_DIR:-} || $result == *XDG_RUNTIME_DIR* ]]; then
            # --verify-config wants a runtime directory before it will read
            # anything, and there is none inside a chroot. That is a fact about
            # where this is running, not about the config — so do not call it
            # an error. Installing from the ISO always lands here, and every
            # install would otherwise end by telling the user their config is
            # broken.
            info "config not verified from here (no session); after logging in:"
            info "    hyprctl configerrors"
        else
            warn "hyprland.lua has errors:"
            printf '%s\n' "$result" | sed 's/^/        /'
        fi
    fi

    if command -v hyprctl >/dev/null && [[ -n $sig ]]; then
        errors="$(HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl reload 2>/dev/null >/dev/null; \
                  HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl configerrors 2>/dev/null || true)"
        if [[ -z $errors ]] || grep -qi 'no errors' <<<"$errors"; then
            ok "Hyprland reloaded with no config errors"
        else
            warn "Hyprland reported config errors:"
            printf '%s\n' "$errors" | sed 's/^/        /'
        fi
    else
        info "Hyprland is not running — after logging in, verify with:"
        info "    hyprctl configerrors"
    fi
fi

# ── done ──────────────────────────────────────────────────────────────────────
step "Done"

if [[ $RUN_SYSTEM -eq 0 && $DO_CONFIGS -eq 1 ]]; then
    cat <<EOF

  ${C_GREEN}Configuration refreshed.${C_RESET} Packages and services were already in place.
  Hyprland applies config changes on save, so there is nothing to restart.

EOF
else
    cat <<EOF

  ${C_GREEN}Hyprland is installed and configured.${C_RESET}

  ${C_BLUE}Next:${C_RESET}
    1. Reboot:  ${C_DIM}sudo reboot${C_RESET}
$( if [[ $DO_GREETD -eq 1 ]]; then
       echo "    2. Log in at the tuigreet prompt — it launches Hyprland for you."
   elif [[ -n $OTHER_DM ]]; then
       echo "    2. At the ${OTHER_DM%.service} login screen, pick \"Hyprland (uwsm-managed)\" as the session."
   else
       echo "    2. Log in on a TTY and run: uwsm start hyprland-uwsm.desktop"
   fi )
    3. Press ${C_YELLOW}SUPER + slash${C_RESET} for the keybind cheatsheet.

  ${C_BLUE}Essential keys:${C_RESET}
    SUPER + Return        terminal        SUPER + D    launcher
    SUPER + E             file manager    SUPER + Q    close window
    SUPER + 1..9          workspace       SUPER + C/V  copy / paste
    SUPER + Shift + S     screenshot      SUPER + X    clipboard history
    SUPER + Shift + E     power menu      SUPER + Esc  lock
    SUPER + W             wallpaper       SUPER + Shift + T  colour theme

  ${C_BLUE}Config:${C_RESET} ~/.config/hypr/  (edits apply live)
  ${C_DIM}Re-run this script any time — it will only refresh what changed.${C_RESET}

EOF
fi
