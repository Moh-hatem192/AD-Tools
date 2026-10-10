#!/usr/bin/env bash
# =============================================================================
#  HTU Pentesting Toolkit - General-Purpose Installer
#  Target: Kali Linux
#  Layout: ~/pentest-tools/  (general-purpose, non-category-specific tools)
#
#  Split out of the original monolithic htu-ad-setup.sh. This script installs
#  the general-purpose arsenal that is not AD/web/OT/mobile-specific: password
#  cracking, network analysis, the exploitation framework, host enumeration,
#  OSINT CLIs and the SecLists wordlist arsenal. Each tool is symlinked into
#  ~/pentest-tools/ AND /usr/local/bin so it resolves from anywhere.
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
PENTEST_ROOT="${HOME}/pentest-tools"

LOG="${PENTEST_ROOT}/install.log"
TMP="$(mktemp -d /tmp/htu-general.XXXXXX)"
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

py_deps() { # install python deps of a cloned repo, in-place, no venv
    local dir="$1" name="$2"
    if [[ -f "${dir}/requirements.txt" ]]; then
        note "installing python requirements..."
        run pip3 install --break-system-packages --no-input -q -r "${dir}/requirements.txt" \
            || note "${YELLOW}some requirements for ${name} failed (see log)${NC}"
    elif [[ -f "${dir}/pyproject.toml" || -f "${dir}/setup.py" ]]; then
        note "installing package + deps..."
        run pip3 install --break-system-packages --no-input -q "${dir}" \
            || note "${YELLOW}package install for ${name} failed (see log)${NC}"
    fi
}

clone_tool() { # clone_tool <name> <url> [dest-dir]
    local name="$1" url="$2" dest="${3:-${PENTEST_ROOT}/$1}"
    if [[ -d "${dest}/.git" ]]; then
        skip "${name} already cloned -> ${dest/#$HOME/~}"
        run git -C "$dest" pull --ff-only
        py_deps "$dest" "$name"
        return 0
    fi
    [[ -d "$dest" ]] && rm -rf "$dest"
    info "cloning ${name}..."
    if run git clone --depth 1 --quiet "$url" "$dest"; then
        py_deps "$dest" "$name"
        ok "${name} -> ${dest/#$HOME/~}"
    else
        fail "${name} (git clone ${url} failed)"
    fi
}

surface_entrypoint_global() { # surface_entrypoint_global <root> <tool> <path/inside/repo>
    # Makes the command reachable from any directory (symlink in /usr/local/bin),
    # not just from inside the cloned repo. Uses a small cd-then-exec wrapper
    # rather than a bare symlink, so a script with sibling imports still finds
    # them regardless of the caller's cwd or PATH lookup.
    local root="$1" tool="$2" rel="$3"
    local script="${rel##*/}"
    local dest="${root}/${tool}"
    if [[ -f "${dest}/${rel}" ]]; then
        chmod +x "${dest}/${rel}"
        local wrapper="${dest}/.run-${script}"
        if [[ "$(head -c2 "${dest}/${rel}")" == "#!" ]]; then
            printf '#!/usr/bin/env bash\ncd "%s" && exec ./%s "$@"\n' "$dest" "$rel" >"$wrapper"
        else
            # no shebang in the upstream script - the kernel can't pick an
            # interpreter for a bare exec, so call it through python2 explicitly.
            printf '#!/usr/bin/env bash\ncd "%s" && exec python2 ./%s "$@"\n' "$dest" "$rel" >"$wrapper"
        fi
        chmod +x "$wrapper"
        ln -sf "$wrapper" "${root}/${script}"
        run $SUDO ln -sf "$wrapper" "/usr/local/bin/${script}"
        note "${script} available system-wide (/usr/local/bin/${script}), also at ${root/#$HOME/~}/${script}"
    else
        fail "${script} (not found in the cloned ${tool} repository)"
    fi
}

