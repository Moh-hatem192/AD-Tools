#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Run every category in the same overall order as the original installer.
# Each category keeps its own log and verification summary.
for installer in ad-tools.sh general-pentesting-tools.sh web-tools.sh OT-tools.sh mobile-tools.sh; do
    printf '\n\033[1;36m==> Running %s\033[0m\n' "$installer"
    "${SCRIPT_DIR}/${installer}"
done
