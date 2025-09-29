#!/usr/bin/env bash
# k3s-net-setup.sh
# Complementa sonar-sysctl-setup.sh preparando la red para k3s/Kubernetes:
# - Carga/persiste br_netfilter
# - Aplica sysctl de bridge e ip_forward (persistentes y en caliente)
#
# NO modifica vm.max_map_count ni fs.file-max (eso lo maneja el otro script).

set -euo pipefail

# ---- Valores por defecto (se pueden cambiar por flags) ----
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-k3s.conf}"
ENABLE_IPV6_BRIDGE="${ENABLE_IPV6_BRIDGE:-1}"   # 1 = escribir bridge-nf para IPv6
APPLY_RUNTIME="${APPLY_RUNTIME:-1}"             # 1 = sysctl -w (aplicar en caliente)
RELOAD_FROM_FILE="${RELOAD_FROM_FILE:-1}"       # 1 = sysctl -p "${SYSCTL_FILE}"

usage() {
  cat <<EOF
Uso: sudo ./k3s-net-setup.sh [opciones]

Opciones:
  --sysctl-file <path>   Ruta del archivo sysctl (def: ${SYSCTL_FILE})
  --no-ipv6-bridge       No escribir net.bridge.bridge-nf-call-ip6tables
  --no-runtime           No aplicar en caliente (omite sysctl -w)
  --no-reload            No recargar desde el archivo (omite sysctl -p)
  -h, --help             Mostrar esta ayuda

Ejemplos:
  sudo ./k3s-net-setup.sh
  sudo ./k3s-net-setup.sh --sysctl-file /etc/sysctl.d/90-k8s.conf
  sudo ./k3s-net-setup.sh --no-ipv6-bridge
EOF
}

# ---- Parseo simple de flags (CORREGIDO) ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sysctl-file) SYSCTL_FILE="$2"; shift 2 ;;
    --no-ipv6-bridge) ENABLE_IPV6_BRIDGE=0; shift ;;
    --no-runtime) APPLY_RUNTIME=0; shift ;;
    --no-reload) RELOAD_FROM_FILE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Este script requiere sudo/root." >&2
    exit 1
  fi
}

load_br_netfilter_now() {
  echo "→ Cargando módulo br_netfilter (si no está activo)…"
  if ! lsmod | grep -q '^br_netfilter'; then
    modprobe br_netfilter || {
      echo "⚠️  No se pudo cargar br_netfilter con modprobe. Continúo, pero verifica el kernel." >&2
    }
  else
    echo "   br_netfilter ya está cargado."
  fi
}

persist_br_netfilter() {
  echo "→ Asegurando persistencia de br_netfilter en boot…"
  mkdir -p /etc/modules-load.d
  local ml_file="/etc/modules-load.d/k8s.conf"
  if [[ -f "${ml_file}" ]]; then
    if ! grep -q '^br_netfilter$' "${ml_file}"; then
      echo "br_netfilter" >> "${ml_file}"
      echo "   Añadido br_netfilter a ${ml_file}"
    else
      echo "   br_netfilter ya presente en ${ml_file}"
    fi
  else
    echo "br_netfilter" > "${ml_file}"
    chmod 644 "${ml_file}"
    echo "   Creado ${ml_file} con br_netfilter"
  fi
}

write_sysctl_file() {
  echo "→ Escribiendo configuración persistente en ${SYSCTL_FILE}…"
  mkdir -p "$(dirname "${SYSCTL_FILE}")"

  {
    echo "net.bridge.bridge-nf-call-iptables=1"
    [[ "${ENABLE_IPV6_BRIDGE}" -eq 1 ]] && echo "net.bridge.bridge-nf-call-ip6tables=1"
    echo "net.ipv4.ip_forward=1"
  } > "${SYSCTL_FILE}"

  chmod 644 "${SYSCTL_FILE}"
}

apply_runtime() {
  [[ "${APPLY_RUNTIME}" -eq 1 ]] || { echo "→ Omitido aplicar en caliente (por flag)."; return; }
  echo "→ Aplicando en caliente (sysctl -w)…"
  sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
  if [[ "${ENABLE_IPV6_BRIDGE}" -eq 1 ]]; then
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1 || true
  fi
  sysctl -w net.ipv4.ip_forward=1
}

reload_from_file() {
  [[ "${RELOAD_FROM_FILE}" -eq 1 ]] || { echo "→ Omitido recargar desde archivo (por flag)."; return; }
  echo "→ Recargando desde ${SYSCTL_FILE} (sysctl -p)…"
  sysctl -p "${SYSCTL_FILE}" || {
    echo "⚠️  sysctl -p retornó error. Verifica que las claves existan (p.ej., br_netfilter cargado)." >&2
  }
}

show_current() {
  echo "→ Valores actuales (si existen):"
  sysctl -a 2>/dev/null | grep -E 'net\.bridge\.bridge-nf-call-(ip6)?tables' || true
  sysctl net.ipv4.ip_forward
}

main() {
  require_root
  load_br_netfilter_now
  persist_br_netfilter
  write_sysctl_file
  apply_runtime
  reload_from_file
  show_current
  echo "✅ Red para k3s preparada."
}

main
