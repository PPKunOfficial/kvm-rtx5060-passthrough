#!/usr/bin/env bash
# 15-usb-controller-bind.sh
#
# 运行时把后置 USB-C 的 xHCI 控制器 (0000:06:00.3) 从内置的 xhci_pci 交给
# vfio-pci，供 win11 直通使用。
#
# 为什么不能用 GRUB 的 vfio-pci.ids=：
#   本机 CONFIG_USB_XHCI_PCI=y（内置），内核对 PCI 设备枚举时就把控制器绑给了
#   xhci_pci，vfio-pci 在 initramfs 里再加载已经晚了。所以必须运行时解绑。
#
# 为什么必须先拔掉扩展坞：
#   该控制器 reset_method 只有 "pm"，实测在 USB-C 扩展坞（带 DP alt-mode
#   billboard）挂着时解绑 xhci 会把内核挂死、整机重启。有设备挂着时本脚本会
#   直接拒绝执行。
#
# 用法：
#   sudo bash 15-usb-controller-bind.sh status   # 看当前绑定和挂在上面的设备
#   sudo bash 15-usb-controller-bind.sh bind     # 交给 vfio（坞必须先拔掉）
#   sudo bash 15-usb-controller-bind.sh unbind   # 还给 Linux 的 xhci
#
# 典型流程：
#   1) 拔掉后置 USB-C 上的扩展坞
#   2) sudo bash 15-usb-controller-bind.sh bind
#   3) virsh start win11
#   4) 把扩展坞插回去 —— Windows 里会直接认出来
set -euo pipefail

PCI_ADDR=0000:06:00.3
DOM=win11
CONN=qemu:///system
XHCI_DRV=/sys/bus/pci/drivers/xhci_hcd
VFIO_DRV=/sys/bus/pci/drivers/vfio-pci

ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [警告] %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

cur_driver() { readlink -f "/sys/bus/pci/devices/$PCI_ADDR/driver" 2>/dev/null | sed 's#.*/##'; }

attached_devices() {
    local d path
    for d in /sys/bus/usb/devices/*-*; do
        [[ -f $d/idVendor ]] || continue
        path=$(readlink -f "$d")
        if [[ $path == *"$PCI_ADDR"* ]]; then
            printf '    %s  %s:%s  %s\n' "$(basename "$d")" \
                "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" \
                "$(cat "$d/product" 2>/dev/null)"
        fi
    done
}

vm_running() { [[ $(virsh -c "$CONN" domstate "$DOM" 2>/dev/null || true) == 运行 ]]; }

case "${1:-status}" in
status)
    echo "=== 控制器绑定 ==="
    echo "  $PCI_ADDR -> $(cur_driver || echo 未绑定)"
    echo "  driver_override = $(cat /sys/bus/pci/devices/$PCI_ADDR/driver_override 2>/dev/null || echo '(null)')"
    echo "  $DOM: $(virsh -c "$CONN" domstate "$DOM" 2>/dev/null || echo 未知)"
    echo
    echo "=== 挂在该控制器上的 USB 设备 ==="
    attached_devices || true
    echo
    if [[ -n $(attached_devices) ]]; then
        echo "  → 有设备挂着：此时 bind 会被拒绝（会挂死内核）"
    else
        echo "  → 空的，可以安全 bind"
    fi
    ;;
bind)
    [[ ${EUID} -eq 0 ]] || exec sudo -- "$0" "$@"
    [[ -e /sys/bus/pci/devices/$PCI_ADDR ]] || die "找不到 $PCI_ADDR"
    vm_running && die "$DOM 正在运行，先关机"
    drv=$(cur_driver || true)
    if [[ $drv == vfio-pci ]]; then
        ok "已经在 vfio-pci 上，无需操作"
        exit 0
    fi
    [[ -z $drv || $drv == xhci_hcd ]] || die "当前驱动是 $drv，不认识这个状态"

    devs=$(attached_devices || true)
    if [[ -n $devs ]]; then
        printf '%s\n' "$devs"
        die "控制器上还挂着 USB 设备。请先物理拔掉后置 USB-C 上的扩展坞再重跑。"
    fi

    echo '== 解绑 xhci -> 绑定 vfio-pci =='
    echo vfio-pci > "/sys/bus/pci/devices/$PCI_ADDR/driver_override"
    if [[ $drv == xhci_hcd ]]; then
        echo "$PCI_ADDR" > "$XHCI_DRV/unbind" || die "从 xhci 解绑失败"
        ok '已从 xhci_hcd 解绑'
    fi
    echo "$PCI_ADDR" > "$VFIO_DRV/bind" || die "绑定 vfio-pci 失败"
    sleep 1
    [[ $(cur_driver) == vfio-pci ]] && ok "现在绑定：vfio-pci" || die "绑定后状态异常：$(cur_driver || echo 无)"
    echo
    echo '现在可以启动 VM：virsh start win11'
    echo '启动后再把扩展坞插回去，Windows 会热插拔识别。'
    ;;
unbind)
    [[ ${EUID} -eq 0 ]] || exec sudo -- "$0" "$@"
    vm_running && die "$DOM 正在运行，先关机"
    [[ $(cur_driver) == vfio-pci ]] || { ok '不在 vfio-pci 上，无需操作'; exit 0; }
    echo '== vfio-pci -> xhci_hcd =='
    echo "$PCI_ADDR" > "$VFIO_DRV/unbind" || die '从 vfio 解绑失败'
    : > "/sys/bus/pci/devices/$PCI_ADDR/driver_override" 2>/dev/null || true
    echo "$PCI_ADDR" > "$XHCI_DRV/bind" || die '重新绑定 xhci 失败（可能需要重启）'
    sleep 1
    [[ $(cur_driver) == xhci_hcd ]] && ok "现在绑定：xhci_hcd" || warn "当前：$(cur_driver || echo 无)"
    ;;
-h|--help|help)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    ;;
*)
    die "未知参数：${1}（status|bind|unbind）"
    ;;
esac
