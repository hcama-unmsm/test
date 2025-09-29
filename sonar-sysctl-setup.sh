#!/usr/bin/env bash
# sonar-sysctl-setup.sh
# Aplica en caliente y persiste vm.max_map_count (y fs.file-max opcional).
# Opcional: configura límites de systemd para k3s (nofile/nproc).

set -euo pipefail

# ---- Valores por defecto (puedes cambiarlos con flags) ----
VM_MAX_MAP_COUNT="${VM_MAX_MAP_COUNT:-262144}"
FS_FILE_MAX="${FS_FILE_MAX:-65536}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-sonar.conf}"
SET_FS_FILE_MAX="${SET_FS_FILE_MAX:-1}"     # 1 = escribir fs.file-max también
CONFIGURE_K3S_LIMITS="${CONFIGURE_K3S_LIMITS:-0}" # 1 = configurar límites para k3s
K3S_NOFILE="${K3S_NOFILE:-131072}"
K3S_NPROC="${K3S_NPROC:-8192}"

usage() {
  cat <<EOF
Uso: sudo ./sonar-sysctl-setup.sh [opciones]

Opciones:
  --vm <num>           Valor para vm.max_map_count (def: ${VM_MAX_MAP_COUNT})
  --fs <num>           Valor para fs.file-max (def: ${FS_FILE_MAX})
  --no-fs              No tocar fs.file-max
  --k3s-limits         Configurar límites de systemd para k3s (LimitNOFILE/LimitNPROC)
  --k3s-nofile <num>   Valor para LimitNOFILE (def: ${K3S_NOFILE})
  --k3s-nproc  <num>   Valor para LimitNPROC  (def: ${K3S_NPROC})
  --sysctl-file <path> Archivo sysctl (def: ${SYSCTL_FILE})

Ejemplos:
  sudo ./sonar-sysctl-setup.sh
  sudo ./sonar-sysctl-setup.sh --k3s-limits
  sudo ./sonar-sysctl-setup.sh --vm 262144 --fs 131072 --k3s-limits --k3s-nofile 262144
EOF
}

# ---- Parseo simple de flags ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_MAX_MAP_COUNT="$2"; shift 2 ;;
    --fs) FS_FILE_MAX="$2"; shift 2 ;;
    --no-fs) SET_FS_FILE_MAX=0; shift ;;
    --k3s-limits) CONFIGURE_K3S_LIMITS=1; shift ;;
    --k3s-nofile) K3S_NOFILE="$2"; shift 2 ;;
    --k3s-nproc)  K3S_NPROC="$2";  shift 2 ;;
    --sysctl-file) SYSCTL_FILE="$2"; shift 2 ;;
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

apply_sysctl_runtime() {
  echo "→ Aplicando en caliente:"
  sysctl -w "vm.max_map_count=${VM_MAX_MAP_COUNT}"
  if [[ "${SET_FS_FILE_MAX}" -eq 1 ]]; then
    sysctl -w "fs.file-max=${FS_FILE_MAX}"
  fi
}

write_sysctl_file() {
  echo "→ Escribiendo ${SYSCTL_FILE} (persistente):"
  mkdir -p "$(dirname "${SYSCTL_FILE}")"
  {
    echo "vm.max_map_count=${VM_MAX_MAP_COUNT}"
    [[ "${SET_FS_FILE_MAX}" -eq 1 ]] && echo "fs.file-max=${FS_FILE_MAX}"
  } > "${SYSCTL_FILE}"
  chmod 644 "${SYSCTL_FILE}"
}

reload_sysctl_file() {
  echo "→ Recargando desde ${SYSCTL_FILE}:"
  sysctl -p "${SYSCTL_FILE}"
}

show_current() {
  echo "→ Valores actuales:"
  sysctl vm.max_map_count
  [[ "${SET_FS_FILE_MAX}" -eq 1 ]] && sysctl fs.file-max || true
}

configure_k3s_limits() {
  local unit=""
  if systemctl is-enabled --quiet k3s 2>/dev/null || systemctl is-active --quiet k3s 2>/dev/null; then
    unit="k3s"
  elif systemctl is-enabled --quiet k3s-agent 2>/dev/null || systemctl is-active --quiet k3s-agent 2>/dev/null; then
    unit="k3s-agent"
  else
    echo "⚠️  No se detectó k3s/k3s-agent como servicio systemd. Omitiendo límites." >&2
    return 0
  fi

  echo "→ Configurando límites para ${unit}: NOFILE=${K3S_NOFILE}, NPROC=${K3S_NPROC}"
  local dir="/etc/systemd/system/${unit}.service.d"
  mkdir -p "${dir}"
  cat > "${dir}/override.conf" <<EOF
[Service]
LimitNOFILE=${K3S_NOFILE}
LimitNPROC=${K3S_NPROC}
EOF

  systemctl daemon-reload
  # reexec no es necesario; con reload + restart basta
  systemctl restart "${unit}"

  echo "→ Límites efectivos:"
  systemctl show "${unit}" -p LimitNOFILE -p LimitNPROC
}

main() {
  require_root
  show_current
  apply_sysctl_runtime
  write_sysctl_file
  reload_sysctl_file
  [[ "${CONFIGURE_K3S_LIMITS}" -eq 1 ]] && configure_k3s_limits
  echo "✅ Listo."
}

main
