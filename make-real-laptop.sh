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
#   6b. wraps lsusb so vendor 0e0f names are rewritten. Does not bind-mount or
#      udev-rename the VMware virtual USB hub (needed to attach a USB camera).
#   7. spoofs SCSI model/vendor in sysfs + udev (so GNOME Disks / UDisks2
#      show Samsung, not VMware). lsblk is also wrapped. Optical drive is
#      hidden from Disks (UDISKS_IGNORE).
#   8. wraps ps so vmtoolsd is not listed. pgrep is left alone.
#   9. wraps ethtool so vmxnet3 is printed as e1000e.
#  10. runs Tools under a bland process name (gsd-disk-mon) and plugin/config
#      dirs (gsd-hw-helper / hw-assist-cfg). Original package paths stay for
#      apt; Files/Nautilus hides them via .hidden. Do not uninstall
#      open-vm-tools — clipboard and display need it.
#  11. PipeWire/Pulse/WirePlumber keep VM-sized audio buffers AND ALSA
#      headroom. Cloaking systemd-detect-virt makes PipeWire skip vm.overrides
#      and WirePlumber skip vm.node.defaults (api.alsa.headroom=8192). Without
#      that, the emulated ES1371 and USB mics chop. USB udev is not globally
#      triggered (that also glitches isochronous audio).
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
LSUSB_BIN="/usr/bin/lsusb"
LSUSB_REAL="/usr/bin/lsusb.real"
USBDEVICES_BIN="/usr/bin/usb-devices"
USBDEVICES_REAL="/usr/bin/usb-devices.real"
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
UDEV_DISK_RULE="/etc/udev/rules.d/99-make-real-laptop-disk.rules"
UDEV_USB_RULE="/etc/udev/rules.d/99-make-real-laptop-usb.rules"
UDEV_V4L_RULE="/etc/udev/rules.d/99-make-real-laptop-v4l.rules"
DISK_ID_HELPER="/usr/libexec/make-real-laptop-disk-id"
UDISKS_DROPIN="/etc/systemd/system/udisks2.service.d/make-real-laptop.conf"
INQUIRY_SRC="${STATE_DIR}/fakeinquiry.c"
INQUIRY_SO="/usr/lib/make-real-laptop/libfakeinquiry.so"
PIPEWIRE_CONF="/etc/pipewire/pipewire.conf.d/99-make-real-laptop.conf"
PIPEWIRE_PULSE_CONF="/etc/pipewire/pipewire-pulse.conf.d/99-make-real-laptop.conf"
PIPEWIRE_CLIENT_CONF="/etc/pipewire/client.conf.d/99-make-real-laptop.conf"
WIREPLUMBER_LUA="/etc/wireplumber/main.lua.d/51-make-real-laptop.lua"
WIREPLUMBER_LUA_OLD="/etc/wireplumber/main.lua.d/99-make-real-laptop.lua"
WIREPLUMBER_CONF="/etc/wireplumber/wireplumber.conf.d/99-make-real-laptop.conf"
PULSE_ENV="/etc/environment.d/99-make-real-laptop-audio.conf"
MODPROBE_USB="/etc/modprobe.d/99-make-real-laptop-usb.conf"
HOSTNAME_NEW="dell-laptop"

# SCSI INQUIRY widths: vendor 8, product 16, revision 4. Latitude 5540 NVMe.
BLOCK_DISK_VENDOR="Samsung"
BLOCK_DISK_MODEL="SAMSUNG MZVL2512"
BLOCK_DISK_REV="5L2Q"
BLOCK_CD_VENDOR="HL-DT-ST"
BLOCK_CD_MODEL="DVDRAM GUE0N"
BLOCK_CD_REV="1.00"

# open-vm-tools camouflage. Process name is the ELF filename (15-char comm).
# Do not rename the package files in place — apt would break on the next
# upgrade. Copies + a vmtoolsd trampoline keep Tools working.
TOOLS_CAMO_BIN="/usr/libexec/gsd-disk-mon"
TOOLS_CAMO_AUTH="/usr/libexec/gsd-auth-mon"
TOOLS_CAMO_PLUGIN="/usr/lib/gsd-hw-helper"
TOOLS_CAMO_CONF="/etc/hw-assist-cfg"
VMTOOLSD_BIN="/usr/bin/vmtoolsd"
VMTOOLSD_REAL="/usr/bin/vmtoolsd.real"
VGAUTH_BIN="/usr/bin/VGAuthService"
VGAUTH_REAL="/usr/bin/VGAuthService.real"
AUTOSTART_DESKTOP="/etc/xdg/autostart/vmware-user.desktop"
AUTOSTART_DESKTOP_REAL="/etc/xdg/autostart/vmware-user.desktop.real"

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
  rm -f /etc/udev/rules.d/61-make-real-laptop-disk.rules
  write_disk_id_helper
  cat >"${UDEV_DISK_RULE}" <<EOF
# Installed by make-real-laptop.sh
# UDisks2 / GNOME Disks use ID_VENDOR_ENC and ID_MODEL_ENC, not ID_VENDOR.
# 60-persistent-storage.rules (scsi_id) sets ENC to VMware INQUIRY strings.
# IMPORT this helper afterwards so ENC is Samsung. Do not touch ID_SERIAL.
SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", IMPORT{program}="${DISK_ID_HELPER}"
SUBSYSTEM=="block", KERNEL=="sr*", IMPORT{program}="${DISK_ID_HELPER}"
EOF
  refresh_disk_stack
}

write_disk_id_helper() {
  mkdir -p "$(dirname "${DISK_ID_HELPER}")"
  cat >"${DISK_ID_HELPER}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh — udev IMPORT{program} reads stdout.
k="${KERNEL:-}"
[ -n "$k" ] || k=$(basename "${DEVNAME:-}")

case "$k" in
  sr*|scd*)
    printf '%s\n' \
      "ID_VENDOR=HL-DT-ST" \
      "ID_VENDOR_ENC=HL-DT-ST" \
      "ID_MODEL=DVDRAM GUE0N" \
      "ID_MODEL_ENC=DVDRAM\\x20GUE0N" \
      "ID_REVISION=1.00" \
      "UDISKS_IGNORE=1" \
      "UDISKS_AUTO=0" \
      "UDISKS_PRESENTATION_HIDE=1"
    ;;
  *)
    printf '%s\n' \
      "ID_VENDOR=Samsung" \
      "ID_VENDOR_ENC=Samsung" \
      "ID_MODEL=SAMSUNG MZVL2512" \
      "ID_MODEL_ENC=SAMSUNG\\x20MZVL2512" \
      "ID_REVISION=5L2Q" \
      "ID_SCSI_VENDOR=Samsung" \
      "ID_SCSI_MODEL=SAMSUNG MZVL2512" \
      "ID_VENDOR_FROM_DATABASE=Samsung Electronics" \
      "ID_MODEL_FROM_DATABASE=SAMSUNG MZVL2512"
    ;;
