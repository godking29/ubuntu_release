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
# lscpu "Hypervisor vendor: VMware" comes from the CPUID instruction, which a
# guest cannot change. This script:
#   1. spoofs DMI so detect_vm_dmi() does not see VMware
#   2. hides /sys/hypervisor
#   3. wraps systemd-detect-virt so it prints "none"
#   4. wraps lscpu so it does not print Hypervisor vendor / Virtualization type
#   5. wraps hostnamectl so Virtualization: vmware is omitted (bare metal
#      hostnamectl has no Virtualization line). hostnamed still sees CPUID;
#      do not mask CPUID in the .vmx (that breaks Chrome and VMware Tools).
#   6. wraps lspci so vendor 15ad / "VMware" device names are rewritten to
#      Intel. The real PCI IDs in sysfs are unchanged (changing them would
#      break GPU, disk, USB, and VMware Tools).
#   7. spoofs SCSI model/vendor in sysfs + wraps lsblk (VMware Virtual disk /
#      NECVMWar CD). Does not change WWN / by-id (that would break fstab).
#   8. wraps ps so vmtoolsd is not listed. The daemon stays running — do not
#      stop open-vm-tools (clipboard, display, Tools would break). pgrep is
#      left alone so Tools can still find itself.
#   9. wraps ethtool so vmxnet3 is printed as e1000e.
#
set -euo pipefail

STATE_DIR="/var/lib/make-real-laptop"
RUNTIME_DIR="/run/make-real-laptop"
CONF_DIR="/etc/make-real-laptop"
UNIT_PATH="/etc/systemd/system/make-real-laptop.service"
INSTALL_PATH="/usr/local/sbin/make-real-laptop.sh"
VIRT_BIN="/usr/bin/systemd-detect-virt"
VIRT_REAL="/usr/bin/systemd-detect-virt.real"
LSCPU_BIN="/usr/bin/lscpu"
LSCPU_REAL="/usr/bin/lscpu.real"
HOSTNAMECTL_BIN="/usr/bin/hostnamectl"
HOSTNAMECTL_REAL="/usr/bin/hostnamectl.real"
LSPCI_BIN="/usr/bin/lspci"
LSPCI_REAL="/usr/bin/lspci.real"
PS_BIN="/usr/bin/ps"
PS_REAL="/usr/bin/ps.real"
LSBLK_BIN="/usr/bin/lsblk"
LSBLK_REAL="/usr/bin/lsblk.real"
LSSCSI_BIN="/usr/bin/lsscsi"
LSSCSI_REAL="/usr/bin/lsscsi.real"
ETHTOOL_BIN="/usr/sbin/ethtool"
ETHTOOL_REAL="/usr/sbin/ethtool.real"
ETHTOOL_BIN_ALT="/usr/bin/ethtool"
ETHTOOL_REAL_ALT="/usr/bin/ethtool.real"
HOSTNAMED_DROPIN="/etc/systemd/system/systemd-hostnamed.service.d/make-real-laptop.conf"
UDEV_DISK_RULE="/etc/udev/rules.d/61-make-real-laptop-disk.rules"
HOSTNAME_NEW="dell-laptop"

# SCSI INQUIRY widths: vendor 8, product 16, revision 4. Latitude 5540 NVMe.
BLOCK_DISK_VENDOR="ATA"
BLOCK_DISK_MODEL="SAMSUNG MZVL2512"
BLOCK_DISK_REV="5L2Q"
BLOCK_CD_VENDOR="HL-DT-ST"
BLOCK_CD_MODEL="DVDRAM GUE0N"
BLOCK_CD_REV="1.00"

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

scsi_pad() {
  printf '%-*s\n' "$1" "$2"
}

bind_scsi_attrs() {
  local dest="$1" kind="$2"
  local name dir key vendor model rev
  [[ -d "${dest}" ]] || return 0
  name="$(basename "$(dirname "${dest}")")"
  [[ -n "${name}" ]] || return 0
  dir="${RUNTIME_DIR}/block/${name}"
  mkdir -p "${dir}"
  if [[ "${kind}" == "cd" ]]; then
    vendor="$(scsi_pad 8 "${BLOCK_CD_VENDOR}")"
    model="$(scsi_pad 16 "${BLOCK_CD_MODEL}")"
    rev="$(scsi_pad 4 "${BLOCK_CD_REV}")"
  else
    vendor="$(scsi_pad 8 "${BLOCK_DISK_VENDOR}")"
    model="$(scsi_pad 16 "${BLOCK_DISK_MODEL}")"
    rev="$(scsi_pad 4 "${BLOCK_DISK_REV}")"
  fi
  printf '%s' "${vendor}" >"${dir}/vendor"
  printf '%s' "${model}" >"${dir}/model"
  printf '%s' "${rev}" >"${dir}/rev"
  chmod 444 "${dir}/vendor" "${dir}/model" "${dir}/rev"
  for key in vendor model rev; do
    [[ -e "${dest}/${key}" ]] || continue
    bind_file "${dir}/${key}" "${dest}/${key}"
  done
}

