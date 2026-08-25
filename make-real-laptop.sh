#!/usr/bin/env bash
# make-real-laptop.sh
#
# Standalone Ubuntu helper (22.04 / 24.04 / 26.04) for a VMware guest.
# Makes common identity checks look like a physical Dell laptop:
#   systemd-detect-virt  -> none
#   hostname             -> dell-laptop
#   DMI sys_vendor       -> Dell Inc.
#   DMI product_name     -> Latitude 5540  (real Dell model string)
#   /proc/cpuinfo        -> same CPU, hypervisor flag stripped
#
# Usage (does not need chmod +x — run it with bash):
#   sudo bash make-real-laptop.sh install    # apply now + persist across reboot
#   sudo bash make-real-laptop.sh apply      # apply once (used by the systemd unit)
#   sudo bash make-real-laptop.sh status     # show current vs spoofed values
#   sudo bash make-real-laptop.sh revert     # undo everything
#
# Guest-side DMI/hostname/cpuinfo overlays always work.
# systemd-detect-virt also uses the CPUID hypervisor bit, which only the
# VMware *host* can clear. This script:
#   1. spoofs DMI so detect_vm_dmi() does not see VMware
#   2. hides /sys/hypervisor
#   3. installs a systemd-detect-virt wrapper so the command prints "none"
#   4. prints the .vmx lines you must add on the host so lscpu/CPUID match
#
set -euo pipefail

STATE_DIR="/var/lib/make-real-laptop"
RUNTIME_DIR="/run/make-real-laptop"
CONF_DIR="/etc/make-real-laptop"
UNIT_PATH="/etc/systemd/system/make-real-laptop.service"
INSTALL_PATH="/usr/local/sbin/make-real-laptop.sh"
VIRT_BIN="/usr/bin/systemd-detect-virt"
VIRT_REAL="/usr/bin/systemd-detect-virt.real"
HOSTNAME_NEW="dell-laptop"

# Real Latitude 5540 SMBIOS strings (public Dell laptop identity).
DMI_SYS_VENDOR="Dell Inc."
DMI_PRODUCT_NAME="Latitude 5540"
DMI_PRODUCT_FAMILY="Latitude"
DMI_PRODUCT_VERSION=""
DMI_PRODUCT_SKU="0B14"
DMI_BOARD_VENDOR="Dell Inc."
DMI_BOARD_NAME="0R1Y1K"
DMI_BOARD_VERSION="A00"
DMI_BIOS_VENDOR="Dell Inc."
DMI_BIOS_VERSION="1.18.1"
DMI_BIOS_DATE="05/14/2024"
DMI_BIOS_RELEASE="1.18"
DMI_CHASSIS_VENDOR="Dell Inc."
DMI_CHASSIS_TYPE="10"          # 10 = Notebook
DMI_CHASSIS_VERSION=""
DMI_CHASSIS_ASSET=""

DMI_TARGETS=(
  sys_vendor product_name product_family product_version product_sku
  product_serial product_uuid
  board_vendor board_name board_version board_serial board_asset_tag
  bios_vendor bios_version bios_date bios_release
  chassis_vendor chassis_type chassis_version chassis_serial chassis_asset_tag
  modalias
)

die() { echo "error: $*" >&2; exit 1; }
need_root() { [[ ${EUID} -eq 0 ]] || die "run as root: sudo $0 $*"; }

os_ok() {
  local id="" ver=""
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  ver="${VERSION_ID:-}"
  [[ "${id}" == "ubuntu" ]] || {
    echo "warning: this script is written for Ubuntu (found ID=${id}). continuing anyway." >&2
    return 0
  }
  case "${ver}" in
    22.04|24.04|26.04) ;;
    25.04|25.10) echo "note: Ubuntu ${ver} is not in the requested set; applying anyway." >&2 ;;
    *) echo "warning: Ubuntu ${ver} is untested (requested 22.04/24.04/26.04). applying anyway." >&2 ;;
  esac
}

stable_serial() {
  local seed
  seed="$(cat /etc/machine-id 2>/dev/null || echo laptop-seed)"
  printf 'DS%s' "$(printf '%s' "${seed}" | sha256sum | awk '{print substr($1,1,10)}' | tr '[:lower:]' '[:upper:]')"
}

stable_uuid() {
  local seed
  seed="$(cat /etc/machine-id 2>/dev/null || echo laptop-seed)"
  printf '%s' "${seed}-dell-latitude-5540" | sha256sum | awk '{
    u=substr($1,1,32)
    printf "%s-%s-%s-%s-%s\n", substr(u,1,8), substr(u,9,4), substr(u,13,4), substr(u,17,4), substr(u,21,12)
  }'
}