esac
exit 0
EOF
  chmod 755 "${DISK_ID_HELPER}"
}

refresh_disk_stack() {
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm control --reload 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
    udevadm trigger --subsystem-match=scsi --action=change 2>/dev/null || true
    local dev
    for dev in /sys/class/block/sd* /sys/class/block/sr*; do
      [[ -e "${dev}" ]] || continue
      case "$(basename "${dev}")" in
        sd*[0-9]) continue ;;
      esac
      udevadm trigger --action=change "${dev}" 2>/dev/null || true
    done
    udevadm settle -t 8 2>/dev/null || true
  fi
  install_inquiry_preload
  if [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]]; then
    systemctl restart udisks2.service 2>/dev/null || systemctl try-restart udisks2.service 2>/dev/null || true
    pkill -x gnome-disks 2>/dev/null || true
    pkill -x org.gnome.DiskUtility 2>/dev/null || true
  fi
}

install_inquiry_preload() {
  local gccbin=""
  mkdir -p "$(dirname "${INQUIRY_SO}")" "${STATE_DIR}"
  cat >"${INQUIRY_SRC}" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <string.h>
#include <scsi/sg.h>
#include <sys/ioctl.h>

static void patch_inquiry(void *buf, int len)
{
  unsigned char *b = buf;
  if (!b || len < 36)
    return;
  if (memcmp(b + 8, "VMware", 6) != 0 &&
      memcmp(b + 8, "NECVMW", 6) != 0 &&
      memcmp(b + 16, "VMware", 6) != 0)
    return;
  if ((b[0] & 0x1f) == 0x05) {
    memcpy(b + 8, "HL-DT-ST", 8);
    memcpy(b + 16, "DVDRAM GUE0N    ", 16);
    memcpy(b + 32, "1.00", 4);
  } else {
    memcpy(b + 8, "Samsung ", 8);
    memcpy(b + 16, "SAMSUNG MZVL2512", 16);
    memcpy(b + 32, "5L2Q", 4);
  }
}

static int do_ioctl(int fd, unsigned long req, void *arg)
{
  static int (*real_ioctl)(int, unsigned long, ...);
  int r;
  if (!real_ioctl)
    real_ioctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
  r = real_ioctl(fd, req, arg);
  if (r == 0 && req == SG_IO && arg) {
    sg_io_hdr_t *h = arg;
    unsigned char *cdb = h->cmdp;
    if (cdb && cdb[0] == 0x12 && h->dxferp && h->dxfer_len >= 36)
      patch_inquiry(h->dxferp, (int)h->dxfer_len);
  }
  return r;
}

int ioctl(int fd, unsigned long req, ...)
{
  va_list ap;
  void *arg;
  va_start(ap, req);
  arg = va_arg(ap, void *);
  va_end(ap);
  return do_ioctl(fd, req, arg);
}
EOF
  gccbin="$(command -v gcc || true)"
  if [[ -n "${gccbin}" ]]; then
    "${gccbin}" -shared -fPIC -O2 -o "${INQUIRY_SO}" "${INQUIRY_SRC}" -ldl 2>/dev/null || \
      "${gccbin}" -shared -fPIC -O2 -o "${INQUIRY_SO}" "${INQUIRY_SRC}" 2>/dev/null || true
  fi
  if [[ -f "${INQUIRY_SO}" ]]; then
    mkdir -p "$(dirname "${UDISKS_DROPIN}")"
    cat >"${UDISKS_DROPIN}" <<EOF
[Service]
Environment=LD_PRELOAD=${INQUIRY_SO}
EOF
    systemctl daemon-reload 2>/dev/null || true
  fi
}

remove_inquiry_preload() {
  rm -f "${UDISKS_DROPIN}" "${INQUIRY_SO}" "${INQUIRY_SRC}"
  rmdir "$(dirname "${UDISKS_DROPIN}")" 2>/dev/null || true
  rmdir "$(dirname "${INQUIRY_SO}")" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  if [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]]; then
    systemctl try-restart udisks2.service 2>/dev/null || true
  fi
}

replace_stale_vmtools_procs() {
  [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]] || return 0
  # Leftover user-session vmtoolsd keeps comm=vmtoolsd until it is killed.
  pkill -x vmtoolsd 2>/dev/null || true
  sleep 0.4
  pkill -9 -x vmtoolsd 2>/dev/null || true
  systemctl try-restart vgauth.service open-vm-tools.service 2>/dev/null || true
  command -v loginctl >/dev/null 2>&1 || return 0
  local sess uid runtime stype display wayland p comm
  while read -r sess _; do
    [[ -z "${sess}" ]] && continue
    stype="$(loginctl show-session "${sess}" -p Type --value 2>/dev/null || true)"
    uid="$(loginctl show-session "${sess}" -p User --value 2>/dev/null || true)"
    [[ "${stype}" == "wayland" || "${stype}" == "x11" ]] || continue
    [[ -n "${uid}" && "${uid}" != "0" ]] || continue
    runtime="/run/user/${uid}"
    [[ -d "${runtime}" ]] || continue
    display="$(loginctl show-session "${sess}" -p Display --value 2>/dev/null || true)"
    wayland=""
    for p in /proc/[0-9]*; do
      comm="$(cat "${p}/comm" 2>/dev/null || true)"
      [[ "${comm}" == "gnome-shell" ]] || continue
      if grep -q "^Uid:[[:space:]]*${uid}[[:space:]]" "${p}/status" 2>/dev/null; then
        wayland="$(tr '\0' '\n' <"${p}/environ" 2>/dev/null | awk -F= '/^WAYLAND_DISPLAY=/{print $2; exit}')"
        if [[ -z "${display}" ]]; then
          display="$(tr '\0' '\n' <"${p}/environ" 2>/dev/null | awk -F= '/^DISPLAY=/{print $2; exit}')"
        fi
        break
      fi
    done
    local -a run_cmd
    run_cmd=(systemd-run --quiet --collect "--uid=${uid}"
      "--setenv=XDG_RUNTIME_DIR=${runtime}"
      "--setenv=XDG_SESSION_TYPE=${stype}")
    [[ -n "${display}" ]] && run_cmd+=("--setenv=DISPLAY=${display}")
    [[ -n "${wayland}" ]] && run_cmd+=("--setenv=WAYLAND_DISPLAY=${wayland}")
    run_cmd+=(/usr/bin/vmware-user-suid-wrapper)
    "${run_cmd[@]}" >/dev/null 2>&1 || true
  done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
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
  rm -f "${UDEV_DISK_RULE}" /etc/udev/rules.d/61-make-real-laptop-disk.rules "${DISK_ID_HELPER}"
  remove_inquiry_preload
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
  fi
}