scsi_kind_from_dir() {
  local dest="$1" typef="" t="" name=""
  name="$(basename "$(dirname "${dest}")")"
  case "${name}" in
    sr*|scd*) echo cd; return ;;
  esac
  typef="${dest}/type"
  if [[ -r "${typef}" ]]; then
    t="$(tr -d '[:space:]' <"${typef}" 2>/dev/null || true)"
    # SCSI type 5 = CD/DVD
    if [[ "${t}" == "5" ]]; then
      echo cd
      return
    fi
  fi
  echo disk
}

apply_block_identity() {
  local dest kind
  mkdir -p "${RUNTIME_DIR}/block"
  for dest in /sys/block/*/device; do
    [[ -d "${dest}" ]] || continue
    case "$(basename "$(dirname "${dest}")")" in
      loop*|ram*|zram*|dm-*|md*|fd*) continue ;;
    esac
    kind="$(scsi_kind_from_dir "${dest}")"
    bind_scsi_attrs "${dest}" "${kind}"
  done
  for dest in /sys/class/scsi_device/*/device /sys/class/scsi_disk/*/device /sys/class/scsi_generic/*/device; do
    [[ -d "${dest}" ]] || continue
    kind="$(scsi_kind_from_dir "${dest}")"
    bind_scsi_attrs "${dest}" "${kind}"
  done
  cat >"${UDEV_DISK_RULE}" <<'EOF'
# Installed by make-real-laptop.sh — display names only. Do not touch ID_SERIAL
# or WWN; Ubuntu may mount by /dev/disk/by-id.
SUBSYSTEM=="block", ENV{ID_VENDOR}=="VMware*", ENV{ID_VENDOR}="ATA", ENV{ID_MODEL}="SAMSUNG MZVL2512"
SUBSYSTEM=="block", ENV{ID_VENDOR}=="NECVMWar*", ENV{ID_VENDOR}="HL-DT-ST", ENV{ID_MODEL}="DVDRAM GUE0N"
SUBSYSTEM=="block", ENV{ID_MODEL}=="VMware*", ENV{ID_VENDOR}="ATA", ENV{ID_MODEL}="SAMSUNG MZVL2512"
EOF
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
  fi
}

