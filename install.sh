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
readonly CONFIG_DST="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"

# Default fractional scale for generated monitor lines. Hyprland requires the
# scaled resolution to land on a whole pixel, so a scale is only used when it
# divides that display cleanly; otherwise the script falls back to 1 for that
# monitor and says so. 5120x2160 / 1.6 = 3200x1350, which is exact.
DEFAULT_SCALE=1.6

# ── options ───────────────────────────────────────────────────────────────────
DO_PACKAGES=auto        # auto | yes | no  — "auto" skips when already provisioned
DO_CONFIGS=1
DO_AUR=1
DO_GAMING=1
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
  --redetect-monitors  Regenerate monitors.conf (otherwise a run leaves your
                       existing one alone, so hand-tuned layouts survive).
  --dry-run            Show what would change; write nothing.

  --no-aur             Skip building paru.
  --no-gaming          Skip multilib, Steam, gamemode, 32-bit drivers.
  --no-bluetooth       Skip bluez/blueman.
  --no-greetd          Skip the login manager.
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
        --no-aur)            DO_AUR=0 ;;
        --no-gaming)         DO_GAMING=0 ;;
        --no-bluetooth)      DO_BLUETOOTH=0 ;;
        --no-greetd)         DO_GREETD=0 ;;
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

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not root. It calls sudo where needed."
[[ -f /etc/arch-release ]] || die "This script targets Arch Linux."
command -v pacman >/dev/null || die "pacman not found."
[[ -d "$CONFIG_SRC" ]] || die "config/ directory not found next to install.sh"

if ! ping -c1 -W3 archlinux.org >/dev/null 2>&1; then
    die "No network connectivity. Bring up networking first (nmtui / iwctl)."
fi
ok "Arch Linux, network up, running as $USER"
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