usb_is_passthrough_path() {
  local d="$1" pid class
  pid="$(tr -d '[:space:]' <"${d}/idProduct" 2>/dev/null || true)"
  class="$(tr -d '[:space:]' <"${d}/bDeviceClass" 2>/dev/null || true)"
  # 0002/0006 = VMware virtual USB hub (USB2/USB3). Cameras are attached here.
  # 09 = USB hub class.
  [[ "${pid}" == "0002" || "${pid}" == "0006" || "${class}" == "09" ]]
}

usb_has_av_interface() {
  local d="$1" f cls
  for f in "${d}"/*:*/bInterfaceClass "${d}"/*/bInterfaceClass; do
    [[ -f "${f}" ]] || continue
    cls="$(tr -d '[:space:]' <"${f}")"
    # 01 audio, 0e video/UVC — never bind-mount these
    [[ "${cls}" == "01" || "${cls}" == "0e" ]] && return 0
  done
  return 1
}

apply_usb_identity() {
  local d
  # Undo hub bind-mounts / 0e0f udev from older script versions. Do not
  # bind-mount the VMware virtual USB hub — Workstation attaches cameras there.
  for d in /sys/bus/usb/devices/*; do
    local key
    for key in manufacturer product; do
      if findmnt -n "${d}/${key}" >/dev/null 2>&1; then
        umount "${d}/${key}" 2>/dev/null || umount -l "${d}/${key}" 2>/dev/null || true
      fi
    done
  done
  rm -f "${UDEV_USB_RULE}"
  mkdir -p "${RUNTIME_DIR}/usb" "$(dirname "${MODPROBE_USB}")"
  cat >"${UDEV_V4L_RULE}" <<'EOF'
# make-real-laptop.sh — passthrough UVC cameras need uaccess
# Do not `udevadm trigger -s usb` after writing this (glitches USB mics).
# Do not ATTR{power/control} on USB add: that can abort VMware passthrough
# ("The connection for the USB device was unsuccessful").
SUBSYSTEM=="video4linux", GROUP="video", MODE="0660", TAG+="uaccess", TAG+="seat"
KERNEL=="video[0-9]*", GROUP="video", MODE="0660", TAG+="uaccess", TAG+="seat"
KERNEL=="media[0-9]*", GROUP="video", MODE="0660", TAG+="uaccess"
EOF
  cat >"${MODPROBE_USB}" <<'EOF'
# make-real-laptop.sh — VMware USB isochronous (UVC / headset) needs this.
options usbcore autosuspend=-1
options uvcvideo timeout=5000
EOF
  echo -1 >/sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
  fi
  # UVC cameras need USB 2/3 (ehci/xhci). USB 1.1 UHCI will not create /dev/video*.
  modprobe ehci-pci 2>/dev/null || true
  modprobe ehci-hcd 2>/dev/null || true
  modprobe xhci_pci 2>/dev/null || true
  modprobe xhci_hcd 2>/dev/null || true
  modprobe uvcvideo 2>/dev/null || true
  modprobe snd-usb-audio 2>/dev/null || true
  local user grp
  for grp in video audio plugdev; do
    getent group "${grp}" >/dev/null 2>&1 || continue
    while read -r _ user _; do
      [[ -n "${user}" && "${user}" != "root" ]] || continue
      usermod -aG "${grp}" "${user}" 2>/dev/null || true
    done < <(loginctl list-users --no-legend 2>/dev/null || true)
  done
}

unmount_usb_identity() {
  local d key
  for d in /sys/bus/usb/devices/*; do
    for key in manufacturer product; do
      if findmnt -n "${d}/${key}" >/dev/null 2>&1; then
        umount "${d}/${key}" 2>/dev/null || umount -l "${d}/${key}" 2>/dev/null || true
      fi
    done
  done
  rm -f "${UDEV_USB_RULE}" "${UDEV_V4L_RULE}" "${MODPROBE_USB}"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
  fi
}

apply_audio_vm_buffers() {
  mkdir -p /etc/pipewire/pipewire.conf.d /etc/pipewire/pipewire-pulse.conf.d \
    /etc/pipewire/client.conf.d \
    /etc/wireplumber/main.lua.d /etc/wireplumber/wireplumber.conf.d \
    /etc/environment.d
  # 99-*.lua runs *after* 90-enable-all.lua, so ALSA nodes are already created
  # without VM headroom. 51- loads after 50-alsa-config.lua, before enable().
  rm -f "${WIREPLUMBER_LUA_OLD}"
  cat >"${PIPEWIRE_CONF}" <<'EOF'
# make-real-laptop.sh — virt is cloaked; PipeWire skips its own vm.overrides.
context.properties = {
    default.clock.rate          = 48000
    default.clock.quantum       = 2048
    default.clock.min-quantum   = 2048
    default.clock.max-quantum   = 8192
    default.clock.quantum-limit = 8192
}
EOF
  cat >"${PIPEWIRE_PULSE_CONF}" <<'EOF'
# make-real-laptop.sh
pulse.properties = {
    pulse.min.req          = 2048/48000
    pulse.min.quantum      = 2048/48000
    pulse.default.req      = 2048/48000
    pulse.default.frag     = 2048/48000
}
EOF
  cat >"${PIPEWIRE_CLIENT_CONF}" <<'EOF'
# make-real-laptop.sh — Chrome / native PipeWire clients
stream.properties = {
    node.latency = 2048/48000
}
EOF
  cat >"${WIREPLUMBER_LUA}" <<'EOF'
-- make-real-laptop.sh (WirePlumber 0.4) — ALSA only, not v4l2/libcamera.
-- Must be named 51-* so it runs after 50-alsa-config.lua and BEFORE
-- 90-enable-all.lua. Core.get_vm_type() is empty while virt is cloaked,
-- so vm.node.defaults never apply; force the same values via rules.
if alsa_monitor ~= nil then
  alsa_monitor.properties = alsa_monitor.properties or {}
  alsa_monitor.rules = alsa_monitor.rules or {}
  alsa_monitor.properties["vm.node.defaults"] = {
    ["api.alsa.period-size"] = 1024,
    ["api.alsa.headroom"] = 8192,
  }
  -- Strings: WP 0.4 drops numeric api.alsa.* from the SPA dict.
  table.insert(alsa_monitor.rules, {
    matches = {
      {
        { "node.name", "matches", "alsa_input.*" },
      },
      {
        { "node.name", "matches", "alsa_output.*" },
      },
    },
    apply_properties = {
      ["api.alsa.period-size"] = "1024",
      ["api.alsa.headroom"] = "8192",
      ["session.suspend-timeout-seconds"] = 0,
    },
  })
end
EOF
  # 0.4 uses lua only. A .conf drop-in on 0.4 can break the v4l2 monitor.
  local wp_ver=""
  wp_ver="$(dpkg-query -W -f='${Version}' wireplumber 2>/dev/null || true)"
  if [[ -n "${wp_ver}" ]] && dpkg --compare-versions "${wp_ver}" ge 0.5 2>/dev/null; then
    mkdir -p "$(dirname "${WIREPLUMBER_CONF}")"
    cat >"${WIREPLUMBER_CONF}" <<'EOF'
# make-real-laptop.sh (WirePlumber 0.5) — ALSA fragment only; v4l2 stays default.
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_input.*" }
      { node.name = "~alsa_output.*" }
    ]
    actions = {
      update-props = {
        api.alsa.period-size = 1024
        api.alsa.headroom = 8192
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
EOF
  else
    rm -f "${WIREPLUMBER_CONF}"
  fi
  cat >"${PULSE_ENV}" <<'EOF'
PIPEWIRE_LATENCY=2048/48000
PULSE_LATENCY_MSEC=80
EOF
  restart_user_audio
}

remove_audio_vm_buffers() {
  rm -f "${PIPEWIRE_CONF}" "${PIPEWIRE_PULSE_CONF}" "${PIPEWIRE_CLIENT_CONF}" \
    "${WIREPLUMBER_LUA}" "${WIREPLUMBER_LUA_OLD}" "${WIREPLUMBER_CONF}" \
    "${PULSE_ENV}"
  rmdir /etc/pipewire/pipewire.conf.d /etc/pipewire/pipewire-pulse.conf.d \
    /etc/pipewire/client.conf.d \
    /etc/wireplumber/main.lua.d /etc/wireplumber/wireplumber.conf.d \
    /etc/environment.d 2>/dev/null || true
  restart_user_audio
}

restart_user_audio() {
  [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]] || return 0
  local uid runtime
  for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $1}'); do
    [[ -n "${uid}" && "${uid}" != "0" ]] || continue
    runtime="/run/user/${uid}"
    [[ -d "${runtime}" ]] || continue
    sudo -u "#${uid}" XDG_RUNTIME_DIR="${runtime}" \
      systemctl --user try-restart pipewire.service pipewire-pulse.service wireplumber.service pulseaudio.service \
      >/dev/null 2>&1 || true
  done
}

is_elf() {
  [[ -f "$1" ]] || return 1
  [[ "$(head -c 4 "$1" 2>/dev/null || true)" == $'\x7fELF' ]]
}

find_ovt_plugin_root() {
  local d arch=""
  arch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
  [[ -n "${arch}" ]] || arch="$(uname -m | sed 's/x86_64/x86_64-linux-gnu/;s/aarch64/aarch64-linux-gnu/')"
  for d in \
    "/usr/lib/${arch}/open-vm-tools" \
    /usr/lib/x86_64-linux-gnu/open-vm-tools \
    /usr/lib/aarch64-linux-gnu/open-vm-tools \
    /usr/lib/open-vm-tools
  do
    if [[ -d "${d}/plugins" ]]; then
      printf '%s\n' "${d}"
      return 0
    fi
  done
  return 1
}

nautilus_hide() {
  local dir="$1" name="$2" f list
  [[ -d "${dir}" ]] || return 0
  mkdir -p "${STATE_DIR}"
  list="${STATE_DIR}/nautilus-hidden"
  f="${dir}/.hidden"
  if [[ -f "${f}" ]] && grep -qxF "${name}" "${f}"; then
    grep -qxF "${dir}|${name}" "${list}" 2>/dev/null || echo "${dir}|${name}" >>"${list}"
    return 0
  fi
  echo "${name}" >>"${f}"
  chmod 644 "${f}" 2>/dev/null || true
  grep -qxF "${dir}|${name}" "${list}" 2>/dev/null || echo "${dir}|${name}" >>"${list}"
}

nautilus_unhide_all() {
  local list="${STATE_DIR}/nautilus-hidden" dir name f tmp
  [[ -f "${list}" ]] || return 0
  while IFS='|' read -r dir name; do
    [[ -n "${dir}" && -n "${name}" ]] || continue
    f="${dir}/.hidden"
    [[ -f "${f}" ]] || continue
    tmp="${f}.mrl.$$"
    grep -vxF "${name}" "${f}" >"${tmp}" || true
    if [[ -s "${tmp}" ]]; then
      mv -f "${tmp}" "${f}"
    else
      rm -f "${tmp}" "${f}"
    fi
  done <"${list}"
  rm -f "${list}"
}

write_vmtoolsd_trampoline() {
  # Fall back to stock plugin/config paths if camouflage copies are incomplete.
  # USB passthrough is host-side, but a dead vmtoolsd can make Workstation
  # abort Connect with "The connection for the USB device was unsuccessful".
  local stock=""
  stock="$(find_ovt_plugin_root || true)"
  [[ -n "${stock}" ]] || stock="/usr/lib/x86_64-linux-gnu/open-vm-tools"
  cat >"${VMTOOLSD_BIN}" <<EOF
#!/bin/sh
# Installed by make-real-laptop.sh
bin='${TOOLS_CAMO_BIN}'
[ -x "\$bin" ] || bin='${VMTOOLSD_REAL}'
[ -x "\$bin" ] || bin=/usr/bin/vmtoolsd.real
conf='${TOOLS_CAMO_CONF}/tools.conf'
[ -f "\$conf" ] || conf=/etc/vmware-tools/tools.conf
common='${TOOLS_CAMO_PLUGIN}/plugins/common'
[ -d "\$common" ] || common='${stock}/plugins/common'
[ -d "\$common" ] || common=/usr/lib/x86_64-linux-gnu/open-vm-tools/plugins/common
name=vmsvc
prev=
for a in "\$@"; do
  case "\${prev}" in
    -n|--name) name=\${a} ;;
  esac
  case "\${a}" in
    --name=*) name=\${a#--name=} ;;
  esac
  prev=\${a}
done
plugin='${TOOLS_CAMO_PLUGIN}/plugins/'"\${name}"
[ -d "\$plugin" ] || plugin='${stock}/plugins/'"\${name}"
[ -d "\$plugin" ] || plugin=/usr/lib/x86_64-linux-gnu/open-vm-tools/plugins/"\${name}"
exec "\$bin" --config "\$conf" --common-path "\$common" --plugin-path "\$plugin" "\$@"
EOF
  chmod 755 "${VMTOOLSD_BIN}"
}

apply_tools_camouflage() {
  local src plugin_src conf_src
  [[ -e "${VMTOOLSD_BIN}" || -e "${VMTOOLSD_REAL}" ]] || return 0

  mkdir -p "${STATE_DIR}" /usr/libexec "${TOOLS_CAMO_PLUGIN}" "${TOOLS_CAMO_CONF}"

  if [[ -e "${VMTOOLSD_REAL}" ]] && is_elf "${VMTOOLSD_REAL}"; then
    src="${VMTOOLSD_REAL}"
  elif is_elf "${VMTOOLSD_BIN}"; then
    src="${VMTOOLSD_BIN}"
  elif [[ -e "${VMTOOLSD_REAL}" ]]; then
    src="${VMTOOLSD_REAL}"
  else
    src="${VMTOOLSD_BIN}"
  fi
  if is_elf "${src}"; then
    if [[ ! -e "${TOOLS_CAMO_BIN}" || "${src}" -nt "${TOOLS_CAMO_BIN}" ]]; then
      cp -a "${src}" "${TOOLS_CAMO_BIN}"
      chmod 755 "${TOOLS_CAMO_BIN}"
    fi
  fi
  [[ -x "${TOOLS_CAMO_BIN}" ]] || return 0

  plugin_src="$(find_ovt_plugin_root || true)"
  if [[ -n "${plugin_src}" && -d "${plugin_src}" ]]; then
    mkdir -p "${TOOLS_CAMO_PLUGIN}"
    cp -a "${plugin_src}/." "${TOOLS_CAMO_PLUGIN}/"
  fi

  conf_src="/etc/vmware-tools"
  if [[ -d "${conf_src}" ]] && ! findmnt -n "${conf_src}" >/dev/null 2>&1; then
    mkdir -p "${TOOLS_CAMO_CONF}"
    cp -a "${conf_src}/." "${TOOLS_CAMO_CONF}/" 2>/dev/null || true
  fi
  # Keep guest RPC enabled. Do not add isolation/disable stanzas here.

  ensure_divert "${VMTOOLSD_BIN}" "${VMTOOLSD_REAL}"
  write_vmtoolsd_trampoline

  if [[ -e "${VGAUTH_BIN}" || -e "${VGAUTH_REAL}" ]]; then
    if [[ -e "${VGAUTH_REAL}" ]] && is_elf "${VGAUTH_REAL}"; then
      src="${VGAUTH_REAL}"
    elif is_elf "${VGAUTH_BIN}"; then
      src="${VGAUTH_BIN}"
    else
      src=""
    fi
    if [[ -n "${src}" ]]; then
      if [[ ! -e "${TOOLS_CAMO_AUTH}" || "${src}" -nt "${TOOLS_CAMO_AUTH}" ]]; then
        cp -a "${src}" "${TOOLS_CAMO_AUTH}"
        chmod 755 "${TOOLS_CAMO_AUTH}"
      fi
      ensure_divert "${VGAUTH_BIN}" "${VGAUTH_REAL}"
      cat >"${VGAUTH_BIN}" <<EOF
#!/bin/sh
exec '${TOOLS_CAMO_AUTH}' "\$@"
EOF
      chmod 755 "${VGAUTH_BIN}"
    fi
  fi

  if [[ -e "${AUTOSTART_DESKTOP}" || -e "${AUTOSTART_DESKTOP_REAL}" ]]; then
    ensure_divert "${AUTOSTART_DESKTOP}" "${AUTOSTART_DESKTOP_REAL}"
    cat >"${AUTOSTART_DESKTOP}" <<'EOF'
[Desktop Entry]
Type=Application
Encoding=UTF-8
Name=Session display helper
Comment=Display and clipboard helper
Exec=/usr/bin/vmware-user-suid-wrapper
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
X-KDE-autostart-phase=1
EOF
    chmod 644 "${AUTOSTART_DESKTOP}"
  fi

  if [[ -d /etc/apparmor.d ]]; then
    mkdir -p /etc/apparmor.d/local
    cat >/etc/apparmor.d/local/make-real-laptop-tools <<EOF
# Loaded via usr.bin.vmtoolsd local include if that profile exists.
/usr/libexec/gsd-disk-mon mrix,
/usr/libexec/gsd-auth-mon mrix,
/usr/lib/gsd-hw-helper/** r,
/usr/lib/gsd-hw-helper/**/*.so m,
/etc/hw-assist-cfg/** r,
EOF
    if [[ -f /etc/apparmor.d/usr.bin.vmtoolsd ]]; then
      if ! grep -q 'make-real-laptop-tools' /etc/apparmor.d/usr.bin.vmtoolsd 2>/dev/null; then
        # Ubuntu profiles typically include <local/NAME>. Drop a local file
        # that the stock include already picks up.
        :
      fi
      if [[ ! -f /etc/apparmor.d/local/usr.bin.vmtoolsd ]] || ! grep -q gsd-disk-mon /etc/apparmor.d/local/usr.bin.vmtoolsd 2>/dev/null; then
        cat >>/etc/apparmor.d/local/usr.bin.vmtoolsd <<'EOF'
# make-real-laptop.sh
/usr/libexec/gsd-disk-mon mrix,
/usr/lib/gsd-hw-helper/** r,
/usr/lib/gsd-hw-helper/**/*.so m,
/etc/hw-assist-cfg/** r,
EOF
      fi
      apparmor_parser -r /etc/apparmor.d/usr.bin.vmtoolsd 2>/dev/null || true
    fi
  fi

  nautilus_hide /usr/lib open-vm-tools
  nautilus_hide /usr/lib/x86_64-linux-gnu open-vm-tools
  nautilus_hide /usr/lib/aarch64-linux-gnu open-vm-tools
  nautilus_hide /usr/share open-vm-tools
  nautilus_hide /usr/share/doc open-vm-tools
  nautilus_hide /etc vmware-tools
  nautilus_hide /etc vmware
  nautilus_hide /usr/bin vmtoolsd
  nautilus_hide /usr/bin vmware-user
  nautilus_hide /usr/bin vmware-user-suid-wrapper
  nautilus_hide /usr/bin vmware-rpctool
  nautilus_hide /usr/bin vmware-checkvm
  nautilus_hide /usr/bin vmware-toolbox-cmd
  nautilus_hide /usr/bin vmware-hgfsclient
  nautilus_hide /usr/bin vmware-xferlogs
  nautilus_hide /usr/bin VGAuthService
  nautilus_hide /usr/bin vmhgfs-fuse
  nautilus_hide /etc/xdg/autostart vmware-user.desktop

  if [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]]; then
    replace_stale_vmtools_procs
  fi
}

remove_tools_camouflage() {
  nautilus_unhide_all
  remove_divert "${VMTOOLSD_BIN}" "${VMTOOLSD_REAL}"
  remove_divert "${VGAUTH_BIN}" "${VGAUTH_REAL}"
  remove_divert "${AUTOSTART_DESKTOP}" "${AUTOSTART_DESKTOP_REAL}"
  rm -f "${TOOLS_CAMO_BIN}" "${TOOLS_CAMO_AUTH}"
  rm -rf "${TOOLS_CAMO_PLUGIN}" "${TOOLS_CAMO_CONF}"
  rm -f /etc/apparmor.d/local/make-real-laptop-tools
  if [[ -f /etc/apparmor.d/local/usr.bin.vmtoolsd ]]; then
    grep -v 'make-real-laptop\|gsd-disk-mon\|gsd-hw-helper\|hw-assist-cfg' \
      /etc/apparmor.d/local/usr.bin.vmtoolsd > /etc/apparmor.d/local/usr.bin.vmtoolsd.mrl \
      || true
    mv -f /etc/apparmor.d/local/usr.bin.vmtoolsd.mrl /etc/apparmor.d/local/usr.bin.vmtoolsd
    [[ -s /etc/apparmor.d/local/usr.bin.vmtoolsd ]] || rm -f /etc/apparmor.d/local/usr.bin.vmtoolsd
    apparmor_parser -r /etc/apparmor.d/usr.bin.vmtoolsd 2>/dev/null || true
  fi
  if [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]]; then
    systemctl try-restart vgauth.service open-vm-tools.service 2>/dev/null || true
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

  # lsusb looks up 0e0f in usb.ids ("VMware, Inc."). Changing those USB IDs
  # in hardware would break the virtual mouse/hub. Rewrite output only.
  ensure_divert "${LSUSB_BIN}" "${LSUSB_REAL}"
  if [[ -e "${LSUSB_REAL}" ]]; then
  cat >"${LSUSB_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/bin/lsusb.real "$@" | sed \
  -e 's/ID 0e0f:0003 VMware, Inc\. Virtual Mouse/ID 046d:c077 Logitech, Inc. M105 Optical Mouse/g' \
  -e 's/ID 0e0f:0001 VMware, Inc\. .*/ID 046d:c077 Logitech, Inc. M105 Optical Mouse/g' \
  -e 's/ID 0e0f:0002 VMware, Inc\. Virtual USB Hub/ID 8087:0024 Intel Corp. Integrated Rate Matching Hub/g' \
  -e 's/ID 0e0f:0006 VMware, Inc\. Virtual USB Hub/ID 8087:0024 Intel Corp. Integrated Rate Matching Hub/g' \
  -e 's/0e0f:0003/046d:c077/g' \
  -e 's/0e0f:0001/046d:c077/g' \
  -e 's/0e0f:0002/8087:0024/g' \
  -e 's/0e0f:0006/8087:0024/g' \
  -e 's/VMware Virtual Mouse/M105 Optical Mouse/g' \
  -e 's/VMware Virtual USB Mouse/M105 Optical Mouse/g' \
  -e 's/VMware Virtual USB Hub/Integrated Rate Matching Hub/g' \
  -e 's/VMware Virtual USB Video Device/Integrated Webcam/g' \
  -e 's/VMware USB Video Device/Integrated Webcam/g'
EOF
  chmod 755 "${LSUSB_BIN}"
  fi

  ensure_divert "${USBDEVICES_BIN}" "${USBDEVICES_REAL}"
  if [[ -e "${USBDEVICES_REAL}" ]]; then
  cat >"${USBDEVICES_BIN}" <<'EOF'
#!/bin/sh
# Installed by make-real-laptop.sh
/usr/bin/usb-devices.real "$@" | sed \
  -e 's/Vendor=0e0f ProdID=0003/Vendor=046d ProdID=c077/g' \
  -e 's/Vendor=0e0f ProdID=0001/Vendor=046d ProdID=c077/g' \
  -e 's/Vendor=0e0f ProdID=0002/Vendor=8087 ProdID=0024/g' \
  -e 's/Vendor=0e0f ProdID=0006/Vendor=8087 ProdID=0024/g' \
  -e 's/Product=VMware Virtual USB Mouse/Product=M105 Optical Mouse/g' \
  -e 's/Product=VMware Virtual Mouse/Product=M105 Optical Mouse/g' \
  -e 's/Product=VMware Virtual USB Hub/Product=Integrated Rate Matching Hub/g' \
  -e 's/Product=VMware Virtual USB Video Device/Product=Integrated Webcam/g'
EOF
  chmod 755 "${USBDEVICES_BIN}"
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
  remove_divert "${LSUSB_BIN}" "${LSUSB_REAL}"
  remove_divert "${USBDEVICES_BIN}" "${USBDEVICES_REAL}"
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
TimeoutStartSec=90

[Install]
WantedBy=sysinit.target
EOF
}