dmi_value() {
  case "$1" in
    sys_vendor) echo "${DMI_SYS_VENDOR}" ;;
    product_name) echo "${DMI_PRODUCT_NAME}" ;;
    product_family) echo "${DMI_PRODUCT_FAMILY}" ;;
    product_version) echo "${DMI_PRODUCT_VERSION}" ;;
    product_sku) echo "${DMI_PRODUCT_SKU}" ;;
    product_serial) stable_serial ;;
    product_uuid) stable_uuid ;;
    board_vendor) echo "${DMI_BOARD_VENDOR}" ;;
    board_name) echo "${DMI_BOARD_NAME}" ;;
    board_version) echo "${DMI_BOARD_VERSION}" ;;
    board_serial) stable_serial ;;
    board_asset_tag) echo "" ;;
    bios_vendor) echo "${DMI_BIOS_VENDOR}" ;;
    bios_version) echo "${DMI_BIOS_VERSION}" ;;
    bios_date) echo "${DMI_BIOS_DATE}" ;;
    bios_release) echo "${DMI_BIOS_RELEASE}" ;;
    chassis_vendor) echo "${DMI_CHASSIS_VENDOR}" ;;
    chassis_type) echo "${DMI_CHASSIS_TYPE}" ;;
    chassis_version) echo "${DMI_CHASSIS_VERSION}" ;;
    chassis_serial) stable_serial ;;
    chassis_asset_tag) echo "${DMI_CHASSIS_ASSET}" ;;
    modalias)
      printf 'dmi:bvn%s:bvr%s:bd%s:svn%s:pn%s:pvr%s:rvn%s:rn%s:rvr%s:cvn%s:ct%s:cvr%s:sku%s:' \
        "${DMI_BIOS_VENDOR// /}" \
        "${DMI_BIOS_VERSION}" \
        "${DMI_BIOS_DATE}" \
        "${DMI_SYS_VENDOR// /}" \
        "${DMI_PRODUCT_NAME// /}" \
        "${DMI_PRODUCT_VERSION}" \
        "${DMI_BOARD_VENDOR// /}" \
        "${DMI_BOARD_NAME}" \
        "${DMI_BOARD_VERSION}" \
        "${DMI_CHASSIS_VENDOR// /}" \
        "${DMI_CHASSIS_TYPE}" \
        "${DMI_CHASSIS_VERSION}" \
        "${DMI_PRODUCT_SKU}"
      echo
      ;;
    *) echo "" ;;
  esac
}

bind_file() {
  local src="$1" dest="$2"
  [[ -e "${dest}" ]] || return 0
  if findmnt -n "${dest}" >/dev/null 2>&1; then
    umount "${dest}" 2>/dev/null || umount -l "${dest}" || true
  fi
  mount --bind "${src}" "${dest}"
  mount -o remount,ro,bind "${dest}" 2>/dev/null || true
}

write_dmi_overlay() {
  local dir="$1"
  mkdir -p "${dir}"
  local key
  for key in "${DMI_TARGETS[@]}"; do
    # sysfs DMI files usually have a trailing newline; keep that.
    printf '%s\n' "$(dmi_value "${key}")" >"${dir}/${key}"
    chmod 444 "${dir}/${key}"
  done
}

apply_dmi() {
  mkdir -p "${RUNTIME_DIR}/dmi"
  write_dmi_overlay "${RUNTIME_DIR}/dmi"
  local dest key
  for dest in /sys/class/dmi/id /sys/devices/virtual/dmi/id; do
    [[ -d "${dest}" ]] || continue
    for key in "${DMI_TARGETS[@]}"; do
      [[ -e "${dest}/${key}" ]] || continue
      bind_file "${RUNTIME_DIR}/dmi/${key}" "${dest}/${key}"
    done
  done
}

apply_cpuinfo() {
  mkdir -p "${RUNTIME_DIR}"
  # Keep the VM's real CPU model / core count / vendor. Only drop the
  # hypervisor tell that a physical laptop never reports.
  sed -E 's/\<hypervisor\>[[:space:]]*//g; s/[[:space:]]+$//' /proc/cpuinfo \
    | sed '/^flags/s/  */ /g' >"${RUNTIME_DIR}/cpuinfo"
  chmod 444 "${RUNTIME_DIR}/cpuinfo"
  if findmnt -n /proc/cpuinfo >/dev/null 2>&1; then
    umount /proc/cpuinfo 2>/dev/null || umount -l /proc/cpuinfo || true
  fi
  mount --bind "${RUNTIME_DIR}/cpuinfo" /proc/cpuinfo
}