unmount_block_identity() {
  local dest key
  for dest in /sys/block/*/device /sys/class/scsi_device/*/device /sys/class/scsi_disk/*/device /sys/class/scsi_generic/*/device; do
    [[ -d "${dest}" ]] || continue
    for key in vendor model rev; do
      if findmnt -n "${dest}/${key}" >/dev/null 2>&1; then
        umount "${dest}/${key}" 2>/dev/null || umount -l "${dest}/${key}" 2>/dev/null || true
      fi
    done
  done
  rm -f "${UDEV_DISK_RULE}"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
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

ensure_divert() {
  local orig="$1" real="$2"
  [[ -e "${orig}" ]] || return 0
  if [[ ! -e "${real}" ]]; then
    if command -v dpkg-divert >/dev/null 2>&1; then
      dpkg-divert --local --rename --divert "${real}" --add "${orig}" >/dev/null
    else
      cp -a "${orig}" "${real}"
    fi
  fi
}

remove_divert() {
  local orig="$1" real="$2"
  if [[ -e "${real}" ]]; then
    rm -f "${orig}"
    if command -v dpkg-divert >/dev/null 2>&1; then
      dpkg-divert --local --rename --remove "${orig}" >/dev/null 2>&1 || mv -f "${real}" "${orig}"
    else
      mv -f "${real}" "${orig}"
    fi
  fi
}

install_virt_wrapper() {
  ensure_divert "${VIRT_BIN}" "${VIRT_REAL}"
  if [[ -e "${VIRT_REAL}" ]]; then
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
  fi

  ensure_divert "${LSCPU_BIN}" "${LSCPU_REAL}"
  if [[ -e "${LSCPU_REAL}" ]]; then
  cat >"${LSCPU_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh — drop VMware CPUID rows lscpu prints.
# A physical Intel laptop has no "Hypervisor vendor" / "Virtualization type".
# Vulnerability rows that say "Dependent on hypervisor status" also leak VM.
/usr/bin/lscpu.real "$@" \
  | sed \
      -e '/^Hypervisor vendor:/d' \
      -e '/^Virtualization type:/d' \
      -e 's/Unknown: Dependent on hypervisor status/Not affected/' \
  | grep -vi hypervisor
EOF
  chmod 755 "${LSCPU_BIN}"
  fi

  # hostnamectl talks to systemd-hostnamed over D-Bus. That daemon calls
  # detect_virtualization() in-process (CPUID), NOT /usr/bin/systemd-detect-virt.
  # Wrapping the virt binary therefore cannot hide "Virtualization: vmware".
  # A physical laptop omits that line; strip it from status output. Mutating
  # subcommands (set-hostname, …) go straight to the real binary.
  ensure_divert "${HOSTNAMECTL_BIN}" "${HOSTNAMECTL_REAL}"
  if [[ -e "${HOSTNAMECTL_REAL}" ]]; then
  cat >"${HOSTNAMECTL_BIN}" <<'EOF'
#!/bin/sh
real=/usr/bin/hostnamectl.real
for arg in "$@"; do
  case "${arg}" in
    set-hostname|set-chassis|set-deployment|set-location|set-icon-name|set-pretty)
      exec "${real}" "$@"
      ;;
  esac
done
"${real}" "$@" | sed -e '/^[[:space:]]*Virtualization:/d'
EOF
  chmod 755 "${HOSTNAMECTL_BIN}"
  fi

  # lspci reads the real PCI bus. VMware virtual devices are vendor 15ad.
  # Changing those IDs in hardware would break SVGA, disk, USB and Tools.
  # Rewrite lspci *output* to Intel Comet Lake / UHD 630 names (matches the
  # i7-10700 already visible in cpuinfo). Numeric 15ad -> 8086.
  ensure_divert "${LSPCI_BIN}" "${LSPCI_REAL}"
  if [[ -e "${LSPCI_REAL}" ]]; then
  cat >"${LSPCI_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/bin/lspci.real "$@" | sed \
  -e '/15ad:0740/d' \
  -e '/Virtual Machine Communication Interface/d' \
  -e 's/VMware SVGA II Adapter/UHD Graphics 630/g' \
  -e 's/VMware PCI Express Root Port/PCI Express Root Port/g' \
  -e 's/VMware PCI bridge/PCI bridge/g' \
  -e 's/VMware USB1\.1 UHCI Controller/USB UHCI Controller/g' \
  -e 's/VMware USB2 EHCI Controller/USB EHCI Controller/g' \
  -e 's/VMware SATA AHCI controller/SATA AHCI Controller/g' \
  -e 's/VMware, Inc\./Intel Corporation/g' \
  -e 's/VMware /Intel /g' \
  -e 's/vmwgfx/i915/g' \
  -e 's/vmw_pvscsi/ahci/g' \
  -e 's/vmxnet3/e1000e/g' \
  -e 's/\[15ad:/[8086:/g' \
  -e 's/\b15ad:/8086:/g' \
  | grep -viE 'vmware|15ad|virtualbox|virtio|qemu|xen|hyper-v|vmwgfx|vmw_|vmxnet' \
  || true
EOF
  chmod 755 "${LSPCI_BIN}"
  fi

  # vmtoolsd must keep running (Tools / clipboard / display). Only hide it from
  # `ps` listings. Do not wrap pgrep/pidof — open-vm-tools uses those.
  ensure_divert "${PS_BIN}" "${PS_REAL}"
  if [[ -e "${PS_REAL}" ]]; then
  cat >"${PS_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/bin/ps.real "$@" | grep -viE 'vmtoolsd|vmware-user|vmware-vmblock|VGAuthService|vmware-rpctool|vmware-toolbox|open-vm-tools|VBoxService|VBoxClient|qemu-ga|spice-vdagent|xe-daemon' || true
EOF
  chmod 755 "${PS_BIN}"
  fi

  ensure_divert "${LSBLK_BIN}" "${LSBLK_REAL}"
  if [[ -e "${LSBLK_REAL}" ]]; then
  cat >"${LSBLK_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/bin/lsblk.real "$@" | sed \
  -e 's/VMware Virtual SATA CDRW Drive/HL-DT-ST DVDRAM GUE0N/g' \
  -e 's/VMware Virtual S[^[:space:]]*/SAMSUNG MZVL2512/g' \
  -e 's/NECVMWar/HL-DT-ST/g' \
  -e 's/[[:space:]]VMware[[:space:]]/ ATA /g' \
  -e 's/\bVMware\b/ATA/g' \
  -e 's/[[:space:]]spi[[:space:]]/ sata /g' \
  | grep -viE 'vmware|necvmwar|pvscsi' || true
EOF
  chmod 755 "${LSBLK_BIN}"
  fi

  ensure_divert "${LSSCSI_BIN}" "${LSSCSI_REAL}"
  if [[ -e "${LSSCSI_REAL}" ]]; then
  cat >"${LSSCSI_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/bin/lsscsi.real "$@" | sed \
  -e 's/VMware   Virtual S[^[:space:]]*/ATA      SAMSUNG MZVL2512/g' \
  -e 's/NECVMWar VMware IDE CDR10/HL-DT-ST DVDRAM GUE0N  /g' \
  -e 's/VMware Virtual SATA CDRW Drive/HL-DT-ST DVDRAM GUE0N/g' \
  -e 's/VMware/ATA   /g' \
  -e 's/NECVMWar/HL-DT-ST/g' \
  | grep -viE 'vmware|necvmwar' || true
EOF
  chmod 755 "${LSSCSI_BIN}"
  fi

  ensure_divert "${ETHTOOL_BIN}" "${ETHTOOL_REAL}"
  if [[ -e "${ETHTOOL_REAL}" ]]; then
  cat >"${ETHTOOL_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/sbin/ethtool.real "$@" | sed \
  -e 's/vmxnet3/e1000e/g' \
  -e 's/vmxnet/e1000e/g' \
  -e 's/VMware/Intel/g' \
  | grep -viE 'vmware|vmxnet|vmw_' || true
EOF
  chmod 755 "${ETHTOOL_BIN}"
  fi
  if [[ -e "${ETHTOOL_BIN_ALT}" && "${ETHTOOL_BIN_ALT}" != "${ETHTOOL_BIN}" ]]; then
    ensure_divert "${ETHTOOL_BIN_ALT}" "${ETHTOOL_REAL_ALT}"
    if [[ -e "${ETHTOOL_REAL_ALT}" ]]; then
    cat >"${ETHTOOL_BIN_ALT}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
real=/usr/bin/ethtool.real
[ -x "${real}" ] || real=/usr/sbin/ethtool.real
"${real}" "$@" | sed \
  -e 's/vmxnet3/e1000e/g' \
  -e 's/vmxnet/e1000e/g' \
  -e 's/VMware/Intel/g' \
  | grep -viE 'vmware|vmxnet|vmw_' || true
EOF
    chmod 755 "${ETHTOOL_BIN_ALT}"
    fi
  fi

  mkdir -p "$(dirname "${HOSTNAMED_DROPIN}")"
  cat >"${HOSTNAMED_DROPIN}" <<'EOF'
[Service]
# systemd 256+ honours this; 255 (Ubuntu 24.04) ignores it. Harmless either way.
Environment=SYSTEMD_VIRTUALIZATION=none
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl try-restart systemd-hostnamed.service 2>/dev/null || true
}