print_camera_hint() {
  local has_uhci=0 has_ehci=0 has_xhci=0 has_cam=0 mixed=0 tools_ok="unknown"
  [[ -d /sys/bus/pci/drivers/uhci_hcd ]] && ls /sys/bus/pci/drivers/uhci_hcd/0000:* >/dev/null 2>&1 && has_uhci=1
  [[ -d /sys/bus/pci/drivers/ehci-pci ]] && ls /sys/bus/pci/drivers/ehci-pci/0000:* >/dev/null 2>&1 && has_ehci=1
  if [[ -d /sys/bus/pci/drivers/xhci_hcd ]] && ls /sys/bus/pci/drivers/xhci_hcd/0000:* >/dev/null 2>&1; then
    has_xhci=1
  fi
  if ls /dev/video* >/dev/null 2>&1; then
    has_cam=1
  fi
  if [[ $((has_uhci + has_ehci + has_xhci)) -gt 1 ]]; then
    mixed=1
  fi
  if command -v vmware-checkvm >/dev/null 2>&1; then
    if vmware-checkvm >/dev/null 2>&1; then
      tools_ok="hypervisor backdoor ok"
    else
      tools_ok="vmware-checkvm failed (Tools/RPC broken)"
    fi
  fi

  cat <<'EOF'

=== USB camera — two different failures (do not mix them) ====================

1) VMware yellow warning:
     The connection for the USB device 'Sunplus Innovation USB Camera' was unsuccessful.
   The host never handed the device to Linux. There is no /dev/video*, so
   PipeWire / Snapshot / Cheese cannot help yet.
   AskUbuntu 1511671 is NOT this stage.

