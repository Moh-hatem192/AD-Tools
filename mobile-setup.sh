#!/usr/bin/env bash
# =============================================================================
#  HTU Pentesting Toolkit - Mobile / Android APK Installer
#  Target: Kali Linux
#  Layout: ~/mobile-tools/  (Android/APK analysis tools)
#
#  Split out of the original monolithic htu-ad-setup.sh. This script installs
#  ONLY the Android/APK analysis arsenal: static + dynamic tooling. Everything
#  except frida ships as an apt package on Kali; frida's CLIs come from pipx
#  (frida-tools). Each tool is symlinked into ~/mobile-tools/ AND /usr/local/bin.
# =============================================================================

set -uo pipefail

# ------------------------------- Colors --------------------------------------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------- Globals -------------------------------------
MOBILE_ROOT="${HOME}/mobile-tools"

LOG="${MOBILE_ROOT}/install.log"
TMP="$(mktemp -d /tmp/htu-mobile.XXXXXX)"
trap 'rm -rf "${TMP}"; [[ -n "${SUDO_KEEPALIVE:-}" ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export DEBIAN_FRONTEND=noninteractive
export PIP_BREAK_SYSTEM_PACKAGES=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
# a private repo or a typo'd URL must fail, never sit waiting for credentials
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
# keep dpkg from stopping on modified-conffile questions
APT_OPTS=(-y --no-install-recommends -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

OK_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
FAILED_ITEMS=()
STEP=0

if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

require_sudo() {
    # Asked once, at the very start. Everything after this runs unattended:
    # a background refresher keeps the sudo timestamp from expiring mid-run.
    [[ -z "$SUDO" ]] && { printf "   ${GREEN}[+] running as root, no password needed${NC}\n\n"; return 0; }
    if sudo -n true 2>/dev/null; then
        printf "   ${GREEN}[+] sudo already authenticated${NC}\n\n"
    else
        printf "   ${YELLOW}[!] Root access is needed for apt and /usr/local/bin symlinks.${NC}\n"
        printf "   ${GRAY}    Asked once here - the rest of the install runs unattended.${NC}\n\n"
        if ! sudo -p "   [?] Enter sudo password for $(whoami): " -v; then
            printf "\n${RED}   [-] Could not obtain root privileges. Aborting.${NC}\n\n"
            exit 1
        fi
        printf "   ${GREEN}[+] authenticated - sit back, this takes a few minutes${NC}\n\n"
    fi
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPALIVE=$!
}

# ------------------------------ UI helpers -----------------------------------
box() {
    # box <color> <line1> [line2...]
    local color="$1"; shift
    local lines=("$@") width=0 l
    for l in "${lines[@]}"; do (( ${#l} > width )) && width=${#l}; done
    width=$((width + 6))
    printf "\n${color}╔"; printf '═%.0s' $(seq 1 $width); printf "╗${NC}\n"
    for l in "${lines[@]}"; do
        local pad=$(( (width - ${#l}) / 2 ))
        local rpad=$(( width - ${#l} - pad ))
        printf "${color}║${NC}%*s${BOLD}%s${NC}%*s${color}║${NC}\n" "$pad" "" "$l" "$rpad" ""
    done
    printf "${color}╚"; printf '═%.0s' $(seq 1 $width); printf "╝${NC}\n\n"
}

step()    { STEP=$((STEP+1)); printf "\n${BLUE}[%02d/%02d]${NC} ${BOLD}%s${NC}\n" "$STEP" "$TOTAL" "$1"; }
ok()      { OK_COUNT=$((OK_COUNT+1));     printf "   ${GREEN}[+] %s${NC}\n" "$1"; }
skip()    { SKIP_COUNT=$((SKIP_COUNT+1)); printf "   ${PURPLE}[=] %s${NC}\n" "$1"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT+1)); FAILED_ITEMS+=("$1"); printf "   ${RED}[-] %s${NC}\n" "$1"; }
info()    { printf "   ${CYAN}[*] %s${NC}\n" "$1"; }
note()    { printf "   ${GRAY}    %s${NC}\n" "$1"; }

run() { # silent runner, everything to the log
    echo "### $* ###" >>"$LOG" 2>&1
    "$@" >>"$LOG" 2>&1
}

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------- Install primitives -------------------------------
apt_pkg() { # apt_pkg <pkg> <binary-to-check> <friendly-name>
    local pkg="$1" bin="$2" name="$3"
    if have "$bin"; then
        skip "${name} already installed ($(command -v "$bin"))"
        return 0
    fi
    info "installing ${name} via apt..."
    if run $SUDO apt-get install "${APT_OPTS[@]}" "$pkg" && have "$bin"; then
        ok "${name} installed ($(command -v "$bin"))"
    else
        fail "${name} (apt install '$pkg' failed - see $LOG)"
    fi
}

# --------------------------- Tool definitions --------------------------------
# apt-pkg|binary|friendly-name    (Android/APK analysis - all apt on Kali;
# each gets symlinked into mobile-tools/ AND /usr/local/bin)
MOBILE_PACKAGES=(
    "apktool|apktool|Apktool"
    "jadx|jadx-gui|JADX (jadx-gui)"
    "dex2jar|d2j-dex2jar|dex2jar"
    "apksigner|apksigner|apksigner"
    "ghidra|ghidra|Ghidra"
)
TOTAL=$(( ${#MOBILE_PACKAGES[@]} + 3 ))

# ============================== BANNER =======================================
clear 2>/dev/null || true
box "$CYAN" "HTU Mobile toolkit being installed" \
            "" \
            "target: ${MOBILE_ROOT/#$HOME/~}" \
            "host: $(hostname)    user: $(whoami)"

require_sudo

mkdir -p "$MOBILE_ROOT"
: >"$LOG"
printf "${GRAY}   full log: %s${NC}\n" "$LOG"

# ============================ 1. SYSTEM PREP =================================
step "System preparation (apt update + build dependencies)"
run $SUDO apt-get update && ok "package index updated" || fail "apt-get update"
BASE_DEPS=(git curl wget unzip tar build-essential
           python3 python3-pip python3-dev pipx tree)
info "ensuring base dependencies..."
# A single unavailable name makes apt abort the entire transaction, so only
# ask for packages that actually have a candidate in the configured repos.
AVAILABLE=(); UNAVAILABLE=()
for p in "${BASE_DEPS[@]}"; do
    if [[ -n "$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | grep -v '^(none)$')" ]]; then
        AVAILABLE+=("$p")
    else
        UNAVAILABLE+=("$p")
    fi
done
(( ${#UNAVAILABLE[@]} )) && note "no candidate in repos, skipping: ${UNAVAILABLE[*]}"
if run $SUDO apt-get install "${APT_OPTS[@]}" "${AVAILABLE[@]}"; then
    ok "base dependencies present (${#AVAILABLE[@]} packages)"
else
    note "${YELLOW}bulk install failed, retrying one by one...${NC}"
    BAD=()
    for p in "${AVAILABLE[@]}"; do
        run $SUDO apt-get install "${APT_OPTS[@]}" "$p" || BAD+=("$p")
    done
    if (( ${#BAD[@]} )); then fail "base dependencies: ${BAD[*]}"; else ok "base dependencies present"; fi
fi
run pipx ensurepath

# ============================ 2. DIRECTORY TREE ==============================
step "Creating ${MOBILE_ROOT/#$HOME/~} (Android/APK analysis tools)"
if [[ -d "$MOBILE_ROOT" ]]; then
    skip "${MOBILE_ROOT/#$HOME/~} already exists"
else
    mkdir -p "$MOBILE_ROOT" && ok "${MOBILE_ROOT/#$HOME/~}" || fail "mkdir ${MOBILE_ROOT}"
fi

# ======================= 3. APT MOBILE TOOLS (system-wide) ===================
for entry in "${MOBILE_PACKAGES[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
    if have "$bin"; then
        run $SUDO ln -sf "$(command -v "$bin")" "/usr/local/bin/${bin}"
        ln -sf "$(command -v "$bin")" "${MOBILE_ROOT}/${bin}"
        note "available system-wide (/usr/local/bin/${bin}), linked at ${MOBILE_ROOT/#$HOME/~}/${bin}"
    fi
done

# --- Frida: dynamic instrumentation toolkit. pipx frida-tools ships the
# frida / frida-ps / frida-trace CLIs. The on-device frida-server (matching
# frida version AND device/emulator arch) still has to be pushed separately
# at engagement time - the CLI alone does not include it. ---
step "Installing Frida (frida-tools)"
if have frida; then
    skip "frida already installed ($(command -v frida))"
else
    info "installing frida-tools via pipx..."
    if run pipx install --force frida-tools && { have frida || { export PATH="${HOME}/.local/bin:$PATH"; have frida; }; }; then
        ln -sf "$(command -v frida)" "${MOBILE_ROOT}/frida" 2>/dev/null
        ok "frida installed ($(command -v frida))"
        note "push a matching frida-server to the device/emulator before dynamic work"
    else
        fail "frida (pipx install failed - see $LOG)"
    fi
fi

# ============================ FINAL VERIFICATION =============================
box "$YELLOW" "QUICK CHECK - verifying every tool"

MISSING=0
MISSING_DETAILS=()
COL=0
COLS=3

_mark() { # _mark <1|0> <label> <detail-if-missing>
    if (( $1 )); then
        printf "   ${GREEN}\xe2\x9c\x93${NC} ${GREEN}%-24s${NC}" "$2"
    else
        printf "   ${RED}\xe2\x9c\x97${NC} ${RED}%-24s${NC}" "$2"
        MISSING=$((MISSING+1)); MISSING_DETAILS+=("$2  ->  $3")
    fi
    COL=$((COL+1))
    (( COL % COLS == 0 )) && printf "\n"
    return 0
}
_endrow()   { (( COL % COLS != 0 )) && printf "\n"; COL=0; return 0; }
group()     { _endrow; printf "\n${BOLD}${CYAN} %s${NC}\n" "$1"; }
check_cmd() { if have "$1";      then _mark 1 "$2" ""; else _mark 0 "$2" "'$1' not found in PATH"; fi; }
check_dir() { if [[ -e "$1" ]];  then _mark 1 "$2" ""; else _mark 0 "$2" "${1/#$HOME/~}"; fi; }

group "Mobile-tools (${MOBILE_ROOT/#$HOME/~})"
check_cmd apktool          "Apktool"
check_cmd jadx-gui         "JADX (jadx-gui)"
check_cmd d2j-dex2jar      "dex2jar"
check_cmd apksigner        "apksigner"
check_cmd ghidra           "Ghidra"
check_cmd frida            "Frida"
_endrow

if (( MISSING > 0 )); then
    printf "\n${RED}${BOLD} Missing (%d):${NC}\n" "$MISSING"
    for m in "${MISSING_DETAILS[@]}"; do printf "   ${RED}\xe2\x9c\x97${NC} ${GRAY}%s${NC}\n" "$m"; done
fi

printf "\n${BOLD} Summary:${NC}  ${GREEN}%d installed${NC}  |  ${PURPLE}%d already present${NC}  |  ${RED}%d failed${NC}  |  ${RED}%d missing after checks${NC}\n" \
    "$OK_COUNT" "$SKIP_COUNT" "$FAIL_COUNT" "$MISSING"

if (( FAIL_COUNT > 0 )); then
    printf "\n${RED}${BOLD} Failed steps:${NC}\n"
    for f in "${FAILED_ITEMS[@]}"; do printf "   ${RED}- %s${NC}\n" "$f"; done
    printf "   ${GRAY}details in %s${NC}\n" "$LOG"
fi

printf "\n${GRAY} Directory tree:${NC}\n"
if have tree; then tree -L 2 "$MOBILE_ROOT" 2>/dev/null | head -40
else find "$MOBILE_ROOT" -maxdepth 2 -not -path '*/.*' | sed "s|${HOME}|~|" | sort | head -40; fi

box "$GREEN" "HTU Mobile toolkit finished installing" \
             "wish you a successful penetration testing."