# True when scaling `pixels` by `scale` lands on a whole pixel. Hyprland rejects
# a scale that does not, so this decides whether DEFAULT_SCALE is usable on a
# given display. Works in integer arithmetic (scale is taken to 3 decimals) to
# avoid float rounding: 5120 / 1.6 is exact, 1366 / 1.6 = 853.75 is not.
scale_divides() {
    local pixels="$1" scale="$2" milli
    milli=$(awk -v s="$scale" 'BEGIN { printf "%d", s * 1000 + 0.5 }')
    [[ $milli -gt 0 ]] || return 1
    (( pixels * 1000 % milli == 0 ))
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
if [[ $RUN_SYSTEM -eq 1 && $DRY_RUN -eq 0 ]]; then
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
            run sudo sed -i "s/^#\s*${key}.*/${line}/" /etc/pacman.conf
            ok "enabled $key"
        else
            run sudo sed -i "/^\[options\]/a ${line}" /etc/pacman.conf
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
            run sudo sed -i '/^#\[multilib\]/,/^#Include = .*mirrorlist/ s/^#//' /etc/pacman.conf
            ok "multilib enabled"
        fi
    fi

    step "Synchronising databases and updating the system"
    run sudo pacman -Syu --noconfirm
    ok "system up to date"

    step "Installing packages"
    if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
        ok "all ${#WANTED[@]} packages already installed"
    else
        info "${#MISSING_PKGS[@]} to install: ${MISSING_PKGS[*]}"
        run sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
        ok "packages installed"
    fi

    if [[ $DO_AUR -eq 1 ]]; then
        step "AUR helper (paru)"
        if command -v paru >/dev/null; then
            ok "paru already installed"
        elif [[ $DRY_RUN -eq 1 ]]; then
            info "[dry-run] would build paru from the AUR"
        else
            info "building paru from the AUR (a few minutes)"
            build_dir="$(mktemp -d)"
            git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$build_dir/paru-bin"
            ( cd "$build_dir/paru-bin" && makepkg -si --noconfirm )
            rm -rf "$build_dir"
            ok "paru installed"
        fi
    fi

    step "Enabling services"
    if [[ ${#PENDING_UNITS[@]} -eq 0 ]]; then
        ok "all system units already enabled"
    else
        for unit in "${PENDING_UNITS[@]}"; do
            # greetd is configured below; enable it only once that has happened.
            [[ $unit == greetd.service ]] && continue
            run sudo systemctl enable "$unit"
            ok "enabled $unit"
        done
    fi

    if systemctl --user enable pipewire.service pipewire-pulse.service wireplumber.service >/dev/null 2>&1; then
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
            sudo install -d -m 755 /etc/greetd
            sudo tee /etc/greetd/config.toml >/dev/null <<EOF
# Managed by hyprland-setup/install.sh
[terminal]
vt = 1

[default_session]
command = "tuigreet --remember --remember-user-session --asterisks --time --greeting 'Arch Linux' --cmd '${session_cmd}'"
user = "greeter"
EOF
            sudo install -d -o greeter -g greeter -m 755 /var/cache/tuigreet 2>/dev/null || true
            ok "wrote /etc/greetd/config.toml"
        fi

        unit_enabled greetd.service && ok "greetd.service already enabled" || {
            run sudo systemctl enable greetd.service
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
    # ~/.config (monitors.conf, anything you added) are never removed.
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
    monitors_conf="$CONFIG_DST/hypr/monitors.conf"

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
        ok "keeping your existing monitors.conf (--redetect-monitors to regenerate)"
        for conn in "${connected[@]:-}"; do
            [[ -n $conn ]] && info "connected: $conn"
        done
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would write monitors.conf for ${#connected[@]} display(s)"
    else
        [[ -f $monitors_conf ]] && {
            mkdir -p "$BACKUP_DIR/hypr"
            cp -p "$monitors_conf" "$BACKUP_DIR/hypr/monitors.conf"
            warn "backed up previous monitors.conf"
        }
        {
            echo "# Generated by hyprland-setup on $(date -Iseconds)."
            echo "# A re-run leaves this file alone; use --redetect-monitors to rebuild it."
            echo "# \`hyprctl monitors\` lists modes, \`nwg-displays\` is a GUI for arranging them."
            echo "#"
            echo "# Syntax: monitor = NAME, RESOLUTION@HZ, POSITION, SCALE"
            echo "#   highrr = highest refresh rate the display advertises"
            echo "#   highres = highest resolution     preferred = the display's own default"
            echo "#"
            echo "# Scale must land on a whole pixel: RESOLUTION / SCALE has to be an"
            echo "# integer, or Hyprland rejects it. ${DEFAULT_SCALE} was used below wherever"
            echo "# it divides cleanly. Check a candidate with:  hyprctl monitors"
            echo
        } > "$monitors_conf"

        if [[ ${#connected[@]} -eq 0 ]]; then
            echo "monitor = , preferred, auto, auto" >> "$monitors_conf"
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
                elif scale_divides "$width" "$DEFAULT_SCALE" && scale_divides "$height" "$DEFAULT_SCALE"; then
                    logical="$(awk -v w="$width" -v h="$height" -v s="$DEFAULT_SCALE" \
                                   'BEGIN { printf "%dx%d", w/s, h/s }')"
                    info "  scale $DEFAULT_SCALE -> ${logical} logical"
                else
                    scale=1
                    warn "  scale $DEFAULT_SCALE does not divide ${width}x${height} evenly; using 1"
                fi

                echo "monitor = ${conn}, highrr, ${x_offset}x0, ${scale}" >> "$monitors_conf"
                x_offset=$(( x_offset + ${width:-1920} ))
            done
            echo >> "$monitors_conf"
            echo "# Catch-all for any display plugged in later. If a new monitor has a" >> "$monitors_conf"
            echo "# resolution ${DEFAULT_SCALE} does not divide evenly, Hyprland will log an error" >> "$monitors_conf"
            echo "# and pick the nearest valid scale — set an explicit line for it above." >> "$monitors_conf"
            echo "monitor = , preferred, auto, ${DEFAULT_SCALE}" >> "$monitors_conf"
            ok "wrote monitors.conf for ${#connected[@]} display(s)"
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
    gpu_conf="$CONFIG_DST/hypr/gpu.conf"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would ensure gpu.conf matches: ${GPU_VENDORS[*]}"
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
#   env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card0
# List them with: ls -l /dev/dri/by-path/
EOF
            warn "multiple GPUs detected — review ~/.config/hypr/gpu.conf"
        fi

        if [[ -f $gpu_conf ]] && cmp -s "$gpu_tmp" "$gpu_conf"; then
            rm -f "$gpu_tmp"
            ok "gpu.conf already correct for: ${GPU_VENDORS[*]}"
        else
            if [[ -f $gpu_conf ]]; then
                mkdir -p "$BACKUP_DIR/hypr"
                cp -p "$gpu_conf" "$BACKUP_DIR/hypr/gpu.conf"
                warn "GPU config changed — previous version backed up"
            fi
            mkdir -p "$(dirname "$gpu_conf")"
            mv "$gpu_tmp" "$gpu_conf"
            ok "wrote gpu.conf for: ${GPU_VENDORS[*]}"
        fi
    fi

    # ── wallpaper ─────────────────────────────────────────────────────────────
    step "Wallpaper"
    wallpaper="$HOME/Pictures/wallpapers/default.png"
    if [[ -f $wallpaper ]]; then
        ok "wallpaper already present"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] would generate a ${max_w}x${max_h} gradient"
    elif command -v magick >/dev/null; then
        mkdir -p "$(dirname "$wallpaper")"
        magick -size "${max_w}x${max_h}" gradient:'#1e1e2e-#11111b' "$wallpaper"
        ok "generated ${max_w}x${max_h} gradient at $wallpaper"
    else
        warn "imagemagick not available; drop an image at $wallpaper"
    fi

    # GTK apps do not read Hyprland's config, so set the theme via gsettings.
    if [[ $DRY_RUN -eq 0 ]] && command -v gsettings >/dev/null; then
        gsettings set org.gnome.desktop.interface gtk-theme    'Adwaita-dark' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface icon-theme   'Papirus-Dark' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'  2>/dev/null || true
        gsettings set org.gnome.desktop.interface font-name    'Noto Sans 11' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'      2>/dev/null || true
        ok "applied dark GTK defaults"
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
    SUPER + 1..9          workspace       SUPER + V    toggle floating
    SUPER + Shift + S     screenshot      SUPER + X    clipboard history
    SUPER + Shift + E     power menu      SUPER + Esc  lock

  ${C_BLUE}Config:${C_RESET} ~/.config/hypr/  (edits apply live)
  ${C_DIM}Re-run this script any time — it will only refresh what changed.${C_RESET}

EOF
fi