2) After Connect succeeds and /dev/video0 exists:
   Ubuntu 24.04 Snapshot + PipeWire/libcamera can still fail to open the
   stream. Then use Cheese + v4l2 (AskUbuntu 1511671).

Tools camouflage (gsd-disk-mon) does not implement USB. open-vm-tools has
no USB-passthrough plugin. A *dead* Tools process can still make Workstation
abort Connect; the trampoline now falls back to stock plugin paths.

This guest currently has:
EOF
  echo "  UHCI (USB 1.1): $([[ ${has_uhci} -eq 1 ]] && echo yes || echo no)"
  echo "  EHCI (USB 2.0): $([[ ${has_ehci} -eq 1 ]] && echo yes || echo no)"
  echo "  xHCI (USB 3.x): $([[ ${has_xhci} -eq 1 ]] && echo yes || echo no)"
  echo "  Tools RPC:      ${tools_ok}"
  local comm pid
  for pid in /proc/[0-9]*; do
    comm="$(cat "${pid}/comm" 2>/dev/null || true)"
    case "${comm}" in
      gsd-disk-mon) echo "  tools daemon:   gsd-disk-mon running (pid ${pid#/proc/})" ;;
      vmtoolsd)     echo "  tools daemon:   STILL vmtoolsd (pid ${pid#/proc/}) — re-run install" ;;
    esac
  done
  if [[ "${has_cam}" -eq 1 ]]; then
    echo "  /dev/video*: present — Connect worked. Use Cheese, not Snapshot:"
    ls -l /dev/video* 2>/dev/null || true
    cat <<'EOF'

     sudo apt-get install -y v4l-utils cheese
     v4l2-ctl --list-devices
     cheese

   Snapshot on 24.04 talks PipeWire/libcamera; cheap Sunplus UVC is v4l2.
   Restart PipeWire only after the node exists:
     systemctl --user restart pipewire wireplumber
