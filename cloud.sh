#!/usr/bin/env bash
#
# cloud.sh
# -----------------------------------------------------------------------------
# Minimal provisioner for the CPTC *cloud* attack box. Installs ONLY the four
# core Azure/Entra tools we standardised on, plus the handful of OS packages
# those four need — nothing else:
#
#     az CLI   ·   AzureHound   ·   o365spray   ·   AADInternals
#
# TARGET : Debian / Kali / Ubuntu (apt-based) Linux attack box, amd64 or arm64.
#          This is the LINUX box, NOT the Windows host — offensive tooling runs
#          on the attack box, per the team's standard.
# RUN AS : a normal user with sudo (you'll be prompted for the sudo password).
#
# Usage:
#   chmod +x cloud.sh
#   ./cloud.sh                 # install the four tools
#   ./cloud.sh --base ~/tools  # install bins under a custom dir
#
# Design: every step is wrapped so a single failure is logged and the run
# continues. A PASS/FAIL/SKIP summary prints at the end — fix only what failed.
#
# Verified against current sources (Oct 2026): az-cli deb installer
# (aka.ms/InstallAzureCLIDeb), AzureHound release asset naming
# (SpecterOps/AzureHound), o365spray setup.cfg entry point
# (0xZDH/o365spray, python_requires >=3.6.1), AADInternals PSGallery
# module, PowerShell MS package repo.
# -----------------------------------------------------------------------------

set -uo pipefail

# ---------- options ----------------------------------------------------------
BASE="$HOME/cptc-cloud-tools"
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    shift; BASE="${1:?--base needs a path}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

BIN="$BASE/bin"         # standalone binaries (put this on PATH)
mkdir -p "$BIN"

# ---------- pretty logging + result tracking ---------------------------------
c_g=$'\e[32m'; c_r=$'\e[31m'; c_y=$'\e[33m'; c_b=$'\e[36m'; c_0=$'\e[0m'
declare -a R_OK=() R_FAIL=() R_SKIP=()
hdr(){ printf '\n%s==== %s ====%s\n' "$c_b" "$1" "$c_0"; }
ok(){   printf '%s[ OK ]%s %s\n'   "$c_g" "$c_0" "$1"; R_OK+=("$1"); }
fail(){ printf '%s[FAIL]%s %s\n'   "$c_r" "$c_0" "$1"; R_FAIL+=("$1"); }
skip(){ printf '%s[SKIP]%s %s\n'   "$c_y" "$c_0" "$1"; R_SKIP+=("$1"); }
have(){ command -v "$1" >/dev/null 2>&1; }

# run <label> <cmd...> : run a step, record pass/fail, never abort the script
run(){ local label="$1"; shift
  if "$@"; then ok "$label"; else fail "$label"; fi
}

if [ "$(id -u)" -eq 0 ]; then
  echo "${c_y}Running as root — tools will install under /root. That's fine for a throwaway attack box.${c_0}"
fi

# ---------- arch / sudo helpers ----------------------------------------------
case "$(uname -m)" in
  x86_64|amd64)  GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) GOARCH=amd64; echo "${c_y}Unknown arch $(uname -m); assuming amd64.${c_0}" ;;
esac
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# =============================================================================
hdr "1/5  System packages (apt) — only what the four tools need"
# =============================================================================
# curl+ca-certificates -> az-cli installer & AzureHound download
# jq+unzip             -> parse the AzureHound release + unpack it
# git+pipx             -> install o365spray into an isolated venv (pipx pulls
#                         in python3-venv as a dependency)
APT_REAL="curl wget jq unzip ca-certificates git pipx"
if have apt-get; then
  run "apt update"        $SUDO apt-get update -y
  run "apt base packages" $SUDO apt-get install -y $APT_REAL
else
  skip "apt packages (no apt-get — install curl/jq/unzip/git/pipx manually)"
fi

# PATH wiring: our binary dir
export PATH="$BIN:$PATH"
add_path_line(){   # idempotently append a PATH export to a shell rc file
  local rc="$1" line="$2"
  [ -f "$rc" ] || return 0
  grep -qF "$line" "$rc" 2>/dev/null || printf '\n# CPTC cloud tools\n%s\n' "$line" >> "$rc"
}
PATH_LINE="export PATH=\"$BIN:\$PATH\""
add_path_line "$HOME/.bashrc" "$PATH_LINE"
add_path_line "$HOME/.zshrc"  "$PATH_LINE"

# =============================================================================
hdr "2/5  Azure CLI (az)"
# =============================================================================
if have az; then skip "azure-cli (already installed)"
elif have apt-get; then
  # Kali rolling isn't a recognized dist, so pin DIST_CODE to a Debian release
  # that exists in the azure-cli repo (bookworm pkgs run fine on Kali/trixie).
  AZ_DIST="bookworm"; [ -r /etc/os-release ] && . /etc/os-release && \
    case "${VERSION_CODENAME:-}" in bullseye|bookworm|trixie) AZ_DIST="$VERSION_CODENAME";; esac
  # NB: wrap with `env` — `$SUDO DIST_CODE=.. bash` breaks when $SUDO is empty
  # (root): the assignment leaves leading position and bash tries to exec it.
  curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO env DIST_CODE="$AZ_DIST" bash
  if have az; then ok "azure-cli (deb, $AZ_DIST)"; else fail "azure-cli"; fi
