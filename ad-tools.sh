#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${SCRIPT_DIR}/lib/install-common.sh"

LIGOLO_VER="0.9.1"
KERBRUTE_VER="v1.0.3"
case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64)  LIGOLO_ARCH="amd64"; KERBRUTE_ARCH="amd64" ;;
    arm64|aarch64) LIGOLO_ARCH="arm64"; KERBRUTE_ARCH="" ;;
    armhf|armv7l)  LIGOLO_ARCH="armv7"; KERBRUTE_ARCH="" ;;
    i386|i686)     LIGOLO_ARCH="386";   KERBRUTE_ARCH="386" ;;
    *)             LIGOLO_ARCH="amd64"; KERBRUTE_ARCH="amd64" ;;
esac

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
PACKAGES=(
    "python3-impacket|impacket-secretsdump|impacket|impacket toolkit"
    "netexec|nxc|git+https://github.com/Pennyw0rth/NetExec|nxc (NetExec)"
    "evil-winrm|evil-winrm|gem:evil-winrm|evil-winrm"
    "certipy-ad|certipy-ad|certipy-ad|certipy"
    "bloodyad|bloodyAD|bloodyAD|bloodyAD"
    "bloodhound.py|bloodhound-python|bloodhound-ce|bloodhound-python"
    "ldap-utils|ldapsearch|-|ldapsearch (ldap-utils)"
)

start_category "Active Directory" "$AD_ROOT" "$((1 + 1 + ${#PACKAGES[@]} + ${#GIT_TOOLS[@]} + 3))"
system_prep git curl wget unzip tar 7zip build-essential python3 python3-pip python3-dev pipx libssl-dev libffi-dev libldap2-dev libsasl2-dev ldap-utils krb5-user rlwrap tree ruby ruby-dev

step "Creating Active Directory directory structure"
for directory in "$TOOLS" "$EXECUTABLES" "$PSSCRIPTS" "$CVES" "$LIGOLO_AGENTS" "$LIGOLO_PROXY"; do
    if [[ -d "$directory" ]]; then skip "${directory/#$HOME/~} already exists"; else mkdir -p "$directory" && ok "${directory/#$HOME/~}" || fail "mkdir ${directory}"; fi
done

for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg bin spec name <<<"$entry"
    step "Installing ${name} (system-wide)"
    case "$spec" in
        gem:*) apt_then_gem "$pkg" "$bin" "${spec#gem:}" "$name" ;;
        -) apt_pkg "$pkg" "$bin" "$name" ;;
        *) apt_then_pipx "$pkg" "$bin" "$spec" "$name" ;;
    esac
done

# These are the only AD commands intentionally surfaced in /usr/local/bin.
# Other package-provided companion commands remain under package-manager
# control; the installer does not add global aliases for them.
link_global_alias "nxc" "nxc"
link_global_alias "bloodhound-python" "bloodhound-python"
link_global_alias "bloodyad" "bloodyAD"
link_global_alias "certipy-ad" "certipy-ad"

for entry in "${GIT_TOOLS[@]}"; do
    IFS='|' read -r name url <<<"$entry"
    step "Installing ${name}"
    clone_tool "$name" "$url" "${TOOLS}/${name}"
    case "$name" in
        PassTheCert) surface_entrypoint "$TOOLS" "$name" "Python/passthecert.py" ldap3 pyasn1 pycryptodome ;;
        pywhisker) surface_entrypoint "$TOOLS" "$name" "pywhisker/pywhisker.py" ldap3 pyasn1 pycryptodome rich ;;
        powerview.py) surface_python_global "powerview.py" "${TOOLS}/powerview.py" "powerview.py" ;;
    esac
done

step "Installing kerbrute"
if [[ -z "$KERBRUTE_ARCH" ]]; then
    fail "kerbrute (upstream ships no Linux binary for this architecture; build from source with: go install github.com/ropnop/kerbrute@latest)"
elif have kerbrute; then
    skip "kerbrute already installed ($(command -v kerbrute))"
else
    info "downloading kerbrute ${KERBRUTE_VER} (linux/${KERBRUTE_ARCH})..."
    mkdir -p "${TOOLS}/kerbrute"
    if run curl -fsSL -o "${TOOLS}/kerbrute/kerbrute" "https://github.com/ropnop/kerbrute/releases/download/${KERBRUTE_VER}/kerbrute_linux_${KERBRUTE_ARCH}"; then
        chmod +x "${TOOLS}/kerbrute/kerbrute"
        run $SUDO ln -sf "${TOOLS}/kerbrute/kerbrute" /usr/local/bin/kerbrute
        run curl -fsSL -o "${TOOLS}/kerbrute/kerbrute.exe" "https://github.com/ropnop/kerbrute/releases/download/${KERBRUTE_VER}/kerbrute_windows_amd64.exe"
        have kerbrute && ok "kerbrute installed (/usr/local/bin/kerbrute)" || fail "kerbrute (symlink to /usr/local/bin failed)"
    else
        fail "kerbrute (download failed)"
    fi
fi
link_global_alias "kerbrute" "kerbrute"

step "Installing ligolo-ng ${LIGOLO_VER} (proxy + agents)"
LIGOLO_BASE="https://github.com/nicocha30/ligolo-ng/releases/download/v${LIGOLO_VER}"
if [[ -x "${LIGOLO_PROXY}/proxy" ]]; then skip "ligolo proxy already present -> ${LIGOLO_PROXY/#$HOME/~}/proxy"; else
    info "downloading ligolo-ng proxy..."
    archive="${LIGOLO_PROXY}/ligolo-ng_proxy_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz"
    if run curl -fsSL -o "$archive" "${LIGOLO_BASE}/ligolo-ng_proxy_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz" && run tar -xzf "$archive" -C "$LIGOLO_PROXY" && [[ -f "${LIGOLO_PROXY}/proxy" ]]; then
        chmod +x "${LIGOLO_PROXY}/proxy"; ok "ligolo proxy -> ${LIGOLO_PROXY/#$HOME/~}/proxy"
    else fail "ligolo proxy (download or extraction failed)"; fi
