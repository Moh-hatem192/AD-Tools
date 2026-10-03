#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${SCRIPT_DIR}/lib/install-common.sh"

MOBILE_PACKAGES=(
    "apktool|apktool|Apktool"
    "jadx|jadx-gui|JADX (jadx-gui)"
    "dex2jar|d2j-dex2jar|dex2jar"
    "apksigner|apksigner|apksigner"
    "ghidra|ghidra|Ghidra"
)

start_category "Mobile/Android" "$MOBILE_ROOT" "$((1 + 1 + ${#MOBILE_PACKAGES[@]} + 1))"
system_prep curl wget unzip tar python3 python3-pip python3-dev pipx default-jre tree

step "Creating ${MOBILE_ROOT/#$HOME/~}"
if [[ -d "$MOBILE_ROOT" ]]; then skip "${MOBILE_ROOT/#$HOME/~} already exists"; else mkdir -p "$MOBILE_ROOT" && ok "${MOBILE_ROOT/#$HOME/~}" || fail "mkdir ${MOBILE_ROOT}"; fi

for entry in "${MOBILE_PACKAGES[@]}"; do
    IFS='|' read -r pkg bin name <<<"$entry"
    step "Installing ${name}"
    apt_pkg "$pkg" "$bin" "$name"
    link_command "$bin" "$MOBILE_ROOT"
done

step "Installing Frida (frida-tools)"
if have frida; then
    skip "frida already installed ($(command -v frida))"
else
    info "installing frida-tools via pipx..."
    if run pipx install --force frida-tools && have frida; then ok "frida installed ($(command -v frida))"; note "push a matching frida-server to the device/emulator before dynamic work"; else fail "frida (pipx install failed - see $LOG)"; fi
fi
link_command frida "$MOBILE_ROOT"

box "$YELLOW" "QUICK CHECK - verifying mobile/Android tools"
group "Mobile commands"
for check in "apktool:Apktool" "jadx-gui:JADX (jadx-gui)" "d2j-dex2jar:dex2jar" "apksigner:apksigner" "ghidra:Ghidra" "frida:Frida"; do
    check_global "${check%%:*}" "${check#*:}"
done
finish_category