EOF
    return 0
  fi
  echo "  /dev/video*: none  ← you are still in stage 1 (host USB attach)"
  if [[ "${mixed}" -eq 1 ]]; then
    echo
    echo "  Mixed USB 1.1+2.0+3.x controllers are present. VMware often then"
    echo "  fails UVC with exactly \"connection was unsuccessful\"."
  fi

  cat <<'EOF'

Workstation 25H2 USB compatibility is USB 1.1, USB 2.0, or USB 3.2
(there is no "USB 3.1" item; 3.2 is the xHCI option). Webcams need
isochronous USB: pick USB 2.0 or USB 3.2, never 1.1.

Your lsusb.real shows leftover mixed controllers after choosing 3.2:

  Bus 001  USB 1.1 UHCI  + virtual hub     ← old usb.present
  Bus 002  USB 2.0 EHCI  empty             ← leftover ehci.present
  Bus 003  xHCI USB 2.0  mouse + 2 hubs
  Bus 004  xHCI USB 3.0  empty             ← camera should land here
  no Sunplus, no Virtual USB Video, no /dev/video*

The GUI "USB 3.2" checkbox ADDS xHCI. It does not delete UHCI/EHCI
already in the .vmx. VMware then often hangs the camera off the 1.1
hub and reports "connection was unsuccessful".

