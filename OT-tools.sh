#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${SCRIPT_DIR}/lib/install-common.sh"

OT_GIT_TOOLS=(
    "mbtget|https://github.com/sourceperl/mbtget|scripts/mbtget"
    "plcscan|https://github.com/meeas/plcscan|plcscan.py"
)

start_category "OT/ICS/SCADA" "$OT_ROOT" "$((1 + 1 + ${#OT_GIT_TOOLS[@]} + 4))"
system_prep git curl wget unzip tar build-essential python3 python3-pip python3-dev pipx python2 default-jre ruby ruby-dev tree

step "Creating ${OT_ROOT/#$HOME/~}"
if [[ -d "$OT_ROOT" ]]; then skip "${OT_ROOT/#$HOME/~} already exists"; else mkdir -p "$OT_ROOT" && ok "${OT_ROOT/#$HOME/~}" || fail "mkdir ${OT_ROOT}"; fi

for entry in "${OT_GIT_TOOLS[@]}"; do
    IFS='|' read -r name url rel <<<"$entry"
    step "Installing ${name}"
    clone_tool "$name" "$url" "${OT_ROOT}/${name}"
    surface_entrypoint_global "$OT_ROOT" "$name" "$rel"
done

step "Installing ModbusPal (Modbus/TCP simulator)"
MODBUSPAL_DIR="${OT_ROOT}/modbuspal"
mkdir -p "$MODBUSPAL_DIR"
if [[ -f "${MODBUSPAL_DIR}/ModbusPal.jar" ]]; then
    skip "ModbusPal already present -> ${MODBUSPAL_DIR/#$HOME/~}/ModbusPal.jar"
else
    info "downloading ModbusPal.jar (official SourceForge release)..."
    if run curl -fsSL -o "${MODBUSPAL_DIR}/ModbusPal.jar" "https://sourceforge.net/projects/modbuspal/files/modbuspal/RC%20version%201.6b/ModbusPal.jar/download"; then ok "ModbusPal.jar -> ${MODBUSPAL_DIR/#$HOME/~}/ModbusPal.jar"; else fail "ModbusPal (download failed)"; fi
fi
if [[ -f "${MODBUSPAL_DIR}/ModbusPal.jar" ]]; then
    printf '#!/usr/bin/env bash\nexec java -jar "%s/ModbusPal.jar" "$@"\n' "$MODBUSPAL_DIR" >"${MODBUSPAL_DIR}/modbuspal"
    chmod +x "${MODBUSPAL_DIR}/modbuspal"
    run $SUDO ln -sf "${MODBUSPAL_DIR}/modbuspal" /usr/local/bin/modbuspal
    note "modbuspal available system-wide (/usr/local/bin/modbuspal)"
fi

step "Installing pymodbus (pymodbus.simulator)"
if have pymodbus.simulator; then skip "pymodbus.simulator already installed ($(command -v pymodbus.simulator))"; else
    info "installing pymodbus via pip..."
    if run pip3 install --break-system-packages --no-input -q pymodbus && have pymodbus.simulator; then
        bin_path="$(command -v pymodbus.simulator)"; ok "pymodbus.simulator installed (${bin_path})"
    else fail "pymodbus (pip install failed - see $LOG)"; fi
fi
link_command pymodbus.simulator "$OT_ROOT"

step "Installing modbus-cli (Ruby gem)"
if have modbus; then skip "modbus-cli already installed ($(command -v modbus))"; else
    info "installing modbus-cli via gem..."
    run $SUDO apt-get install "${APT_OPTS[@]}" ruby ruby-dev
    if run $SUDO gem install --no-document modbus-cli && have modbus; then ok "modbus-cli installed ($(command -v modbus))"; else fail "modbus-cli (gem install failed - see $LOG)"; fi
fi
link_command modbus "$OT_ROOT"

step "Fetching and surfacing OT-toolkit scripts from AD-Tools"
fetch_adtools_cache
source_dir="${ADTOOLS_CACHE}/OT-toolkit"
if [[ -d "$source_dir" ]]; then
    mkdir -p "$OT_TOOLKIT"; cp -rf "${source_dir}/." "${OT_TOOLKIT}/" 2>>"$LOG"
    find "$OT_TOOLKIT" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
    missing_ot=0
    for script in attack_pump.py device_fingerprint.py recon_sweep.py sensor_spoof.py unit_id_scanner.py; do
        if [[ -f "${OT_TOOLKIT}/${script}" ]]; then chmod +x "${OT_TOOLKIT}/${script}"; run $SUDO ln -sf "${OT_TOOLKIT}/${script}" "/usr/local/bin/${script}"; ln -sf "${OT_TOOLKIT}/${script}" "${OT_ROOT}/${script}"; else fail "${script} (missing from OT-toolkit)"; missing_ot=1; fi
    done
    (( missing_ot == 0 )) && ok "OT-toolkit scripts available system-wide"
else fail "OT-toolkit not found in AD-Tools repository"; fi

box "$YELLOW" "QUICK CHECK - verifying OT/ICS/SCADA tools"
group "OT commands"
for check in "mbtget:mbtget" "plcscan.py:PLCScan" "modbuspal:ModbusPal" "pymodbus.simulator:pymodbus" "modbus:modbus-cli" "attack_pump.py:OT attack_pump" "device_fingerprint.py:OT device_fingerprint" "recon_sweep.py:OT recon_sweep" "sensor_spoof.py:OT sensor_spoof" "unit_id_scanner.py:OT unit_id_scanner"; do
    check_global "${check%%:*}" "${check#*:}"
done
finish_category
