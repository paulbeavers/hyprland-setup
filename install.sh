#!/usr/bin/env bash
#
# install.sh — add Hyprland + a working desktop to a fresh Arch Linux install.
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
DO_GREETD=1
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

  --aur                Also build paru, an AUR helper. Off by default: every
                       package this script installs is in the official repos.
  --gaming             Also enable multilib and install Steam, gamemode,
                       mangohud and the 32-bit drivers. Off by default.
  --no-bluetooth       Skip bluez/blueman.
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
        --no-greetd)         DO_GREETD=0 ;;
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
[[ -f /etc/arch-release ]] || die "This script targets Arch Linux."
command -v pacman >/dev/null || die "pacman not found."
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
    timeout 5 bash -c 'exec 3<>/dev/tcp/archlinux.org/443' 2>/dev/null && return 0
    die "No network connectivity, and $1 needs it. Connect first (nmtui / iwctl)."
}
# $USER is not set inside arch-chroot, and `set -u` turns that into an abort
# rather than an empty string. id -un always works.
ok "Arch Linux, network up, running as ${FOR_USER:-$(id -un)}"
[[ $DRY_RUN -eq 1 ]] && warn "dry run — nothing will be written"

# ── GPU detection ─────────────────────────────────────────────────────────────
# Read the PCI vendor ID straight out of sysfs rather than shelling out to
# lspci, so detection works on a minimal install with no pciutils.
#   0x1002 AMD/ATI   0x8086 Intel   0x10de NVIDIA
#   0x1af4 virtio    0x15ad VMware  0x1234 QEMU/bochs
GPU_VENDORS=()
GPU_NAMES=()

