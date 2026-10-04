#!/usr/bin/env bash
# =============================================================================
#  HTU Pentesting Toolkit - OT / ICS / SCADA Installer
#  Target: Kali Linux
#  Layout: ~/OT-tools/  (Modbus/ICS/SCADA-specific tools)
#
#  Split out of the original monolithic htu-ad-setup.sh. This script installs
#  ONLY the Modbus/ICS/SCADA arsenal: mbtget, PLCScan, ModbusPal, pymodbus,
#  modbus-cli, and the OT-toolkit attack scripts fetched from the AD-Tools repo.
#  Everything is symlinked into ~/OT-tools/ AND /usr/local/bin.
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
OT_ROOT="${HOME}/OT-tools"
OT_TOOLKIT="${OT_ROOT}/ot-toolkit"

ADTOOLS_REPO="https://github.com/Moh-hatem192/AD-Tools"
ADTOOLS_CACHE="${OT_ROOT}/.AD-Tools"

LOG="${OT_ROOT}/install.log"
TMP="$(mktemp -d /tmp/htu-ot.XXXXXX)"
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
    local name="$1" url="$2" dest="${3:-${OT_ROOT}/$1}"
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
    # rather than a bare symlink, so a script with sibling imports (e.g.
    # plcscan.py importing modbus.py) still finds them regardless of the
    # caller's cwd or PATH lookup.
    local root="$1" tool="$2" rel="$3"
    local script="${rel##*/}"
    local dest="${root}/${tool}"
    if [[ -f "${dest}/${rel}" ]]; then
        chmod +x "${dest}/${rel}"
        local wrapper="${dest}/.run-${script}"
        if [[ "$(head -c2 "${dest}/${rel}")" == "#!" ]]; then
            printf '#!/usr/bin/env bash\ncd "%s" && exec ./%s "$@"\n' "$dest" "$rel" >"$wrapper"
        else
            # no shebang in the upstream script (e.g. plcscan.py, a legacy
            # python2-only tool) - the kernel can't pick an interpreter for
            # a bare exec, so call it through python2 explicitly.
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
# name|git-url|entrypoint-inside-repo   (Modbus/ICS-specific - cloned into
# OT-tools/<name>, then surfaced system-wide)
OT_GIT_TOOLS=(
    "mbtget|https://github.com/sourceperl/mbtget|scripts/mbtget"
    "plcscan|https://github.com/meeas/plcscan|plcscan.py"
)
# apt-pkg|binary|friendly-name    (runtime deps for the custom-built tools below
# - not tools in their own right, so NOT symlinked into OT-tools/)
OT_DEPS=(
    "python2|python2|Python 2 (PLCScan dependency)"
    "default-jre|java|Java Runtime (ModbusPal dependency)"
)
TOTAL=$(( ${#OT_GIT_TOOLS[@]} + ${#OT_DEPS[@]} + 7 ))

# ============================== BANNER =======================================
clear 2>/dev/null || true
box "$CYAN" "HTU OT toolkit being installed" \
            "" \
            "target: ${OT_ROOT/#$HOME/~}" \
            "host: $(hostname)    user: $(whoami)"

require_sudo

mkdir -p "$OT_ROOT"
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
# Kept out of pentest-tools/ on purpose: these tools only exist for Modbus/ICS
# work, unlike nmap/nuclei/metasploit/wireshark etc. which are general-purpose
# and just happen to get used in an OT engagement too.
step "Creating ${OT_ROOT/#$HOME/~} (Modbus/ICS/SCADA-specific tools)"
if [[ -d "$OT_ROOT" ]]; then
    skip "${OT_ROOT/#$HOME/~} already exists"
else
    mkdir -p "$OT_ROOT" && ok "${OT_ROOT/#$HOME/~}" || fail "mkdir ${OT_ROOT}"
fi

# ======================= 3. GIT-CLONED OT TOOLS ==============================
# runtime dependencies for PLCScan / ModbusPal first ---
for entry in "${OT_DEPS[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
done

# --- tools with no apt package, cloned straight from upstream ---
for entry in "${OT_GIT_TOOLS[@]}"; do
    IFS='|' read -r name url rel <<<"$entry"
    step "Installing ${name}"
    clone_tool "$name" "$url" "${OT_ROOT}/${name}"
    surface_entrypoint_global "$OT_ROOT" "$name" "$rel"
done

# --- ModbusPal: Java GUI simulator, no apt package, upstream ships only a jar ---
step "Installing ModbusPal (Modbus/TCP simulator)"
MODBUSPAL_DIR="${OT_ROOT}/modbuspal"
mkdir -p "$MODBUSPAL_DIR"
if [[ -f "${MODBUSPAL_DIR}/ModbusPal.jar" ]]; then
    skip "ModbusPal already present -> ${MODBUSPAL_DIR/#$HOME/~}/ModbusPal.jar"
else
    info "downloading ModbusPal.jar (official sourceforge release)..."
    if run curl -fsSL -o "${MODBUSPAL_DIR}/ModbusPal.jar" \
        "https://sourceforge.net/projects/modbuspal/files/modbuspal/RC%20version%201.6b/ModbusPal.jar/download"; then
        ok "ModbusPal.jar -> ${MODBUSPAL_DIR/#$HOME/~}/ModbusPal.jar"
    else
        fail "ModbusPal (download failed)"
    fi
fi
if [[ -f "${MODBUSPAL_DIR}/ModbusPal.jar" ]]; then
    printf '#!/usr/bin/env bash\nexec java -jar "%s/ModbusPal.jar" "$@"\n' "$MODBUSPAL_DIR" \
        >"${MODBUSPAL_DIR}/modbuspal"
    chmod +x "${MODBUSPAL_DIR}/modbuspal"
    ln -sf "${MODBUSPAL_DIR}/modbuspal" "${OT_ROOT}/modbuspal"
    run $SUDO ln -sf "${MODBUSPAL_DIR}/modbuspal" "/usr/local/bin/modbuspal"
    note "modbuspal available system-wide (/usr/local/bin/modbuspal)"
fi

# --- pymodbus: apt's python3-pymodbus is library-only (no CLI binary in the
# .deb) - pip is what actually ships the pymodbus.simulator console script. ---
step "Installing pymodbus (pymodbus.simulator)"
if have pymodbus.simulator; then
    skip "pymodbus.simulator already installed ($(command -v pymodbus.simulator))"
else
    info "installing pymodbus via pip..."
    if run pip3 install --break-system-packages --no-input -q pymodbus && have pymodbus.simulator; then
        BIN="$(command -v pymodbus.simulator)"
        run $SUDO ln -sf "$BIN" "/usr/local/bin/pymodbus.simulator"
        ln -sf "$BIN" "${OT_ROOT}/pymodbus.simulator"
        ok "pymodbus.simulator installed (${BIN}), linked system-wide and at ${OT_ROOT/#$HOME/~}"
    else
        fail "pymodbus (pip install failed - see $LOG)"
    fi
fi

# --- modbus-cli: no apt package; the gem drops a binary literally named
# "modbus" (that's not a typo - "modbus-cli" is just the gem's package name). ---
step "Installing modbus-cli (Ruby gem)"
if have modbus; then
    skip "modbus-cli already installed ($(command -v modbus))"
else
    info "installing modbus-cli via gem..."
    run $SUDO apt-get install "${APT_OPTS[@]}" ruby ruby-dev
    if run $SUDO gem install --no-document modbus-cli && have modbus; then
        run $SUDO ln -sf "$(command -v modbus)" "/usr/local/bin/modbus"
        ln -sf "$(command -v modbus)" "${OT_ROOT}/modbus"
        ok "modbus-cli installed ($(command -v modbus)), linked at ${OT_ROOT/#$HOME/~}/modbus"
    else
        fail "modbus-cli (gem install failed - see $LOG)"
    fi
fi

# =================== 4. OT-toolkit (from AD-Tools repo) ======================
# The ICS/SCADA attack scripts live inside the AD-Tools repo, under OT-toolkit/.
step "Fetching OT-toolkit scripts from AD-Tools"
if [[ -d "${ADTOOLS_CACHE}/.git" ]]; then
    info "updating AD-Tools repository..."
    run git -C "$ADTOOLS_CACHE" pull --ff-only || note "${YELLOW}pull failed, using cached copy${NC}"
else
    info "cloning ${ADTOOLS_REPO}..."
    rm -rf "$ADTOOLS_CACHE"
    run git clone --depth 1 --quiet "$ADTOOLS_REPO" "$ADTOOLS_CACHE" \
        || fail "AD-Tools repository clone"
fi

if [[ -d "${ADTOOLS_CACHE}/OT-toolkit" ]]; then
    mkdir -p "$OT_TOOLKIT"
    cp -rf "${ADTOOLS_CACHE}/OT-toolkit/." "${OT_TOOLKIT}/" 2>>"$LOG"
    find "$OT_TOOLKIT" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
    n=$(find "$OT_TOOLKIT" -type f ! -path '*/.git/*' | wc -l)
    ok "${OT_TOOLKIT/#$HOME/~}  (${n} files)"
else
    fail "OT-toolkit not found in AD-Tools repository"
fi

# --- surface each OT-toolkit script system-wide, same treatment as every
# other OT-tools entry. ---
step "Surfacing OT-toolkit scripts (ICS/SCADA attack tools) system-wide"
OT_SCRIPTS=(attack_pump.py device_fingerprint.py recon_sweep.py sensor_spoof.py unit_id_scanner.py)
if [[ ! -d "$OT_TOOLKIT" ]]; then
    fail "OT-toolkit scripts (not fetched - see the AD-Tools step above)"
else
    MISSING_OT=0
    for script in "${OT_SCRIPTS[@]}"; do
        if [[ -f "${OT_TOOLKIT}/${script}" ]]; then
            chmod +x "${OT_TOOLKIT}/${script}"
            run $SUDO ln -sf "${OT_TOOLKIT}/${script}" "/usr/local/bin/${script}"
            ln -sf "${OT_TOOLKIT}/${script}" "${OT_ROOT}/${script}"
        else
            fail "${script} (missing from OT-toolkit)"
            MISSING_OT=1
        fi
    done
    (( MISSING_OT == 0 )) && ok "OT-toolkit scripts available system-wide (attack_pump.py, device_fingerprint.py, recon_sweep.py, sensor_spoof.py, unit_id_scanner.py)"
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

group "OT-tools (${OT_ROOT/#$HOME/~})"
check_cmd mbtget           "mbtget"
check_cmd plcscan.py       "PLCScan"
check_cmd modbuspal        "ModbusPal"
check_cmd pymodbus.simulator "pymodbus"
check_cmd modbus           "modbus-cli"
check_cmd attack_pump.py         "OT: attack_pump"
check_cmd device_fingerprint.py  "OT: device_fingerprint"
check_cmd recon_sweep.py         "OT: recon_sweep"
check_cmd sensor_spoof.py        "OT: sensor_spoof"
check_cmd unit_id_scanner.py     "OT: unit_id_scanner"
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
if have tree; then tree -L 2 "$OT_ROOT" -I '.AD-Tools' 2>/dev/null | head -40
else find "$OT_ROOT" -maxdepth 2 -not -path '*/.*' | sed "s|${HOME}|~|" | sort | head -40; fi

box "$GREEN" "HTU OT toolkit finished installing" \
             "wish you a successful penetration testing."