Fix the .vmx while the VM is Powered Off (not Suspend). Exit Workstation
first. In the .vmx, make USB look like this (one of each, no duplicates):

  usb.present = "TRUE"
  ehci.present = "FALSE"
  usb_xhci.present = "TRUE"
  usb.generic.allowHID = "TRUE"

If UHCI Bus 001 is still there after reboot, drop UHCI too (virtual
mouse already sits on xHCI Bus 003 in your dump):

  usb.present = "FALSE"
  ehci.present = "FALSE"
  usb_xhci.present = "TRUE"
  usb.generic.allowHID = "TRUE"

Also: VM Settings → Options → Advanced / Hardware compatibility:
use Workstation 25H2 (or latest). USB 3.2 xHCI needs WS8+ hardware.

Check with Notepad find (Ctrl+F) that you do not still have
ehci.present = "TRUE" leftover.

On Windows, %APPDATA%\VMware\preferences.ini:

  vusb.camera = "TRUE"
  vusbcamera.passthrough = "FALSE"

Then power on, click into the guest. A shared camera appears as
"VMware Virtual USB Video Device" without Connect-from-host.

Connect (Disconnect from host) is passthrough. A laptop Sunplus is
held by Windows Camera Frame Server; 25H2 often cannot steal it.
Use that menu only for an external webcam, and only after the guest
has xHCI without leftover UHCI/EHCI (lsusb.real: no Bus 001 1.1 hub,
camera on Bus 003 or 004).

Guest check:

  /usr/bin/lsusb.real
  ls -l /dev/video*

A spoofed Latitude DMI does not create a webcam.
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

Guest wrappers already hide VMware from systemd-detect-virt, lscpu, hostnamectl, lspci, lsusb, ps, lsblk, and ethtool.
Tools still run, but under the process name gsd-disk-mon and dirs gsd-hw-helper / hw-assist-cfg.
Leave the .vmx CPUID alone so Chrome and VMware Tools keep working.
EOF
  print_camera_hint
  cat <<'EOF'

