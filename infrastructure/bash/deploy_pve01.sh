#!/usr/bin/env bash
# =========================================================
# Despliegue de pve01 (Proxmox VE, instalación desatendida)
# =========================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/iso.sh"

ANSWER_TEMPLATE="${CONFIGS_DIR}/proxmox/answer.toml.template"
WORK_DIR="${PROJECT_ROOT}/artifacts/proxmox-auto"
ASSISTANT_BIN="${PROXMOX_ASSISTANT_DIR}/usr/bin/proxmox-auto-install-assistant"
INSTALL_TIMEOUT=3600

shopt -u patsub_replacement 2>/dev/null || true

# ---------------------------------------------------------
# Descarga y verifica proxmox-auto-install-assistant
# ---------------------------------------------------------
get_assistant() {
    if [[ -x "$ASSISTANT_BIN" ]]; then
        return 0
    fi

    local deb="${PROXMOX_ASSISTANT_DIR}/proxmox-auto-install-assistant_${PROXMOX_ASSISTANT_VERSION}_amd64.deb"
    mkdir -p "$PROXMOX_ASSISTANT_DIR"

    log_info "Descargando proxmox-auto-install-assistant ${PROXMOX_ASSISTANT_VERSION}"
    curl -fL --retry 3 -o "$deb" "$PROXMOX_ASSISTANT_URL"

    if ! echo "${PROXMOX_ASSISTANT_SHA256}  ${deb}" | sha256sum -c --quiet -; then
        log_err "La suma SHA256 del paquete no coincide."
        rm -f "$deb"
        return 1
    fi

    dpkg-deb -x "$deb" "$PROXMOX_ASSISTANT_DIR"
    rm -f "$deb"
    log_ok "Herramienta preparada"
}

# ---------------------------------------------------------
# Genera answer.toml a partir de la plantilla
# ---------------------------------------------------------
generate_answer() {
    local out="$1" hash content mac_lower

    hash="$(openssl passwd -6 "$(openssl rand -base64 24)")"
    mac_lower="$(echo "$PVE_MAC" | tr 'A-F' 'a-f')"

    content="$(<"$ANSWER_TEMPLATE")"
    content="${content//@@FQDN@@/${PVE_NAME}.vcorp.local}"
    content="${content//@@ROOT_PASSWORD_HASH@@/$hash}"
    content="${content//@@AUDITOR_KEY@@/$(<"$AUDIT_PUB_KEY_FILE")}"
    content="${content//@@SYSADMIN_KEY@@/$(<"$SYSADMIN_PUB_KEY_FILE")}"
    content="${content//@@IP_CIDR@@/$PVE_IP}"
    content="${content//@@GATEWAY@@/$PVE_GATEWAY}"
    content="${content//@@DNS@@/$PVE_DNS}"
    content="${content//@@MAC@@/$mac_lower}"

    printf '%s\n' "$content" > "$out"
    chmod 600 "$out"
}

# ---------------------------------------------------------
# Espera que la VM se apague
# ---------------------------
# ---------------------------------------------------------
wait_poweroff() {
    local name="$1" timeout="$2" elapsed=0 state

    while (( elapsed < timeout )); do
        state="$("$VBOXMANAGE_BIN" showvminfo "$name" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
        [[ "$state" == "poweroff" ]] && return 0
        sleep 10
        elapsed=$((elapsed + 10))
        (( elapsed % 120 == 0 )) && log_info "Instalando '$name'... ($((elapsed / 60)) min)"
    done

    log_err "Timeout: '$name' no se ha apagado en $((timeout / 60)) minutos."
    return 1
}

# =========================================================
# Ejecución
# =========================================================

if "$VBOXMANAGE_BIN" showvminfo "$PVE_NAME" >/dev/null 2>&1; then
    log_warn "La máquina '$PVE_NAME' ya existe. Se omite."
    exit 0
fi

log_info "=========================================="
log_info "Desplegando $PVE_NAME (Proxmox VE ${PROXMOX_VERSION})"
log_info "=========================================="

download_iso "$PROXMOX_ISO_URL" "$PROXMOX_ISO_PATH" "$PROXMOX_SHA256SUMS_URL"
get_assistant

mkdir -p "$WORK_DIR"
ANSWER_FILE="${WORK_DIR}/answer.toml"
AUTO_ISO="${WORK_DIR}/${PVE_NAME}-auto.iso"

generate_answer "$ANSWER_FILE"

log_info "Validando answer.toml"
"$ASSISTANT_BIN" validate-answer "$ANSWER_FILE"

log_info "Preparando la ISO de instalación automática"
rm -f "$AUTO_ISO"
"$ASSISTANT_BIN" prepare-iso "$PROXMOX_ISO_PATH" \
    --fetch-from iso \
    --answer-file "$ANSWER_FILE" \
    --output "$AUTO_ISO"

# ---------------------------------------------------------
# Crear la VM
# ---------------------------------------------------------
"$VBOXMANAGE_BIN" createvm --name "$PVE_NAME" --ostype Debian_64 \
    --groups "$VM_EQUIPMENT_GROUP" --register

"$VBOXMANAGE_BIN" modifyvm "$PVE_NAME" \
    --memory "$PVE_MEMORY" --cpus "$PVE_CPUS" \
    --nested-hw-virt on \
    --nic1 intnet --intnet1 "$PVE_NETWORK" --macaddress1 "$PVE_MAC" \
    --cableconnected1 on \
    --graphicscontroller vmsvga --vram 32 \
    --audio-enabled off \
    --rtc-use-utc on \
    --boot1 dvd --boot2 disk --boot3 none --boot4 none

VM_DIR="$(dirname "$("$VBOXMANAGE_BIN" showvminfo "$PVE_NAME" --machinereadable | grep '^CfgFile=' | cut -d'"' -f2)")"

"$VBOXMANAGE_BIN" createmedium disk --filename "$VM_DIR/$PVE_NAME.vdi" \
    --size "$PVE_DISK_MB" --format VDI --variant Standard

"$VBOXMANAGE_BIN" storagectl "$PVE_NAME" --name SATA --add sata \
    --controller IntelAhci --portcount 2 --bootable on

"$VBOXMANAGE_BIN" storageattach "$PVE_NAME" --storagectl SATA \
    --port 0 --device 0 --type hdd --medium "$VM_DIR/$PVE_NAME.vdi"

"$VBOXMANAGE_BIN" storageattach "$PVE_NAME" --storagectl SATA \
    --port 1 --device 0 --type dvddrive --medium "$AUTO_ISO"

# ---------------------------------------------------------
# Instalación
# ---------------------------------------------------------
log_info "Iniciando la instalación desatendida de '$PVE_NAME'"
"$VBOXMANAGE_BIN" startvm "$PVE_NAME" --type headless

wait_poweroff "$PVE_NAME" "$INSTALL_TIMEOUT"

log_info "Retirando la ISO y arrancando desde el disco"
"$VBOXMANAGE_BIN" storageattach "$PVE_NAME" --storagectl SATA \
    --port 1 --device 0 --type dvddrive --medium none
"$VBOXMANAGE_BIN" modifyvm "$PVE_NAME" --boot1 disk --boot2 none

rm -f "$AUTO_ISO" "$ANSWER_FILE"

"$VBOXMANAGE_BIN" startvm "$PVE_NAME" --type headless

log_ok "$PVE_NAME instalado y en marcha (${PVE_IP})."
