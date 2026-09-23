#!/usr/bin/env bash
# =============================================================================
#  HTU Pentesting Toolkit - Automated Installer
#  Target: Kali Linux
#  Layout: ~/AD/{tools,executables,powershell-scripts,CVEs,tunneling/ligolo}
#          ~/pentest-tools/  (general-purpose, non-AD-specific tools)
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
AD_ROOT="${HOME}/AD"
PENTEST_ROOT="${HOME}/pentest-tools"
OT_TOOLKIT="${PENTEST_ROOT}/ot-toolkit"
TOOLS="${AD_ROOT}/tools"
EXECUTABLES="${AD_ROOT}/executables"
PSSCRIPTS="${AD_ROOT}/powershell-scripts"
CVES="${AD_ROOT}/CVEs"
TUNNELING="${AD_ROOT}/tunneling"
LIGOLO="${TUNNELING}/ligolo"
LIGOLO_AGENTS="${LIGOLO}/agents"
LIGOLO_PROXY="${LIGOLO}/proxy"

LIGOLO_VER="0.9.1"
KERBRUTE_VER="v1.0.3"

# Release binaries are per-architecture; map dpkg arch -> release asset arch.
case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64)  LIGOLO_ARCH="amd64"; KERBRUTE_ARCH="amd64" ;;
    arm64|aarch64) LIGOLO_ARCH="arm64"; KERBRUTE_ARCH=""      ;;
    armhf|armv7l)  LIGOLO_ARCH="armv7"; KERBRUTE_ARCH=""      ;;
    i386|i686)     LIGOLO_ARCH="386";   KERBRUTE_ARCH="386"   ;;
    *)             LIGOLO_ARCH="amd64"; KERBRUTE_ARCH="amd64" ;;
esac
ADTOOLS_REPO="https://github.com/Moh-hatem192/AD-Tools"
ADTOOLS_CACHE="${AD_ROOT}/.AD-Tools"

LOG="${AD_ROOT}/install.log"
TMP="$(mktemp -d /tmp/htu-ad.XXXXXX)"
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

apt_then_pipx() { # apt_then_pipx <apt-pkg> <binary> <pipx-spec> <friendly-name>
    local pkg="$1" bin="$2" spec="$3" name="$4"
    if have "$bin"; then
        skip "${name} already installed ($(command -v "$bin"))"
        return 0
    fi
    info "installing ${name} via apt..."
    if run $SUDO apt-get install "${APT_OPTS[@]}" "$pkg" && have "$bin"; then
        ok "${name} installed ($(command -v "$bin"))"
        return 0
    fi
    info "apt unavailable for ${name}, falling back to pipx..."
    if run pipx install --force "$spec" && { have "$bin" || { export PATH="${HOME}/.local/bin:$PATH"; have "$bin"; }; }; then
        ok "${name} installed via pipx ($(command -v "$bin"))"
    else
        fail "${name} (apt + pipx both failed - see $LOG)"
    fi
}