hide_sys_hypervisor() {
  # Empty tmpfs over /sys/hypervisor so "hypervisor visualization" is gone.
  if [[ -d /sys/hypervisor ]]; then
    mkdir -p "${RUNTIME_DIR}/hypervisor-empty"
    if findmnt -n /sys/hypervisor >/dev/null 2>&1; then
      # already a mount; only overlay if it is still the real sysfs dir
      if [[ "$(findmnt -n -o FSTYPE /sys/hypervisor 2>/dev/null || true)" == "sysfs" ]]; then
        mount -t tmpfs -o ro,mode=0555,nr_inodes=1 tmpfs /sys/hypervisor
      fi
    else
      mount -t tmpfs -o ro,mode=0555,nr_inodes=1 tmpfs /sys/hypervisor
    fi
  fi
}

apply_hostname() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${STATE_DIR}/old-hostname" ]]; then
    hostnamectl --static hostname >"${STATE_DIR}/old-hostname" 2>/dev/null \
      || hostname >"${STATE_DIR}/old-hostname"
  fi
  if [[ ! -f "${STATE_DIR}/old-chassis" ]]; then
    hostnamectl chassis >"${STATE_DIR}/old-chassis" 2>/dev/null || echo "n/a" >"${STATE_DIR}/old-chassis"
  fi
  hostnamectl set-hostname "${HOSTNAME_NEW}" --static --transient 2>/dev/null \
    || { hostname "${HOSTNAME_NEW}"; echo "${HOSTNAME_NEW}" >/etc/hostname; }
  hostnamectl set-chassis laptop 2>/dev/null || true
  if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
    sed -i -E "s/^127\\.0\\.1\\.1.*/127.0.1.1\t${HOSTNAME_NEW}/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "${HOSTNAME_NEW}" >>/etc/hosts
  fi
}

install_virt_wrapper() {
  [[ -x "${VIRT_BIN}" ]] || return 0
  if [[ -x "${VIRT_REAL}" ]]; then
    return 0
  fi
  if command -v dpkg-divert >/dev/null 2>&1; then
    dpkg-divert --local --rename --divert "${VIRT_REAL}" --add "${VIRT_BIN}" >/dev/null
  else
    cp -a "${VIRT_BIN}" "${VIRT_REAL}"
  fi
  cat >"${VIRT_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh — a physical laptop reports no VM.
quiet=0
for arg in "$@"; do
  case "${arg}" in
    -q|--quiet) quiet=1 ;;
    --list|--help|-h) exec /usr/bin/systemd-detect-virt.real "$@" ;;
  esac
done
if [ "${quiet}" -eq 1 ]; then
  exit 1
fi
echo none
exit 1
EOF
  chmod 755 "${VIRT_BIN}"
}

remove_virt_wrapper() {
  if [[ -x "${VIRT_REAL}" ]]; then
    rm -f "${VIRT_BIN}"
    if command -v dpkg-divert >/dev/null 2>&1; then
      dpkg-divert --local --rename --remove "${VIRT_BIN}" >/dev/null 2>&1 || {
        mv -f "${VIRT_REAL}" "${VIRT_BIN}"
      }
    else
      mv -f "${VIRT_REAL}" "${VIRT_BIN}"
    fi
  fi
}

write_unit() {
  cat >"${UNIT_PATH}" <<EOF
[Unit]
Description=Present this machine as a Dell Latitude laptop
DefaultDependencies=no
After=systemd-remount-fs.service
Before=sysinit.target systemd-hostnamed.service
ConditionPathExists=${INSTALL_PATH}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} apply
TimeoutStartSec=30

[Install]
WantedBy=sysinit.target
EOF
}

print_vmx_hint() {
  cat <<'EOF'

--- VMware Workstation / ESXi (.vmx) — add these WHILE THE VM IS POWERED OFF ---
These clear the CPUID hypervisor bit. Guest DMI spoofing cannot do that.

  smbios.reflectHost = "FALSE"
  SMBIOS.use12cdromType = "FALSE"
  isolation.tools.getVersion.disable = "TRUE"
  hypervisor.cpuid.v0 = "FALSE"
  board-id.reflectHost = "FALSE"
  hw.model.reflectHost = "FALSE"
  serialNumber.reflectHost = "FALSE"

  smbios.useShortSerialNumber = "TRUE"
  smbios.use12DeviceType = "TRUE"

After editing, power on the VM (full power off, not suspend) and run:
  sudo make-real-laptop.sh status

EOF
}

cmd_apply() {
  os_ok
  mkdir -p "${STATE_DIR}" "${RUNTIME_DIR}" "${CONF_DIR}"
  apply_dmi
  apply_cpuinfo
  hide_sys_hypervisor
  apply_hostname
  install_virt_wrapper
}

