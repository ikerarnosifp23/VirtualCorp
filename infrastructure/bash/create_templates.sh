#!/usr/bin/env bash
# =========================================================
# Creació dels templates Debian Server i Debian Desktop
# (instal·lació desatesa amb preseed + VBoxManage unattended)
# =========================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/iso.sh"

PRESEED_TEMPLATE="${CONFIGS_DIR}/preseed/debian.preseed.template"
PRESEED_OUT_DIR="${PROJECT_ROOT}/artifacts/preseed"
INSTALL_TIMEOUT=3600

# El caràcter & no ha de tenir significat especial en ${var//a/b}
shopt -u patsub_replacement 2>/dev/null || true

# ---------------------------------------------------------
# Genera el preseed d'un template a partir de la plantilla
# ---------------------------------------------------------
generate_preseed() {
    local out="$1" role="$2" hostname="$3" extra_packages="$4"

    local password hash content
    password="$(openssl rand -base64 24)"
    hash="$(openssl passwd -6 "$password")"

    content="$(<"$PRESEED_TEMPLATE")"
    content="${content//@@ROLE@@/$role}"
    content="${content//@@HOSTNAME@@/$hostname}"
    content="${content//@@EXTRA_PACKAGES@@/$extra_packages}"
    content="${content//@@PASSWORD_HASH@@/$hash}"
    content="${content//@@AUDITOR_KEY@@/$(<"$AUDIT_PUB_KEY_FILE")}"
    content="${content//@@SYSADMIN_KEY@@/$(<"$SYSADMIN_PUB_KEY_FILE")}"

    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$content" > "$out"
    chmod 600 "$out"
}

# ---------------------------------------------------------
# Espera que una VM s'apagui
# ---------------------------------------------------------
wait_poweroff() {
    local name="$1" timeout="$2" elapsed=0 state

    while (( elapsed < timeout )); do
        state="$("$VBOXMANAGE_BIN" showvminfo "$name" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
        [[ "$state" == "poweroff" ]] && return 0
        sleep 10
        elapsed=$((elapsed + 10))
        (( elapsed % 120 == 0 )) && log_info "Instal·lant '$name'... ($((elapsed / 60)) min)"
    done

    log_err "Timeout: '$name' no s'ha apagat en $((timeout / 60)) minuts."
    return 1
}

# ---------------------------------------------------------
# Treu les ISO (instal·lació i auxiliar) de la VM
# ---------------------------------------------------------
detach_isos() {
    local name="$1" line ctl port dev

    while IFS= read -r line; do
        if [[ "$line" =~ ^\"(.+)-([0-9]+)-([0-9]+)\"=\".*\.(iso|viso)\"$ ]]; then
            ctl="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            dev="${BASH_REMATCH[3]}"
            "$VBOXMANAGE_BIN" storageattach "$name" --storagectl "$ctl" \
                --port "$port" --device "$dev" --medium none
        fi
    done < <("$VBOXMANAGE_BIN" showvminfo "$name" --machinereadable)
}

# ---------------------------------------------------------
# Crea un template Debian
# ---------------------------------------------------------
create_debian_template() {
    local name="$1" role="$2" extra_packages="$3" memory="$4" cpus="$5" disk_mb="$6"

    if "$VBOXMANAGE_BIN" showvminfo "$name" >/dev/null 2>&1; then
        log_warn "El template '$name' ja existeix. S'omet."
        return 0
    fi

    log_info "=========================================="
    log_info "Creant template: $name ($role)"
    log_info "=========================================="

    local preseed="${PRESEED_OUT_DIR}/${name}.preseed"
    generate_preseed "$preseed" "$role" "$name" "$extra_packages"

    "$VBOXMANAGE_BIN" createvm --name "$name" --ostype Debian_64 \
        --groups "$VM_TEMPLATES_GROUP" --register

    "$VBOXMANAGE_BIN" modifyvm "$name" \
        --memory "$memory" --cpus "$cpus" \
        --nic1 nat \
        --graphicscontroller vmsvga --vram 32 \
        --audio-enabled off \
        --rtc-use-utc on \
        --boot1 dvd --boot2 disk --boot3 none --boot4 none

    local vm_dir
    vm_dir="$(dirname "$("$VBOXMANAGE_BIN" showvminfo "$name" --machinereadable | grep '^CfgFile=' | cut -d'"' -f2)")"

    "$VBOXMANAGE_BIN" createmedium disk --filename "$vm_dir/$name.vdi" \
        --size "$disk_mb" --format VDI --variant Standard

    "$VBOXMANAGE_BIN" storagectl "$name" --name SATA --add sata \
        --controller IntelAhci --portcount 4 --bootable on

    "$VBOXMANAGE_BIN" storageattach "$name" --storagectl SATA \
        --port 0 --device 0 --type hdd --medium "$vm_dir/$name.vdi"

    log_info "Iniciant la instal·lació desatesa de '$name'"

    "$VBOXMANAGE_BIN" unattended install "$name" \
        --iso="$DEBIAN_ISO_PATH" \
        --script-template="$preseed" \
        --user=sysadmin \
        --password="$(openssl rand -base64 24)" \
        --hostname="$name.vcorp.local" \
        --locale=es_ES --country=ES --time-zone=Europe/Madrid \
        --start-vm=headless

    wait_poweroff "$name" "$INSTALL_TIMEOUT"

    log_info "Preparant '$name' per a la clonació"

    detach_isos "$name"

    "$VBOXMANAGE_BIN" modifyvm "$name" \
        --nic1 none \
        --boot1 disk --boot2 none

    "$VBOXMANAGE_BIN" snapshot "$name" take base \
        --description "Base per a clons enllaçats"

    rm -f "$preseed"

    log_ok "Template '$name' creat correctament."
}

# =========================================================
# Execució
# =========================================================

download_iso "$DEBIAN_ISO_URL" "$DEBIAN_ISO_PATH" "$DEBIAN_SHA256SUMS_URL"

create_debian_template "$TEMPLATE_SERVER_NAME" "Server" \
    "" \
    1024 1 10240

create_debian_template "$TEMPLATE_DESKTOP_NAME" "Desktop" \
    "lxqt-core sddm xorg falkon" \
    2048 2 16384

log_ok "Templates creats correctament."