# --------------------------- Tool definitions --------------------------------
# apt-pkg|binary|friendly-name    (general-purpose tools, all apt-only on Kali;
# each gets symlinked into pentest-tools/ AND /usr/local/bin)
PENTEST_PACKAGES=(
    "cyberchef|cyberchef|CyberChef"
    "flameshot|flameshot|Flameshot"
    "ksnip|ksnip|Ksnip"
    "gedit|gedit|gedit"
    "hashcat|hashcat|hashcat"
    "john|john|John the Ripper"
    "metasploit-framework|msfconsole|Metasploit Framework"
    "peass|linpeas|LinPEAS"
    "wireshark|wireshark|Wireshark"
    "nmap|nmap|Nmap"
    "theharvester|theHarvester|theHarvester"
    "recon-ng|recon-ng|Recon-ng"
    "python3-shodan|shodan|Shodan CLI"
    "python3-censys|censys|Censys CLI"
)
# name|git-url|entrypoint-inside-repo   (cloned into pentest-tools/<name>, then
# surfaced system-wide via surface_entrypoint_global)
PENTEST_GIT_TOOLS=(
    "LinEnum|https://github.com/rebootuser/LinEnum|LinEnum.sh"
)
TOTAL=$(( ${#PENTEST_PACKAGES[@]} + ${#PENTEST_GIT_TOOLS[@]} + 3 ))

# ============================== BANNER =======================================
clear 2>/dev/null || true
box "$CYAN" "HTU General-Purpose toolkit being installed" \
            "" \
            "target: ${PENTEST_ROOT/#$HOME/~}" \
            "host: $(hostname)    user: $(whoami)"

require_sudo

mkdir -p "$PENTEST_ROOT"
: >"$LOG"
printf "${GRAY}   full log: %s${NC}\n" "$LOG"

# ============================ 1. SYSTEM PREP =================================
step "System preparation (apt update + build dependencies)"
run $SUDO apt-get update && ok "package index updated" || fail "apt-get update"
BASE_DEPS=(git curl wget unzip tar 7zip build-essential
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
step "Creating ${PENTEST_ROOT/#$HOME/~} (general-purpose tools)"
if [[ -d "$PENTEST_ROOT" ]]; then
    skip "${PENTEST_ROOT/#$HOME/~} already exists"
else
    mkdir -p "$PENTEST_ROOT" && ok "${PENTEST_ROOT/#$HOME/~}" || fail "mkdir ${PENTEST_ROOT}"
fi

# ======================= 3. APT GENERAL TOOLS (system-wide) ==================
for entry in "${PENTEST_PACKAGES[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
    if have "$bin"; then
        # apt already drops these in /usr/bin, which is on PATH for every
        # user - but symlink into /usr/local/bin too so the command is
        # guaranteed to resolve from anywhere, regardless of shell/PATH quirks.
        run $SUDO ln -sf "$(command -v "$bin")" "/usr/local/bin/${bin}"
        # and keep a symlink inside pentest-tools too, so the folder is a
        # browsable index of what got installed.
        ln -sf "$(command -v "$bin")" "${PENTEST_ROOT}/${bin}"
        note "available system-wide (/usr/local/bin/${bin}), linked at ${PENTEST_ROOT/#$HOME/~}/${bin}"
    fi
done

# --- tools with no apt package, cloned straight from upstream ---
for entry in "${PENTEST_GIT_TOOLS[@]}"; do
    IFS='|' read -r name url rel <<<"$entry"
    step "Installing ${name}"
    clone_tool "$name" "$url" "${PENTEST_ROOT}/${name}"
    surface_entrypoint_global "$PENTEST_ROOT" "$name" "$rel"
done

# --- SecLists: the wordlist arsenal (dir/param/subdomain/password lists that
# ffuf, gobuster, feroxbuster etc. all feed on). apt drops it under
# /usr/share/seclists; it has no binary, so it's verified by directory. ---
step "Installing SecLists wordlist arsenal"
SECLISTS_DIR="/usr/share/seclists"
if [[ -d "$SECLISTS_DIR" && -n "$(ls -A "$SECLISTS_DIR" 2>/dev/null)" ]]; then
    skip "SecLists already present -> ${SECLISTS_DIR}"
    ln -sf "$SECLISTS_DIR" "${PENTEST_ROOT}/seclists" 2>/dev/null
else
    info "installing seclists via apt (pulls a few hundred MB, be patient)..."
    if run $SUDO apt-get install "${APT_OPTS[@]}" seclists && [[ -d "$SECLISTS_DIR" ]]; then
        ln -sf "$SECLISTS_DIR" "${PENTEST_ROOT}/seclists" 2>/dev/null
        ok "SecLists -> ${SECLISTS_DIR}  (linked at ${PENTEST_ROOT/#$HOME/~}/seclists)"
    else
        fail "SecLists (apt install 'seclists' failed - see $LOG)"
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

group "Pentest-tools (${PENTEST_ROOT/#$HOME/~})"
check_cmd cyberchef        "CyberChef"
check_cmd flameshot        "Flameshot"
check_cmd ksnip            "Ksnip"
check_cmd gedit            "gedit"
check_cmd hashcat          "hashcat"
check_cmd john             "John the Ripper"
check_cmd msfconsole       "Metasploit"
check_cmd linpeas          "LinPEAS"
check_cmd wireshark        "Wireshark"
check_cmd nmap             "Nmap"
check_cmd LinEnum.sh       "LinEnum"
check_cmd theHarvester     "theHarvester"
check_cmd recon-ng         "Recon-ng"
check_cmd shodan           "Shodan CLI"
check_cmd censys           "Censys CLI"
check_dir "$SECLISTS_DIR"  "SecLists"
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
if have tree; then tree -L 2 "$PENTEST_ROOT" 2>/dev/null | head -40
else find "$PENTEST_ROOT" -maxdepth 2 -not -path '*/.*' | sed "s|${HOME}|~|" | sort | head -40; fi

box "$GREEN" "HTU General-Purpose toolkit finished installing" \
             "wish you a successful penetration testing."