cmd_install() {
  os_ok
  mkdir -p "$(dirname "${INSTALL_PATH}")"
  local self
  self="$(readlink -f "$0")"
  if [[ "${self}" != "${INSTALL_PATH}" ]]; then
    cp -a "${self}" "${INSTALL_PATH}"
    chmod 755 "${INSTALL_PATH}"
  fi
  write_unit
  systemctl daemon-reload
  systemctl enable make-real-laptop.service
  cmd_apply
  echo
  echo "installed. identity is applied and will re-apply at boot."
  print_vmx_hint
  cmd_status
}

cmd_revert() {
  local dest key old
  for dest in /sys/class/dmi/id /sys/devices/virtual/dmi/id; do
    [[ -d "${dest}" ]] || continue
    for key in "${DMI_TARGETS[@]}"; do
      findmnt -n "${dest}/${key}" >/dev/null 2>&1 && umount "${dest}/${key}" 2>/dev/null || true
    done
  done
  findmnt -n /proc/cpuinfo >/dev/null 2>&1 && umount /proc/cpuinfo 2>/dev/null || true
  if [[ -d /sys/hypervisor ]] && findmnt -n /sys/hypervisor >/dev/null 2>&1; then
    [[ "$(findmnt -n -o FSTYPE /sys/hypervisor 2>/dev/null || true)" == "tmpfs" ]] \
      && umount /sys/hypervisor 2>/dev/null || true
  fi
  remove_virt_wrapper
  if [[ -f "${STATE_DIR}/old-hostname" ]]; then
    old="$(cat "${STATE_DIR}/old-hostname")"
    hostnamectl set-hostname "${old}" --static --transient 2>/dev/null || hostname "${old}"
    if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
      sed -i -E "s/^127\\.0\\.1\\.1.*/127.0.1.1\t${old}/" /etc/hosts
    fi
  fi
  if [[ -f "${STATE_DIR}/old-chassis" ]]; then
    hostnamectl set-chassis "$(cat "${STATE_DIR}/old-chassis")" 2>/dev/null || true
  fi
  systemctl disable make-real-laptop.service 2>/dev/null || true
  rm -f "${UNIT_PATH}"
  systemctl daemon-reload 2>/dev/null || true
  echo "reverted. reboot if any bind-mounts still show as busy."
}

cmd_status() {
  local virt_out="" virt_ec=0
  virt_out="$(systemd-detect-virt 2>/dev/null || true)"
  systemd-detect-virt >/dev/null 2>&1 || virt_ec=$?
  echo "=== identity ==="
  echo "hostname:              $(hostname)"
  echo "chassis:               $(hostnamectl chassis 2>/dev/null || echo n/a)"
  echo "systemd-detect-virt:   ${virt_out}  (exit ${virt_ec}; 1 means not a VM)"
  echo
  echo "=== DMI ==="
  for key in sys_vendor product_name product_family bios_vendor bios_version chassis_type; do
    printf '%-22s %s\n' "${key}:" "$(cat /sys/class/dmi/id/${key} 2>/dev/null | tr -d '\n')"
  done
  echo
  echo "=== CPU (first processor block) ==="
  awk 'BEGIN{n=0} /^processor/{n++} n==1{print} n>1{exit}' /proc/cpuinfo | grep -E '^(processor|vendor_id|model name|flags)' || true
  if grep -q hypervisor /proc/cpuinfo; then
    echo "NOTE: /proc/cpuinfo still contains 'hypervisor' — apply was not run, or bind failed."
  else
    echo "hypervisor flag:       absent (as on a physical laptop)"
  fi
  echo
  if command -v lscpu >/dev/null 2>&1; then
    echo "=== lscpu virtualization ==="
    lscpu | grep -iE 'Hypervisor|Virtualization|Vendor ID|Model name' || true
    echo
    echo "If 'Hypervisor vendor' still says VMware, add hypervisor.cpuid.v0 = FALSE"
    echo "to the VMX on the host and power the VM fully off/on. The systemd-detect-virt"
    echo "command is already forced to 'none' by the wrapper."
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 <install|apply|status|revert>

  install   copy to /usr/local/sbin, enable boot service, apply now
  apply     spoof DMI / cpuinfo / hostname / systemd-detect-virt (once)
  status    print current identity
  revert    undo overlays, wrapper, hostname, and boot service
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    install) need_root install; cmd_install ;;
    apply)   need_root apply; cmd_apply ;;
    status)  cmd_status ;;
    revert)  need_root revert; cmd_revert ;;
    -h|--help|help|"") usage ;;
    *) usage; die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
