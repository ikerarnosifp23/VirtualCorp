#!/usr/bin/env bash
# =========================================================
# Despliegue de los equipos de la delegación
# (clones enlazados de los templates Debian)
# =========================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

EQUIPMENT_FILE="${CONFIGS_DIR}/equipment.conf"

# ---------------------------------------------------------
# Comprueba que los templates existen
# ---------------------------------------------------------
check_templates() {
    local tpl
    for tpl in "$TEMPLATE_SERVER_NAME" "$TEMPLATE_DESKTOP_NAME"; do
        if ! "$VBOXMANAGE_BIN" snapshot "$tpl" list >/dev/null 2>&1; then
            log_err "No existe el template '$tpl' (o no tiene snapshot). Ejecuta primero: make create_templates"
            exit 1
        fi
    done
}

# ---------------------------------------------------------
# Crea un equipo como clon enlazado
# ---------------------------------------------------------
deploy_machine() {
    local name="$1" template_type="$2" memory="$3" cpus="$4" network="$5"
    local template

    case "$template_type" in
        server)  template="$TEMPLATE_SERVER_NAME" ;;
        desktop) template="$TEMPLATE_DESKTOP_NAME" ;;
        *)
            log_err "Template desconocido '$template_type' para '$name'"
            return 1
            ;;
    esac

    if "$VBOXMANAGE_BIN" showvminfo "$name" >/dev/null 2>&1; then
        log_warn "El equipo '$name' ya existe. Se omite."
        return 0
    fi

    log_info "Creando '$name' ($template_type) -> red '$network'"

    "$VBOXMANAGE_BIN" clonevm "$template" \
        --snapshot base \
        --options link \
        --name "$name" \
        --groups "$VM_EQUIPMENT_GROUP" \
        --register

    "$VBOXMANAGE_BIN" modifyvm "$name" \
	--groups "$VM_EQUIPMENT_GROUP" \
	--memory "$memory" \
        --cpus "$cpus" \
        --nic1 intnet \
        --intnet1 "$network" \
        --cableconnected1 on

    log_ok "Equipo '$name' creado."
}

# =========================================================
# Ejecución
# =========================================================

check_templates

while read -r name template_type memory cpus network <&3; do
    # Saltar líneas vacías y comentarios
    [[ -z "$name" || "$name" == \#* ]] && continue
    deploy_machine "$name" "$template_type" "$memory" "$cpus" "$network"
done 3< "$EQUIPMENT_FILE"

log_ok "Equipos desplegados correctamente."
