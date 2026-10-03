#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${SCRIPT_DIR}/lib/install-common.sh"

WEB_PACKAGES=(
    "cyberchef|cyberchef|CyberChef"
    "gobuster|gobuster|Gobuster"
    "ffuf|ffuf|ffuf"
    "feroxbuster|feroxbuster|feroxbuster"
    "whatweb|whatweb|WhatWeb"
    "burpsuite|burpsuite|Burp Suite"
    "nuclei|nuclei|Nuclei"
    "wpscan|wpscan|WPScan (WordPress)"
    "joomscan|joomscan|JoomScan (Joomla)"
)

start_category "Web" "$PENTEST_ROOT" "$((1 + 1 + ${#WEB_PACKAGES[@]} + 5))" "web-install.log"
system_prep git curl wget unzip tar build-essential python3 python3-pip python3-dev pipx golang-go libssl-dev libffi-dev tree

step "Creating ${PENTEST_ROOT/#$HOME/~}"
if [[ -d "$PENTEST_ROOT" ]]; then skip "${PENTEST_ROOT/#$HOME/~} already exists"; else mkdir -p "$PENTEST_ROOT" && ok "${PENTEST_ROOT/#$HOME/~}" || fail "mkdir ${PENTEST_ROOT}"; fi

for entry in "${WEB_PACKAGES[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
    link_command "$bin" "$PENTEST_ROOT"
done

step "Installing jwt_tool"
clone_tool "jwt_tool" "https://github.com/ticarpi/jwt_tool" "${PENTEST_ROOT}/jwt_tool"
surface_entrypoint_global "$PENTEST_ROOT" "jwt_tool" "jwt_tool.py"

step "Installing Wappalyzer CLI"
if have wappalyzer; then
    skip "Wappalyzer CLI already installed ($(command -v wappalyzer))"
elif ! have go; then
    fail "Wappalyzer CLI (Go toolchain missing - see $LOG)"
else
    info "building wappalyzer-cli via go install..."
    if run env GOBIN="${PENTEST_ROOT}" go install github.com/gokulapap/wappalyzer-cli/cmd/wappy@latest && [[ -f "${PENTEST_ROOT}/wappy" ]]; then
        mv -f "${PENTEST_ROOT}/wappy" "${PENTEST_ROOT}/wappalyzer"; chmod +x "${PENTEST_ROOT}/wappalyzer"
        ok "Wappalyzer CLI -> ${PENTEST_ROOT/#$HOME/~}/wappalyzer"
    else fail "Wappalyzer CLI (go install failed - see $LOG)"; fi
fi
link_command wappalyzer "$PENTEST_ROOT"

step "Installing droopescan (Drupal/CMS scanner)"
if have droopescan; then skip "droopescan already installed ($(command -v droopescan))"; else
    info "installing droopescan via pipx..."
    if run pipx install --force droopescan && have droopescan; then ok "droopescan installed ($(command -v droopescan))"; else fail "droopescan (pipx install failed - see $LOG)"; fi
fi
link_command droopescan "$PENTEST_ROOT"

step "Installing SecLists wordlist arsenal"
SECLISTS_DIR="/usr/share/seclists"
if [[ -d "$SECLISTS_DIR" && -n "$(ls -A "$SECLISTS_DIR" 2>/dev/null)" ]]; then
    skip "SecLists already present -> ${SECLISTS_DIR}"; ln -sf "$SECLISTS_DIR" "${PENTEST_ROOT}/seclists"
else
    info "installing seclists via apt (pulls a few hundred MB, be patient)..."
    if run $SUDO apt-get install "${APT_OPTS[@]}" seclists && [[ -d "$SECLISTS_DIR" ]]; then ln -sf "$SECLISTS_DIR" "${PENTEST_ROOT}/seclists"; ok "SecLists -> ${SECLISTS_DIR} (linked at ${PENTEST_ROOT/#$HOME/~}/seclists)"; else fail "SecLists (apt install 'seclists' failed - see $LOG)"; fi
fi

step "Updating Nuclei templates (including ics/scada tags)"
if ! have nuclei; then fail "Nuclei templates (nuclei binary missing, install failed above)"; elif run nuclei -update-templates; then ok "Nuclei templates updated"; else fail "Nuclei templates (update failed - see $LOG)"; fi

box "$YELLOW" "QUICK CHECK - verifying web pentesting tools"
group "Web pentesting commands"
for check in "cyberchef:CyberChef" "gobuster:Gobuster" "ffuf:ffuf" "feroxbuster:feroxbuster" "whatweb:WhatWeb" "burpsuite:Burp Suite" "nuclei:Nuclei" "wpscan:WPScan" "joomscan:JoomScan" "jwt_tool.py:jwt_tool" "wappalyzer:Wappalyzer CLI" "droopescan:droopescan"; do
    check_global "${check%%:*}" "${check#*:}"
done
check_path "$SECLISTS_DIR" "SecLists"
finish_category