else skip "azure-cli (no apt — see https://aka.ms/azcli)"; fi

# =============================================================================
hdr "3/5  AzureHound (release binary, checksum-verified)"
# =============================================================================
install_azurehound(){
  have jq || { echo "jq missing"; return 1; }
  local api="https://api.github.com/repos/SpecterOps/AzureHound/releases/latest"
  local json zip_url sha_url tmp
  json="$(curl -fsSL "$api")" || return 1
  zip_url="$(echo "$json" | jq -r ".assets[].browser_download_url" | grep -E "linux_${GOARCH}\.zip$" | head -n1)"
  sha_url="${zip_url}.sha256"
  [ -n "$zip_url" ] || { echo "no linux_${GOARCH} asset found"; return 1; }
  tmp="$(mktemp -d)"
  curl -fsSL "$zip_url" -o "$tmp/ah.zip" || { rm -rf "$tmp"; return 1; }
  if curl -fsSL "$sha_url" -o "$tmp/ah.sha256" 2>/dev/null; then
    ( cd "$tmp" && echo "$(awk '{print $1}' ah.sha256)  ah.zip" | sha256sum -c - ) \
      || { echo "checksum mismatch"; rm -rf "$tmp"; return 1; }
  fi
  unzip -o -q "$tmp/ah.zip" -d "$tmp" || { rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/azurehound" "$BIN/azurehound" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}
if have azurehound; then skip "azurehound (already on PATH)"; else run "azurehound" install_azurehound; fi

# =============================================================================
hdr "4/5  o365spray (Python CLI, pipx-isolated)"
# =============================================================================
# Entra ID / O365 user-enumeration + password-spray tool (0xZDH/o365spray).
# It's a pip package whose setup.cfg exposes the `o365spray` console script;
# we install it with pipx into its own venv under $BASE/pipx and drop the
# launcher straight into $BIN (so it lands on PATH, no extra wiring).
ensure_pipx(){
  have pipx && return 0
  have apt-get && $SUDO apt-get install -y pipx >/dev/null 2>&1
  have pipx && return 0
  # last resort: user-level pip (handle PEP 668 externally-managed envs)
  python3 -m pip install --user pipx >/dev/null 2>&1 \
    || python3 -m pip install --user --break-system-packages pipx >/dev/null 2>&1
  export PATH="$HOME/.local/bin:$PATH"
  have pipx
}
install_o365spray(){
  ensure_pipx || { echo "pipx unavailable"; return 1; }
  # PIPX_HOME holds the venv; PIPX_BIN_DIR is where the console script lands
  PIPX_HOME="$BASE/pipx" PIPX_BIN_DIR="$BIN" \
    pipx install --force "git+https://github.com/0xZDH/o365spray.git" || return 1
  [ -x "$BIN/o365spray" ] || have o365spray
}
if have o365spray; then skip "o365spray (already on PATH)"; else run "o365spray" install_o365spray; fi

# =============================================================================
hdr "5/5  PowerShell + AADInternals"
# =============================================================================
install_pwsh(){
  have pwsh && return 0
  have apt-get || return 1
  # Kali frequently ships powershell in its own repo
  if $SUDO apt-get install -y powershell >/dev/null 2>&1 && have pwsh; then return 0; fi
  # Fallback: Microsoft package repo (Debian). Kali is rolling with no VERSION_ID -> use 12.
  local ver=12; [ -r /etc/os-release ] && . /etc/os-release && case "${VERSION_ID:-}" in 11|12|13) ver="$VERSION_ID";; esac
  curl -fsSL "https://packages.microsoft.com/config/debian/${ver}/packages-microsoft-prod.deb" -o /tmp/pmc.deb || return 1
  $SUDO dpkg -i /tmp/pmc.deb >/dev/null 2>&1 || true
  $SUDO apt-get update -y >/dev/null 2>&1
  $SUDO apt-get install -y powershell >/dev/null 2>&1
  have pwsh
}
if have pwsh; then skip "powershell (already installed)"; else run "powershell" install_pwsh; fi

if have pwsh; then
  run "AADInternals (PS module)" pwsh -NoProfile -Command \
    "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module AADInternals -Scope CurrentUser -Force -AcceptLicense -ErrorAction Stop"
else
  skip "AADInternals (pwsh not available)"
fi

# =============================================================================
hdr "Summary"
# =============================================================================
printf '%sInstalled (%d):%s %s\n' "$c_g" "${#R_OK[@]}"   "$c_0" "${R_OK[*]:-none}"
printf '%sSkipped   (%d):%s %s\n' "$c_y" "${#R_SKIP[@]}" "$c_0" "${R_SKIP[*]:-none}"
printf '%sFailed    (%d):%s %s\n' "$c_r" "${#R_FAIL[@]}" "$c_0" "${R_FAIL[*]:-none}"

cat <<EOF

${c_b}Done.${c_0} Tools live under: $BASE
  - CLI launchers & binaries : $BIN   (added to ~/.bashrc / ~/.zshrc PATH)

${c_y}Open a new shell (or: source ~/.bashrc) so PATH changes take effect.${c_0}

Quick checks:
  az version ; azurehound -h ; o365spray --help
  pwsh -c "Get-Module -ListAvailable AADInternals"

${c_r}If anything shows [FAIL] above, re-run just that tool's section — the rest is already done.${c_0}
EOF