detect_gpus() {
    local dev card vendor id
    for dev in /sys/class/drm/card*/device; do
        [[ -r $dev/vendor ]] || continue
        card="$(basename "$(dirname "$dev")")"
        # Skip connector entries like card1-DP-3; we only want the device.
        [[ $card == *-* ]] && continue

        vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
        id="$(cat "$dev/device" 2>/dev/null || true)"

        case "$vendor" in
            0x1002) v=amd    ;;
            0x8086) v=intel  ;;
            0x10de) v=nvidia ;;
            0x1af4|0x15ad|0x1234) v=virtual ;;
            *)      v=unknown ;;
        esac

        # Do not list the same vendor twice on a multi-card system.
        local seen=0 existing
        for existing in ${GPU_VENDORS[@]+"${GPU_VENDORS[@]}"}; do
            [[ $existing == "$v" ]] && seen=1
        done
        [[ $seen -eq 1 ]] && continue

        GPU_VENDORS+=("$v")
        if command -v lspci >/dev/null; then
            GPU_NAMES+=("$(lspci -d "${vendor#0x}:${id#0x}" 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ *//' || true)")
        else
            GPU_NAMES+=("$v device $id")
        fi
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

# ── package sets ──────────────────────────────────────────────────────────────
# Grouped by purpose so it is obvious what to drop for a leaner system.

PKGS_BASE=(
    base-devel git curl wget man-db man-pages
    xdg-user-dirs xdg-utils
    unzip zip 7zip
    reflector pacman-contrib
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

# Everything this run is responsible for, honouring the feature flags.
WANTED=(
    "${PKGS_BASE[@]}" "${PKGS_GPU[@]}" "${PKGS_AUDIO[@]}" "${PKGS_HYPRLAND[@]}"
    "${PKGS_DESKTOP[@]}" "${PKGS_FONTS[@]}" "${PKGS_THEME[@]}" "${PKGS_SHELL[@]}"
    "${PKGS_APPS[@]}"
)
[[ $DO_GREETD    -eq 1 ]] && WANTED+=( "${PKGS_GREETD[@]}" )
[[ $DO_BLUETOOTH -eq 1 ]] && WANTED+=( "${PKGS_BLUETOOTH[@]}" )
[[ $DO_GAMING    -eq 1 ]] && WANTED+=( "${PKGS_GAMING[@]}" )

# ── package helpers ───────────────────────────────────────────────────────────
# True when a package is installed. Also handles package groups (base-devel),
# which `pacman -Qq` never matches on their own name.
pkg_installed() {
    pacman -Qq "$1" &>/dev/null && return 0

    pacman -Sg "$1" &>/dev/null || return 1
    local _grp member
    while read -r _grp member; do
        pacman -Qq "$member" &>/dev/null || return 1
    done < <(pacman -Sg "$1")
    return 0
}

unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

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

MISSING_PKGS=()
for p in "${WANTED[@]}"; do
    pkg_installed "$p" || MISSING_PKGS+=("$p")
done

PENDING_UNITS=()
unit_enabled NetworkManager.service || PENDING_UNITS+=(NetworkManager.service)
[[ $DO_BLUETOOTH -eq 1 ]] && { unit_enabled bluetooth.service || PENDING_UNITS+=(bluetooth.service); }
[[ $DO_GREETD    -eq 1 ]] && { unit_enabled greetd.service    || PENDING_UNITS+=(greetd.service); }

GREETD_CONFIGURED=0
if [[ $DO_GREETD -eq 0 ]] || grep -qs 'Managed by hyprland-setup' /etc/greetd/config.toml; then
    GREETD_CONFIGURED=1
fi

MULTILIB_READY=1
if [[ $DO_GAMING -eq 1 ]] && ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
    MULTILIB_READY=0
fi

info "packages:  ${#MISSING_PKGS[@]} of ${#WANTED[@]} missing"
# Name them here, not only in the install step. When the install step is never
# reached — no network, and nothing to reach it with — the count on its own
# says something is wrong without saying what, and finding out afterwards means
# reconstructing the package list by hand from a machine that has already
# rebooted.
[[ ${#MISSING_PKGS[@]} -gt 0 ]] && info "           ${MISSING_PKGS[*]}"
info "services:  ${#PENDING_UNITS[@]} pending"
[[ $DO_GREETD  -eq 1 ]] && info "greetd:    $( ((GREETD_CONFIGURED)) && echo configured || echo "not configured" )"
[[ $DO_GAMING  -eq 1 ]] && info "multilib:  $( ((MULTILIB_READY))    && echo enabled    || echo disabled )"

SYSTEM_COMPLETE=0
if [[ ${#MISSING_PKGS[@]} -eq 0 && ${#PENDING_UNITS[@]} -eq 0 \
      && $GREETD_CONFIGURED -eq 1 && $MULTILIB_READY -eq 1 ]]; then
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
    info "requesting sudo (needed for pacman and systemd units)…"
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

        if [[ $DRY_RUN -eq 1 ]]; then
            info "[dry-run] would write /etc/greetd/config.toml"
        else
            $SUDO install -d -m 755 /etc/greetd
            $SUDO tee /etc/greetd/config.toml >/dev/null <<EOF
# Managed by hyprland-setup/install.sh
[terminal]
vt = 1

[default_session]
command = "tuigreet --remember --remember-user-session --asterisks --time --greeting 'Arch Linux' --cmd '${session_cmd}'"
user = "greeter"
EOF
            $SUDO install -d -o greeter -g greeter -m 755 /var/cache/tuigreet 2>/dev/null || true
            ok "wrote /etc/greetd/config.toml"
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

    # GTK apps do not read Hyprland's config, so set the theme via gsettings.
    #
    # Skipped under --for-user: gsettings needs a D-Bus session bus, which a
    # chroot has none of, so every call would fail silently into `|| true` and
    # look like it worked. It is belt-and-braces anyway — gtk-3.0/settings.ini
    # and gtk-4.0/settings.ini are deployed above and carry the same values,
    # which is what actually themes the apps on first login.
    if [[ -n $FOR_USER ]]; then
        info "GTK defaults come from the deployed settings.ini (no session bus in a chroot)"
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
if [[ ${NVIDIA_NOTES:-0} -eq 1 ]]; then
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
$( [[ $DO_GREETD -eq 1 ]] \
     && echo "    2. Log in at the tuigreet prompt — it launches Hyprland for you." \
     || echo "    2. Log in on a TTY and run: uwsm start hyprland-uwsm.desktop" )
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