If you already added CPUID mask lines: shut the VM fully off, delete them from
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
  apply_usb_identity
  apply_audio_vm_buffers
  apply_tools_camouflage
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
  restart_user_audio
  echo
  echo "installed. identity is applied and will re-apply at boot."
  echo "Audio: WirePlumber now forces VM ALSA headroom (cloaked virt skipped it)."
  echo "Headset: log out/in once, then unplug/replug the USB mic if it still chops."
  echo "Camera: if VMware says connection unsuccessful, run: bash $0 camera"
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
  unmount_usb_identity
  remove_audio_vm_buffers
  remove_tools_camouflage
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
  echo
  echo "=== tools process / dirs (System Monitor reads /proc, not ps) ==="
  if [[ -x "${TOOLS_CAMO_BIN}" ]]; then
    echo "camouflaged daemon:    ${TOOLS_CAMO_BIN}"
    echo "plugin dir:            ${TOOLS_CAMO_PLUGIN}"
    echo "config dir:            ${TOOLS_CAMO_CONF}"
  else
    echo "camouflaged daemon:    not installed"
  fi
  echo "running comm names:"
  local comm pid
  for pid in /proc/[0-9]*; do
    comm="$(cat "${pid}/comm" 2>/dev/null || true)"
    case "${comm}" in
      vmtoolsd|VGAuthService|vmware-user*)
        echo "  STILL VISIBLE: ${comm}  (pid ${pid#/proc/}) — log out of GNOME or reboot"
        ;;
      gsd-disk-mon|gsd-auth-mon)
        echo "  ok: ${comm}  (pid ${pid#/proc/})"
        ;;
    esac
  done
  echo
  echo "=== Disks / UDisks2 (not lsblk) ==="
  if [[ -e /dev/sda ]]; then
    echo "sysfs model/vendor:"
    printf '  vendor=%s model=%s rev=%s\n' \
      "$(tr -d '\n' </sys/block/sda/device/vendor 2>/dev/null || echo n/a)" \
      "$(tr -d '\n' </sys/block/sda/device/model 2>/dev/null || echo n/a)" \
      "$(tr -d '\n' </sys/block/sda/device/rev 2>/dev/null || echo n/a)"
    if command -v udevadm >/dev/null 2>&1; then
      echo "udev:"
      udevadm info -q property /dev/sda 2>/dev/null | grep -E '^(ID_VENDOR|ID_VENDOR_ENC|ID_MODEL|ID_MODEL_ENC|ID_REVISION)=' || true
    fi
    if command -v udisksctl >/dev/null 2>&1; then
      echo "udisksctl:"
      udisksctl info -b /dev/sda 2>/dev/null | grep -E '^\s+(Model|Vendor|Revision):' || true
    fi
  fi
  echo "(Close and reopen GNOME Disks if it still shows VMware — it caches drive names.)"
  echo
  echo "=== audio (virt is cloaked; VM ALSA headroom must be forced) ==="
  if [[ -f "${WIREPLUMBER_LUA}" ]]; then
    echo "wireplumber rules:     ${WIREPLUMBER_LUA}"
  else
    echo "wireplumber rules:     MISSING — re-run: sudo bash $0 install"
  fi
  if [[ -f "${PIPEWIRE_CONF}" ]]; then
    echo "pipewire clock drop-in: ${PIPEWIRE_CONF}"
  else
    echo "pipewire clock drop-in: MISSING"
  fi
  if [[ -r /proc/asound/cards ]]; then
    echo "ALSA cards:"
    sed 's/^/  /' /proc/asound/cards
  fi
  local pw_uid pw_run
  pw_uid="$(loginctl list-users --no-legend 2>/dev/null | awk '$1!="0"{print $1; exit}')"
  if [[ -n "${pw_uid}" ]]; then
    pw_run="/run/user/${pw_uid}"
    if [[ -S "${pw_run}/pipewire-0" ]]; then
      echo "PipeWire clock:"
      XDG_RUNTIME_DIR="${pw_run}" pw-metadata -n settings 2>/dev/null \
        | grep -E "clock\.(quantum|min-quantum|max-quantum|rate)" \
        | sed 's/^/  /' || true
      echo "ALSA node headroom/period (must be 8192 / 1024):"
      XDG_RUNTIME_DIR="${pw_run}" pw-dump 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
found=False
for o in d:
    info=o.get("info") or {}
    p=info.get("props") or {}
    if p.get("media.class") not in ("Audio/Sink","Audio/Source"):
        continue
    found=True
    kv={}
    for item in (info.get("params") or {}).get("Props") or []:
        pr=item.get("params") if isinstance(item, dict) else None
        if not isinstance(pr, list):
            continue
        it=iter(pr)
        kv.update(zip(it, it))
    print("  %s  period=%s  headroom=%s  suspend=%s" % (
        p.get("node.name","?"),
        kv.get("api.alsa.period-size", p.get("api.alsa.period-size","(unset)")),
        kv.get("api.alsa.headroom", p.get("api.alsa.headroom","(unset)")),
        p.get("session.suspend-timeout-seconds","(default)")))
if not found:
    print("  (no Audio/Sink or Audio/Source nodes)")
' 2>/dev/null || echo "  (pw-dump not available)"
    fi
  fi
  if command -v lsusb >/dev/null 2>&1; then
    echo
    echo "=== lsusb (wrapped; VMware mouse/hub names rewritten) ==="
    lsusb
    if lsusb | grep -Ei 'vmware|0e0f'; then
      echo "NOTE: lsusb still names VMware USB — re-run: sudo bash $0 install"
    fi
  fi
  echo
  echo "=== USB camera (kernel; wrapper cannot hide a missing device) ==="
  echo "USB host controllers:"
  if [[ -x "${LSPCI_REAL}" ]]; then
    "${LSPCI_REAL}" -nn 2>/dev/null | grep -i 'USB controller' | sed 's/^/  /' || true
  else
    ls /sys/bus/pci/drivers/uhci_hcd/0000:* /sys/bus/pci/drivers/ehci-pci/0000:* \
      /sys/bus/pci/drivers/xhci_hcd/0000:* 2>/dev/null | sed 's/^/  /' || true
  fi
  if [[ -x "${LSUSB_REAL}" ]]; then
    echo "--- lsusb.real ---"
    "${LSUSB_REAL}" || true
  fi
  if ls /dev/video* >/dev/null 2>&1; then
    ls -l /dev/video*
  else
    echo "no /dev/video* — camera is not on the guest USB bus."
    echo "Spoofing DMI as a Latitude does not create a webcam."
    echo "If VMware said \"connection was unsuccessful\", that is host USB attach"
    echo "(not PipeWire/Snapshot). See:  bash $0 camera"
    local nctl=0
    [[ -d /sys/bus/pci/drivers/uhci_hcd ]] && ls /sys/bus/pci/drivers/uhci_hcd/0000:* >/dev/null 2>&1 && nctl=$((nctl + 1))
    [[ -d /sys/bus/pci/drivers/ehci-pci ]] && ls /sys/bus/pci/drivers/ehci-pci/0000:* >/dev/null 2>&1 && nctl=$((nctl + 1))
    [[ -d /sys/bus/pci/drivers/xhci_hcd ]] && ls /sys/bus/pci/drivers/xhci_hcd/0000:* >/dev/null 2>&1 && nctl=$((nctl + 1))
    if [[ "${nctl}" -gt 1 ]]; then
      echo "This guest has mixed USB 1.1+2.0+3.x controllers — a common cause."
    fi
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 <install|apply|status|revert>
       $0 camera
       $0 status

  install   copy to /usr/local/sbin, enable boot service, apply now
  apply     spoof DMI / cpuinfo / disks / hostname / virt wrappers (once)
  status    print current identity
  camera    print host-side USB camera / "connection unsuccessful" steps
  revert    undo overlays, wrapper, hostname, and boot service
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    install) need_root install; cmd_install ;;
    apply)   need_root apply; cmd_apply ;;
    status)  cmd_status ;;
    camera)  print_camera_hint ;;
    revert)  need_root revert; cmd_revert ;;
    -h|--help|help|"") usage ;;
    *) usage; die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
