#!/usr/bin/env bash
# =========================================================
# Descàrrega i verificació d'imatges ISO (versions fixades)
# =========================================================

download_iso() {
    local url="$1"
    local dest="$2"
    local sums_url="$3"
    local name
    name="$(basename "$dest")"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        log_info "La ISO $name ja existeix, no es torna a descarregar"
    else
        log_info "Descarregant $name"
        if ! curl -fL --retry 3 -o "$dest.part" "$url"; then
            log_err "No s'ha pogut descarregar $url"
            rm -f "$dest.part"
            return 1
        fi
        mv "$dest.part" "$dest"
    fi

    log_info "Verificant la suma SHA256 de $name"

    local expected
    expected="$(curl -fsL "$sums_url" | awk -v f="$name" '$2 == f || $2 == "*"f { print $1 }')"

    if [[ -z "$expected" ]]; then
        log_err "No s'ha trobat la suma de $name a $sums_url"
        return 1
    fi

    if ! echo "$expected  $dest" | sha256sum -c --quiet -; then
        log_err "La suma SHA256 de $name no coincideix. Esborra el fitxer i torna-ho a provar."
        return 1
    fi

    log_ok "ISO $name verificada"
}