fi

# Older versions of this installer created this global link. Remove only that
# installer-managed link so Ligolo remains local to the AD/tunneling tree.
if [[ -L /usr/local/bin/ligolo-proxy && "$(readlink -f /usr/local/bin/ligolo-proxy)" == "${LIGOLO_PROXY}/proxy" ]]; then
    run $SUDO unlink /usr/local/bin/ligolo-proxy
fi
if [[ -x "${LIGOLO_AGENTS}/linux-agent" ]]; then skip "ligolo linux-agent already present"; else
    info "downloading ligolo-ng linux agent..."
    archive="${LIGOLO_AGENTS}/ligolo-ng_agent_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz"
    if run curl -fsSL -o "$archive" "${LIGOLO_BASE}/ligolo-ng_agent_${LIGOLO_VER}_linux_${LIGOLO_ARCH}.tar.gz" && run tar -xzf "$archive" -C "$LIGOLO_AGENTS" && [[ -f "${LIGOLO_AGENTS}/agent" ]]; then
        mv -f "${LIGOLO_AGENTS}/agent" "${LIGOLO_AGENTS}/linux-agent"; chmod +x "${LIGOLO_AGENTS}/linux-agent"; ok "ligolo linux-agent -> ${LIGOLO_AGENTS/#$HOME/~}/linux-agent"
    else fail "ligolo linux-agent (download or extraction failed)"; fi
fi
if [[ -f "${LIGOLO_AGENTS}/windows-agent.exe" ]]; then skip "ligolo windows-agent already present"; else
    info "downloading ligolo-ng windows agent..."
    archive="${LIGOLO_AGENTS}/ligolo-ng_agent_${LIGOLO_VER}_windows_amd64.zip"
    if run curl -fsSL -o "$archive" "${LIGOLO_BASE}/ligolo-ng_agent_${LIGOLO_VER}_windows_amd64.zip" && run unzip -o -q "$archive" -d "$LIGOLO_AGENTS" && [[ -f "${LIGOLO_AGENTS}/agent.exe" ]]; then
        mv -f "${LIGOLO_AGENTS}/agent.exe" "${LIGOLO_AGENTS}/windows-agent.exe"; ok "ligolo windows-agent -> ${LIGOLO_AGENTS/#$HOME/~}/windows-agent.exe"
    else fail "ligolo windows-agent (download or extraction failed)"; fi
fi

step "Fetching executables, powershell-scripts and CVEs from AD-Tools"
fetch_adtools_cache
if [[ -d "$ADTOOLS_CACHE" ]]; then
    for pair in "executables:${EXECUTABLES}" "powershell-scripts:${PSSCRIPTS}" "CVEs:${CVES}"; do
        src="${ADTOOLS_CACHE}/${pair%%:*}"; dst="${pair##*:}"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"; cp -rf "${src}/." "${dst}/" 2>>"$LOG"; find "$dst" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
            count="$(find "$dst" -type f ! -path '*/.git/*' | wc -l)"; ok "${dst/#$HOME/~} (${count} files)"
        else fail "${pair%%:*} not found in AD-Tools repository"; fi
    done
    find "$PSSCRIPTS" -type f -exec chmod a-x {} + 2>/dev/null
else fail "AD-Tools content (repository unavailable)"; fi

box "$YELLOW" "QUICK CHECK - verifying Active Directory tools"
group "Approved global AD commands"
for check in "nxc:nxc" "bloodhound-python:bloodhound-python" "powerview.py:powerview.py" "bloodyad:bloodyad" "kerbrute:kerbrute" "certipy-ad:certipy-ad"; do check_global "${check%%:*}" "${check#*:}"; done
group "Git tools"
check_path "${TOOLS}/GhostSPN/GhostSPN.py" "GhostSPN"
check_path "${TOOLS}/GPOwned/GPOwned.py" "GPOwned"
check_path "${TOOLS}/krbrelayx/krbrelayx.py" "krbrelayx"
check_path "${TOOLS}/PetitPotam/PetitPotam.py" "PetitPotam"
check_path "${TOOLS}/PKINITtools/gettgtpkinit.py" "PKINITtools"
check_path "${TOOLS}/pyGPOAbuse/pygpoabuse.py" "pyGPOAbuse"
check_path "${TOOLS}/targetedKerberoast/targetedKerberoast.py" "targetedKerberoast"
check_path "${TOOLS}/PassTheCert/passthecert.py" "passthecert.py"
check_path "${TOOLS}/pywhisker/pywhisker.py" "pywhisker.py"
check_path "${TOOLS}/windapsearch/windapsearch.py" "windapsearch.py"
check_path "${TOOLS}/powerview.py/powerview" "powerview.py"
group "Tunneling and repository content"
check_path "${LIGOLO_PROXY}/proxy" "ligolo proxy (local)"
check_path "${LIGOLO_AGENTS}/linux-agent" "ligolo linux-agent"
check_path "${LIGOLO_AGENTS}/windows-agent.exe" "ligolo windows-agent"
check_path "$EXECUTABLES" "executables"
check_path "$PSSCRIPTS" "powershell-scripts"
check_path "$CVES" "CVEs"
finish_category