remove_virt_wrapper() {
  remove_divert "${VIRT_BIN}" "${VIRT_REAL}"
  remove_divert "${LSCPU_BIN}" "${LSCPU_REAL}"
  remove_divert "${HOSTNAMECTL_BIN}" "${HOSTNAMECTL_REAL}"
  remove_divert "${LSPCI_BIN}" "${LSPCI_REAL}"
  remove_divert "${PS_BIN}" "${PS_REAL}"
  remove_divert "${LSBLK_BIN}" "${LSBLK_REAL}"
  remove_divert "${LSSCSI_BIN}" "${LSSCSI_REAL}"
  remove_divert "${ETHTOOL_BIN}" "${ETHTOOL_REAL}"
  remove_divert "${ETHTOOL_BIN_ALT}" "${ETHTOOL_REAL_ALT}"
  rm -f "${HOSTNAMED_DROPIN}"
  rmdir "$(dirname "${HOSTNAMED_DROPIN}")" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl try-restart systemd-hostnamed.service 2>/dev/null || true
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

=== Host .vmx CPUID masks — do NOT use them ===================================
Zeroing CPUID leaf 0x40000000 hides VMware from lscpu, but VMware Tools
*needs* that leaf to talk to the hypervisor. Masking leaf 1 ECX can also
strip AVX/OSXSAVE and Chrome then crashes with a "corrupted profile".

Do not add these (and remove them if you already did):

  cpuid.1.ecx = ...
  cpuid.40000000.eax / ebx / ecx / edx = ...
  isolation.tools.getVersion.disable = "TRUE"

Guest wrappers already hide VMware from systemd-detect-virt, lscpu, hostnamectl, lspci, ps, lsblk, and ethtool.
Leave the .vmx CPUID alone so Chrome and VMware Tools keep working.

If you already added those lines: shut the VM fully off, delete them from
the .vmx, save, power on. Then:

  sudo apt-get install --reinstall -y open-vm-tools open-vm-tools-desktop
  sudo systemctl restart open-vm-tools

Chrome: if it still says the profile is corrupted after the CPUID is
restored, it crashed while the mask was on. Test with:

  google-chrome --user-data-dir=/tmp/chrome-check

If that window is fine, the browser is OK and only the old profile lock
is stale — remove ~/.config/google-chrome/SingletonLock and retry.

EOF
}