apt_then_gem() { # apt_then_gem <apt-pkg> <binary> <gem-name> <friendly-name>
    local pkg="$1" bin="$2" gem="$3" name="$4"
    if have "$bin"; then
        skip "${name} already installed ($(command -v "$bin"))"
        return 0
    fi
    info "installing ${name} via apt..."
    if run $SUDO apt-get install "${APT_OPTS[@]}" "$pkg" && have "$bin"; then
        ok "${name} installed ($(command -v "$bin"))"
        return 0
    fi
    info "apt unavailable for ${name}, falling back to rubygems..."
    run $SUDO apt-get install "${APT_OPTS[@]}" ruby ruby-dev
    if run $SUDO gem install --no-document "$gem" && have "$bin"; then
        ok "${name} installed via gem ($(command -v "$bin"))"
    else
        fail "${name} (apt + gem both failed - see $LOG)"
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
    local name="$1" url="$2" dest="${3:-${TOOLS}/$1}"
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

surface_entrypoint() { # surface_entrypoint <tool> <path/inside/repo.py> [pip-dep...]
    local tool="$1" rel="$2"; shift 2
    local script="${rel##*/}"
    if [[ -f "${TOOLS}/${tool}/${rel}" ]]; then
        chmod +x "${TOOLS}/${tool}/${rel}"
        ln -sf "$rel" "${TOOLS}/${tool}/${script}"
        (( $# )) && { run pip3 install --break-system-packages --no-input -q "$@" \
            || note "${YELLOW}some ${script} deps failed (see log)${NC}"; }
        note "${script} linked at ${TOOLS/#$HOME/~}/${tool}/${script}"
    else
        fail "${script} (not found in the cloned ${tool} repository)"
    fi
}

surface_entrypoint_global() { # surface_entrypoint_global <tool> <path/inside/repo>
    # Like surface_entrypoint, but for pentest-tools: makes the command reachable
    # from any directory (symlink in /usr/local/bin), not just from inside the
    # cloned repo. Uses a small cd-then-exec wrapper rather than a bare symlink,
    # so a script with sibling imports (e.g. plcscan.py importing modbus.py)
    # still finds them regardless of the caller's cwd or PATH lookup.
    local tool="$1" rel="$2"
    local script="${rel##*/}"
    local dest="${PENTEST_ROOT}/${tool}"
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
        ln -sf "$wrapper" "${PENTEST_ROOT}/${script}"
        run $SUDO ln -sf "$wrapper" "/usr/local/bin/${script}"
        note "${script} available system-wide (/usr/local/bin/${script}), also at ${PENTEST_ROOT/#$HOME/~}/${script}"
    else
        fail "${script} (not found in the cloned ${tool} repository)"
    fi
}

# ============================== BANNER =======================================
clear 2>/dev/null || true
box "$CYAN" "HTU Pentesting Toolkit being installed." \
            "" \
            "target: ${AD_ROOT/#$HOME/~} + ${PENTEST_ROOT/#$HOME/~}" \
            "host: $(hostname)    user: $(whoami)"

require_sudo

mkdir -p "$AD_ROOT"
: >"$LOG"
printf "${GRAY}   full log: %s${NC}\n" "$LOG"

# --------------------------- Tool definitions --------------------------------
# name|git-url
GIT_TOOLS=(
    "GhostSPN|https://github.com/p0dalirius/GhostSPN"
    "GPOwned|https://github.com/X-C3LL/GPOwned"
    "krbrelayx|https://github.com/dirkjanm/krbrelayx"
    "PetitPotam|https://github.com/topotam/PetitPotam"
    "PKINITtools|https://github.com/dirkjanm/PKINITtools"
    "pyGPOAbuse|https://github.com/Hackndo/pyGPOAbuse"
    "targetedKerberoast|https://github.com/ShutdownRepo/targetedKerberoast"
    "PassTheCert|https://github.com/AlmondOffSec/PassTheCert"
    "pywhisker|https://github.com/ShutdownRepo/pywhisker"
    "windapsearch|https://github.com/ropnop/windapsearch"
    "powerview.py|https://github.com/aniqfakhrul/powerview.py"
)
# apt-pkg|binary|pipx-spec|friendly-name    ('-' spec = apt only)
PACKAGES=(
    "python3-impacket|impacket-secretsdump|impacket|impacket toolkit"
    "netexec|netexec|git+https://github.com/Pennyw0rth/NetExec|netexec"
    "evil-winrm|evil-winrm|gem:evil-winrm|evil-winrm"
    "certipy-ad|certipy-ad|certipy-ad|certipy"
    "bloodyad|bloodyad|bloodyAD|bloodyAD"
    "bloodhound.py|bloodhound-python|bloodhound-ce|bloodhound-python"
    "ldap-utils|ldapsearch|-|ldapsearch (ldap-utils)"
)
# apt-pkg|binary|friendly-name    (general-purpose tools, all apt-only on Kali;
# each gets symlinked into pentest-tools/ AND /usr/local/bin, see section 8)
PENTEST_PACKAGES=(
    "cyberchef|cyberchef|CyberChef"
    "flameshot|flameshot|Flameshot"
    "hashcat|hashcat|hashcat"
    "john|john|John the Ripper"
    "gobuster|gobuster|Gobuster"
    "ffuf|ffuf|ffuf"
    "metasploit-framework|msfconsole|Metasploit Framework"
    "peass|linpeas|LinPEAS"
    "whatweb|whatweb|WhatWeb"
    "wireshark|wireshark|Wireshark"
    "nmap|nmap|Nmap"
    "burpsuite|burpsuite|Burp Suite"
    "theharvester|theHarvester|theHarvester"
    "recon-ng|recon-ng|Recon-ng"
    "python3-shodan|shodan|Shodan CLI"
    "python3-censys|censys|Censys CLI"
    "nuclei|nuclei|Nuclei"
)
# apt-pkg|binary|friendly-name    (runtime deps for the custom-built tools below
# - not tools in their own right, so NOT symlinked into pentest-tools/)
PENTEST_DEPS=(
    "python2|python2|Python 2 (PLCScan dependency)"
    "default-jre|java|Java Runtime (ModbusPal dependency)"
    "golang-go|go|Go toolchain (Wappalyzer CLI dependency)"
)
# name|git-url|entrypoint-inside-repo   (cloned into pentest-tools/<name>, then
# surfaced system-wide via surface_entrypoint_global, see section 8)
PENTEST_GIT_TOOLS=(
    "LinEnum|https://github.com/rebootuser/LinEnum|LinEnum.sh"
    "mbtget|https://github.com/sourceperl/mbtget|scripts/mbtget"
    "plcscan|https://github.com/meeas/plcscan|plcscan.py"
)
TOTAL=$(( ${#GIT_TOOLS[@]} + ${#PACKAGES[@]} + ${#PENTEST_PACKAGES[@]} \
        + ${#PENTEST_DEPS[@]} + ${#PENTEST_GIT_TOOLS[@]} + 12 ))

# ============================ 1. SYSTEM PREP =================================
step "System preparation (apt update + build dependencies)"
run $SUDO apt-get update && ok "package index updated" || fail "apt-get update"
BASE_DEPS=(git curl wget unzip tar 7zip build-essential
           python3 python3-pip python3-dev pipx
           libssl-dev libffi-dev libldap2-dev libsasl2-dev
           ldap-utils krb5-user rlwrap tree)
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
step "Creating directory structure under ${AD_ROOT/#$HOME/~}"
for d in "$TOOLS" "$EXECUTABLES" "$PSSCRIPTS" "$CVES" "$LIGOLO_AGENTS" "$LIGOLO_PROXY"; do
    if [[ -d "$d" ]]; then
        skip "${d/#$HOME/~} already exists"
    else
        mkdir -p "$d" && ok "${d/#$HOME/~}" || fail "mkdir ${d}"
    fi
done

# ======================= 3. GLOBAL (SYSTEM-WIDE) TOOLS =======================
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg bin spec name <<<"$entry"
    step "Installing ${name} (system-wide)"
    case "$spec" in
        gem:*) apt_then_gem  "$pkg" "$bin" "${spec#gem:}" "$name" ;;
        -)     apt_pkg       "$pkg" "$bin" "$name" ;;
        *)     apt_then_pipx "$pkg" "$bin" "$spec" "$name" ;;
    esac
done

# ============================ 4. GIT-CLONED TOOLS ============================
for entry in "${GIT_TOOLS[@]}"; do
    IFS='|' read -r name url <<<"$entry"
    step "Installing ${name}"
    clone_tool "$name" "$url"
    # A couple of repos keep their entry point one directory down (next to a C#
    # port, or inside the python package). Surface it at the tool root so the
    # path to run is always <tool>/<script>.py, and pull the extra deps.
    case "$name" in
        PassTheCert) surface_entrypoint "$name" "Python/passthecert.py" ldap3 pyasn1 pycryptodome ;;
        pywhisker)   surface_entrypoint "$name" "pywhisker/pywhisker.py" ldap3 pyasn1 pycryptodome rich ;;
    esac
done

# ============================== 5. KERBRUTE ==================================
step "Installing kerbrute"
if [[ -z "$KERBRUTE_ARCH" ]]; then
    fail "kerbrute (upstream ships no linux binary for this architecture; build from source with: go install github.com/ropnop/kerbrute@latest)"
elif have kerbrute; then
    skip "kerbrute already installed ($(command -v kerbrute))"
else
    info "downloading kerbrute ${KERBRUTE_VER} (linux/${KERBRUTE_ARCH})..."
    mkdir -p "${TOOLS}/kerbrute"
    if run curl -fsSL -o "${TOOLS}/kerbrute/kerbrute" \
        "https://github.com/ropnop/kerbrute/releases/download/${KERBRUTE_VER}/kerbrute_linux_${KERBRUTE_ARCH}"; then
        chmod +x "${TOOLS}/kerbrute/kerbrute"
        run $SUDO ln -sf "${TOOLS}/kerbrute/kerbrute" /usr/local/bin/kerbrute
        # windows build kept alongside for post-exploitation use
        run curl -fsSL -o "${TOOLS}/kerbrute/kerbrute.exe" \
            "https://github.com/ropnop/kerbrute/releases/download/${KERBRUTE_VER}/kerbrute_windows_amd64.exe"
        if have kerbrute; then
            ok "kerbrute installed (/usr/local/bin/kerbrute)"
        else
            fail "kerbrute (symlink to /usr/local/bin failed)"
        fi
    else
        fail "kerbrute (download failed)"
    fi
fi

# ============================== 6. LIGOLO-NG =================================
step "Installing ligolo-ng ${LIGOLO_VER} (proxy + agents)"
LIGOLO_BASE="https://github.com/nicocha30/ligolo-ng/releases/download/v${LIGOLO_VER}"

# --- proxy (linux) ---
if [[ -x "${LIGOLO_PROXY}/proxy" ]]; then
    skip "ligolo proxy already present -> ${LIGOLO_PROXY/#$HOME/~}/proxy"
else
    info "downloading ligolo-ng proxy..."
    if run curl -fsSL -o "${LIGOLO_PROXY}/ligolo-ng_proxy_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz" \
        "${LIGOLO_BASE}/ligolo-ng_proxy_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz"; then
        run tar -xzf "${LIGOLO_PROXY}/ligolo-ng_proxy_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz" -C "${LIGOLO_PROXY}"
        if [[ -f "${LIGOLO_PROXY}/proxy" ]]; then
            chmod +x "${LIGOLO_PROXY}/proxy"
            run $SUDO ln -sf "${LIGOLO_PROXY}/proxy" /usr/local/bin/ligolo-proxy
            ok "ligolo proxy -> ${LIGOLO_PROXY/#$HOME/~}/proxy  (also: ligolo-proxy)"
        else
            fail "ligolo proxy (extraction produced no 'proxy' binary)"
        fi
    else
        fail "ligolo proxy (download failed)"
    fi
fi

# --- linux agent ---
if [[ -x "${LIGOLO_AGENTS}/linux-agent" ]]; then
    skip "ligolo linux-agent already present"
else
    info "downloading ligolo-ng linux agent..."
    if run curl -fsSL -o "${LIGOLO_AGENTS}/ligolo-ng_agent_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz" \
        "${LIGOLO_BASE}/ligolo-ng_agent_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz"; then
        run tar -xzf "${LIGOLO_AGENTS}/ligolo-ng_agent_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz" -C "${LIGOLO_AGENTS}"
        if [[ -f "${LIGOLO_AGENTS}/agent" ]]; then
            mv -f "${LIGOLO_AGENTS}/agent" "${LIGOLO_AGENTS}/linux-agent"
            chmod +x "${LIGOLO_AGENTS}/linux-agent"
            ok "ligolo linux-agent -> ${LIGOLO_AGENTS/#$HOME/~}/linux-agent"
        else
            fail "ligolo linux-agent (extraction produced no 'agent' binary)"
        fi
    else
        fail "ligolo linux-agent (download failed)"
    fi
fi

# --- windows agent ---
if [[ -f "${LIGOLO_AGENTS}/windows-agent.exe" || -f "${LIGOLO_AGENTS}/windows-agent" ]]; then
    skip "ligolo windows-agent already present"
else
    info "downloading ligolo-ng windows agent..."
    if run curl -fsSL -o "${LIGOLO_AGENTS}/ligolo-ng_agent_${LIGOLO_VER}_windows_amd64.zip" \
        "${LIGOLO_BASE}/ligolo-ng_agent_${LIGOLO_VER}_windows_amd64.zip"; then
        run unzip -o -q "${LIGOLO_AGENTS}/ligolo-ng_agent_${LIGOLO_VER}_windows_amd64.zip" -d "${LIGOLO_AGENTS}"
        if [[ -f "${LIGOLO_AGENTS}/agent.exe" ]]; then
            mv -f "${LIGOLO_AGENTS}/agent.exe" "${LIGOLO_AGENTS}/windows-agent.exe"
            ok "ligolo windows-agent -> ${LIGOLO_AGENTS/#$HOME/~}/windows-agent.exe"
        else
            fail "ligolo windows-agent (extraction produced no 'agent.exe')"
        fi
    else
        fail "ligolo windows-agent (download failed)"
    fi
fi

# =================== 7. AD-Tools repo: exes / PS / CVEs ======================
step "Fetching executables, powershell-scripts, CVEs and OT-toolkit from AD-Tools"
if [[ -d "${ADTOOLS_CACHE}/.git" ]]; then
    info "updating AD-Tools repository..."
    run git -C "$ADTOOLS_CACHE" pull --ff-only || note "${YELLOW}pull failed, using cached copy${NC}"
else
    info "cloning ${ADTOOLS_REPO}..."
    rm -rf "$ADTOOLS_CACHE"
    run git clone --depth 1 --quiet "$ADTOOLS_REPO" "$ADTOOLS_CACHE" \
        || fail "AD-Tools repository clone"
fi

if [[ -d "$ADTOOLS_CACHE" ]]; then
    # OT-toolkit (ICS/SCADA attack scripts) lives in the same repo - copied
    # from this same clone rather than a second git clone of it.
    for pair in "executables:${EXECUTABLES}" "powershell-scripts:${PSSCRIPTS}" "CVEs:${CVES}" "OT-toolkit:${OT_TOOLKIT}"; do
        src="${ADTOOLS_CACHE}/${pair%%:*}"
        dst="${pair##*:}"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"
            cp -rf "${src}/." "${dst}/" 2>>"$LOG"
            find "$dst" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
            n=$(find "$dst" -type f ! -path '*/.git/*' | wc -l)
            ok "${dst/#$HOME/~}  (${n} files)"
        else
            fail "${pair%%:*} not found in AD-Tools repository"
        fi
    done
    # strip the exec bit from .ps1 files only - a recursive a-x would also
    # remove traversal (+x) from the directories and make them unreadable
    find "$PSSCRIPTS" -type f -exec chmod a-x {} + 2>/dev/null
else
    fail "AD-Tools content (repository unavailable)"
fi

# ==================== 8. PENTEST-TOOLS (general-purpose) =====================
step "Creating ${PENTEST_ROOT/#$HOME/~} (general-purpose, non-AD-specific tools)"
if [[ -d "$PENTEST_ROOT" ]]; then
    skip "${PENTEST_ROOT/#$HOME/~} already exists"
else
    mkdir -p "$PENTEST_ROOT" && ok "${PENTEST_ROOT/#$HOME/~}" || fail "mkdir ${PENTEST_ROOT}"
fi

for entry in "${PENTEST_PACKAGES[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
    if have "$bin"; then
        # apt already drops these in /usr/bin, which is on PATH for every
        # user - but symlink into /usr/local/bin too (same as the kerbrute
        # and ligolo-proxy binaries above) so the command is guaranteed to
        # resolve from anywhere, regardless of shell/PATH quirks.
        run $SUDO ln -sf "$(command -v "$bin")" "/usr/local/bin/${bin}"
        # and keep a symlink inside pentest-tools too, so the folder is a
        # browsable index of what got installed.
        ln -sf "$(command -v "$bin")" "${PENTEST_ROOT}/${bin}"
        note "available system-wide (/usr/local/bin/${bin}), linked at ${PENTEST_ROOT/#$HOME/~}/${bin}"
    fi
done

# --- runtime dependencies for PLCScan / ModbusPal / Wappalyzer below ---
for entry in "${PENTEST_DEPS[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
done

# --- tools with no apt package, cloned straight from upstream ---
for entry in "${PENTEST_GIT_TOOLS[@]}"; do
    IFS='|' read -r name url rel <<<"$entry"
    step "Installing ${name}"
    clone_tool "$name" "$url" "${PENTEST_ROOT}/${name}"
    surface_entrypoint_global "$name" "$rel"
done

# --- ModbusPal: Java GUI simulator, no apt package, upstream ships only a jar ---
step "Installing ModbusPal (Modbus/TCP simulator)"
MODBUSPAL_DIR="${PENTEST_ROOT}/modbuspal"
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
    ln -sf "${MODBUSPAL_DIR}/modbuspal" "${PENTEST_ROOT}/modbuspal"
    run $SUDO ln -sf "${MODBUSPAL_DIR}/modbuspal" "/usr/local/bin/modbuspal"
    note "modbuspal available system-wide (/usr/local/bin/modbuspal)"
fi

# --- Wappalyzer: upstream's own CLI/npm package is deprecated in favor of a
# paid API, so this uses the actively-maintained community Go CLI instead. ---
step "Installing Wappalyzer CLI"
if have wappalyzer; then
    skip "Wappalyzer CLI already installed ($(command -v wappalyzer))"
elif ! have go; then
    fail "Wappalyzer CLI (Go toolchain missing - see $LOG)"
else
    info "building wappalyzer-cli via go install..."
    if run env GOBIN="${PENTEST_ROOT}" go install github.com/gokulapap/wappalyzer-cli/cmd/wappy@latest \
        && [[ -f "${PENTEST_ROOT}/wappy" ]]; then
        mv -f "${PENTEST_ROOT}/wappy" "${PENTEST_ROOT}/wappalyzer"
        chmod +x "${PENTEST_ROOT}/wappalyzer"
        run $SUDO ln -sf "${PENTEST_ROOT}/wappalyzer" "/usr/local/bin/wappalyzer"
        ok "Wappalyzer CLI -> ${PENTEST_ROOT/#$HOME/~}/wappalyzer (also: wappalyzer)"
    else
        fail "Wappalyzer CLI (go install failed - see $LOG)"
    fi
fi

# --- Nuclei OT/ICS templates: not a separate apt package - pulled via nuclei's
# own official updater, which is also what fetches the ics/scada-tagged ones. ---
step "Updating Nuclei templates (incl. ics/scada tags)"
if ! have nuclei; then
    fail "Nuclei templates (nuclei binary missing, install failed above)"
elif run nuclei -update-templates; then
    ok "Nuclei templates updated"
else
    fail "Nuclei templates (update failed - see $LOG)"
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
        ln -sf "$BIN" "${PENTEST_ROOT}/pymodbus.simulator"
        ok "pymodbus.simulator installed (${BIN}), linked system-wide and at ${PENTEST_ROOT/#$HOME/~}"
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
        ln -sf "$(command -v modbus)" "${PENTEST_ROOT}/modbus"
        ok "modbus-cli installed ($(command -v modbus)), linked at ${PENTEST_ROOT/#$HOME/~}/modbus"
    else
        fail "modbus-cli (gem install failed - see $LOG)"
    fi
fi

# --- OT-toolkit: ICS/SCADA attack scripts fetched from AD-Tools in section 7
# above (same clone, no second git clone) - this just surfaces each one
# system-wide, same treatment as every other pentest-tools entry. ---
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
            ln -sf "${OT_TOOLKIT}/${script}" "${PENTEST_ROOT}/${script}"
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

group "Global commands (usable from anywhere)"
check_cmd impacket-secretsdump "impacket toolkit"
check_cmd netexec              "netexec"
check_cmd evil-winrm           "evil-winrm"
check_cmd certipy-ad           "certipy"
check_cmd bloodyad             "bloodyAD"
check_cmd bloodhound-python    "bloodhound-python"
check_cmd kerbrute             "kerbrute"
check_cmd ldapsearch           "ldapsearch"
check_cmd ligolo-proxy         "ligolo-proxy"

group "Tools  (${TOOLS/#$HOME/~})"
check_dir "${TOOLS}/GhostSPN/GhostSPN.py"                       "GhostSPN"
check_dir "${TOOLS}/GPOwned/GPOwned.py"                         "GPOwned"
check_dir "${TOOLS}/krbrelayx/krbrelayx.py"                     "krbrelayx"
check_dir "${TOOLS}/PetitPotam/PetitPotam.py"                   "PetitPotam"
check_dir "${TOOLS}/PKINITtools/gettgtpkinit.py"                "PKINITtools"
check_dir "${TOOLS}/pyGPOAbuse/pygpoabuse.py"                   "pyGPOAbuse"
check_dir "${TOOLS}/targetedKerberoast/targetedKerberoast.py"   "targetedKerberoast"
check_dir "${TOOLS}/PassTheCert/passthecert.py"                 "passthecert.py"
check_dir "${TOOLS}/pywhisker/pywhisker.py"                     "pywhisker.py"
check_dir "${TOOLS}/windapsearch/windapsearch.py"               "windapsearch.py"
check_dir "${TOOLS}/powerview.py/powerview"                     "powerview.py"
check_dir "${TOOLS}/kerbrute/kerbrute"                          "kerbrute binary"

group "Tunneling"
check_dir "${LIGOLO_PROXY}/proxy"                "ligolo proxy"
check_dir "${LIGOLO_AGENTS}/linux-agent"         "ligolo linux-agent"
check_dir "${LIGOLO_AGENTS}/windows-agent.exe"   "ligolo windows-agent"

group "Repository content"
check_dir "$EXECUTABLES"  "executables"
check_dir "$PSSCRIPTS"    "powershell-scripts"
check_dir "$CVES"         "CVEs"

group "Pentest-tools (${PENTEST_ROOT/#$HOME/~})"
check_cmd cyberchef        "CyberChef"
check_cmd flameshot        "Flameshot"
check_cmd hashcat          "hashcat"
check_cmd john             "John the Ripper"
check_cmd gobuster         "Gobuster"
check_cmd ffuf             "ffuf"
check_cmd msfconsole       "Metasploit"
check_cmd linpeas          "LinPEAS"
check_cmd whatweb          "WhatWeb"
check_cmd wireshark        "Wireshark"
check_cmd nmap             "Nmap"
check_cmd burpsuite        "Burp Suite"
check_cmd LinEnum.sh       "LinEnum"
check_cmd mbtget           "mbtget"
check_cmd plcscan.py       "PLCScan"
check_cmd modbuspal        "ModbusPal"
check_cmd wappalyzer       "Wappalyzer CLI"
check_cmd theHarvester     "theHarvester"
check_cmd recon-ng         "Recon-ng"
check_cmd shodan           "Shodan CLI"
check_cmd censys           "Censys CLI"
check_cmd nuclei           "Nuclei"
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
if have tree; then tree -L 2 "$AD_ROOT" -I '.AD-Tools' 2>/dev/null | head -40
else find "$AD_ROOT" -maxdepth 2 -not -path '*/.*' | sed "s|${HOME}|~|" | sort | head -40; fi
if have tree; then tree -L 2 "$PENTEST_ROOT" 2>/dev/null | head -40
else find "$PENTEST_ROOT" -maxdepth 2 -not -path '*/.*' | sed "s|${HOME}|~|" | sort | head -40; fi

box "$GREEN" "HTU Pentesting Toolkit finished installing," \
             "wish you a successful penetration testing."