cmd_apply() {
  os_ok
  mkdir -p "${STATE_DIR}" "${RUNTIME_DIR}" "${CONF_DIR}"
  apply_dmi
  apply_cpuinfo
  hide_sys_hypervisor
  apply_block_identity
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
  unmount_block_identity
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
  echo
  echo "=== hostnamectl (Virtualization line must be absent) ==="
  hostnamectl | grep -E 'hostname|Chassis|Virtualization|Hardware Vendor|Hardware Model' || true
  if [[ -x "${HOSTNAMECTL_REAL}" ]] && "${HOSTNAMECTL_REAL}" | grep -q 'Virtualization:'; then
    echo "(D-Bus hostnamed still reports a VM; hostnamectl no longer prints that line.)"
  fi
  if command -v lscpu >/dev/null 2>&1; then
    echo
    echo "=== lscpu ==="
    lscpu | grep -iE 'Vendor ID|Model name|Hypervisor|Virtualization type' || true
  fi
  if command -v lspci >/dev/null 2>&1; then
    echo
    echo "=== lspci (VMware / 15ad must be absent) ==="
    if lspci -nn | grep -Ei 'vmware|15ad|virtualbox|virtio|qemu|xen|hyper-v'; then
      echo "NOTE: lspci still names VMware devices — re-run: sudo bash $0 install"
    else
      echo "(none — lspci output uses Intel names; sysfs PCI IDs are still 15ad)"
    fi
  fi
  echo
  echo "=== ps (vmtoolsd / guest agents must be absent) ==="
  if ps aux | grep -Ei 'vmtoolsd|VBoxService|qemu-ga|spice-vdagent|xe-daemon'; then
    echo "NOTE: guest-tools process still visible — re-run: sudo bash $0 install"
  else
    echo "(none — vmtoolsd is still running; ps no longer lists it)"
  fi
  if command -v lsblk >/dev/null 2>&1; then
    echo
    echo "=== lsblk (VMware / NECVMWar must be absent) ==="
    lsblk -o NAME,MODEL,VENDOR,TRAN,SIZE,TYPE
    if lsblk -o NAME,MODEL,VENDOR | grep -Ei 'vmware|necvmwar'; then
      echo "NOTE: lsblk still names VMware disks — re-run: sudo bash $0 install"
    fi
  fi
  echo
  echo "=== NIC (ethtool driver; VMware MAC OUI is still real) ==="
  local iface driver mac
  for iface in /sys/class/net/*; do
    iface="$(basename "${iface}")"
    [[ "${iface}" == "lo" ]] && continue
    mac="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo n/a)"
    driver="n/a"
    if command -v ethtool >/dev/null 2>&1; then
      driver="$(ethtool -i "${iface}" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}')"
    fi
    printf '%-10s driver=%-10s mac=%s\n' "${iface}" "${driver:-n/a}" "${mac}"
    case "${mac}" in
      00:0c:29:*|00:50:56:*|00:05:69:*|00:1c:14:*)
        echo "  (MAC uses a VMware OUI. Changing it in-guest can break networking; set ethernet0.address in the .vmx if you need a Dell/Intel OUI.)"
        ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: sudo $0 <install|apply|status|revert>

  install   copy to /usr/local/sbin, enable boot service, apply now
  apply     spoof DMI / cpuinfo / disks / hostname / virt wrappers (once)
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
