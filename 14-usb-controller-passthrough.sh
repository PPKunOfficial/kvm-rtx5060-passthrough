#!/usr/bin/env bash
# 14-usb-controller-passthrough.sh
#
# 把后置 USB-C 的 xHCI 控制器整机直通给 win11。
#
# 为什么不走 libvirt 的 managed='yes'：
#   0000:06:00.3 的 reset_method 只有 "pm"（无 flr/bus），managed='yes' 会先把
#   xhci_hcd 从控制器上解绑；扩展坞（USB-C，带 DP alt-mode billboard）挂着时
#   解绑会让内核挂死，实测直接整机重启。所以改成在 GRUB 直通启动项里用
#   vfio-pci.ids=1022:15b6 在开机时就接管，虚拟机启动阶段不需要任何解绑/复位，
#   域定义里用 managed='no'，万一没预绑定只会干净地启动失败，不会挂内核。
#
# 代价（直通模式启动时）：
#   - 该控制器上的所有设备都归 Windows：后置 USB-C 口及其扩展坞，
#     以及同控制器另一个口上的设备（当前是 MOONDROP 解码器）。
#   - 想还给 Linux：跑本脚本 disable 并重启，或用 vfio-boot-mode host 启动。
#
# 用法：
#   sudo bash 14-usb-controller-passthrough.sh enable    # 配置并提示重启
#   sudo bash 14-usb-controller-passthrough.sh disable   # 撤销
#   sudo bash 14-usb-controller-passthrough.sh status    # 查看
set -euo pipefail

[[ ${EUID} -eq 0 ]] || exec sudo -- "$0" "$@"

PCI_ADDR=0000:06:00.3
PCI_ID=1022:15b6
GPU_ID=10de:2d19
GRUB_FILES=(/etc/default/grub /etc/grub.d/40_custom)
GRUB_CFG=/boot/grub/grub.cfg
DOM=win11
CONN=qemu:///system

ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [警告] %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

grub_patch() { # $1 = add|remove
    local mode=$1 f changed=0
    for f in "${GRUB_FILES[@]}"; do
        [[ -f $f ]] || continue
        local before after
        before=$(cat "$f")
        python3 - "$f" "$mode" "$PCI_ID" "$GPU_ID" <<'PY'
import re, sys
path, mode, pci_id, gpu_id = sys.argv[1:5]
s = open(path).read()

def patch(m):
    quoted, bare = m.group(1), m.group(2)
    ids = quoted if quoted is not None else bare
    parts = [p for p in ids.split(',') if p]
    if mode == 'add':
        if pci_id in parts:
            return m.group(0)
        parts.append(pci_id)
    else:
        parts = [p for p in parts if p != pci_id]
    new = ','.join(parts)
    return "vfio-pci.ids=" + ("'%s'" % new if quoted is not None else new)

# 只改本来就带 GPU 直通 id 的项；引号形式和无引号形式都覆盖
s = re.sub(r"vfio-pci\.ids=(?:'([^']*)'|([^\s'\"]+))", patch, s)
open(path, 'w').write(s)
PY
        after=$(cat "$f")
        if [[ $before != "$after" ]]; then
            printf '  %s: 已更新\n' "$f"
            changed=1
            grep -n 'vfio-pci.ids' "$f" | sed 's/^/    /'
        fi
    done
    return $((1 - changed))
}

register_grub() {
    command -v grub-mkconfig >/dev/null || die '找不到 grub-mkconfig'
    cp -a "$GRUB_CFG" "$GRUB_CFG.bak-$(date +%Y%m%d%H%M%S)"
    grub-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1 || die 'grub-mkconfig 失败'
    grep -q "$PCI_ID" "$GRUB_CFG" && ok "grub.cfg 已包含 $PCI_ID" || warn "grub.cfg 里没找到 $PCI_ID"
    echo '  grub.cfg 启动项：'
    grep -n "menuentry '" "$GRUB_CFG" | sed 's/^/    /'
}

xml_edit() { # $1 = add|remove
    local mode=$1 tmp
    tmp=$(mktemp --suffix=.xml)
    virsh -c "$CONN" dumpxml --inactive "$DOM" > "$tmp"
    python3 - "$tmp" "$mode" <<'PY'
import re, sys
path, mode = sys.argv[1:3]
s = open(path).read()
HOSTDEV = """    <hostdev mode='subsystem' type='pci' managed='no'>
      <driver name='vfio'/>
      <source>
        <address domain='0x0000' bus='0x06' slot='0x00' function='0x3'/>
      </source>
    </hostdev>
"""
ROOTPORT = """    <controller type='pci' index='9' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='9' port='0x18'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0' multifunction='on'/>
    </controller>
"""
# 先清掉任何已存在的 06:00.3 hostdev / index 9 根端口，保证幂等
s = re.sub(r"\n\s*<hostdev mode='subsystem' type='pci' managed='[^']*'>\s*"
           r"<source>\s*<address domain='0x0000' bus='0x06' slot='0x00' function='0x3'/>\s*"
           r"</source>(?:\s*<address [^>]*/>)?\s*</hostdev>", "", s)
s = re.sub(r"\n\s*<controller type='pci' index='9' model='pcie-root-port'>.*?</controller>",
           "", s, flags=re.S)
if mode == 'add':
    i = s.index('  </devices>')
    s = s[:i] + ROOTPORT + HOSTDEV + s[i:]
open(path, 'w').write(s)
print(f"  xml: {mode} 完成")
PY
    virsh -c "$CONN" define "$tmp" >/dev/null
    rm -f "$tmp"
}

case "${1:-status}" in
enable)
    [[ -e /sys/bus/pci/devices/$PCI_ADDR ]] || die "找不到 $PCI_ADDR"
    if [[ $(virsh -c "$CONN" domstate "$DOM" 2>/dev/null || true) == '运行' ]]; then
        die "win11 正在运行，先关机再改配置"
    fi
    echo '== 1. GRUB 直通项加入 vfio-pci.ids='"$PCI_ID"' =='
    grub_patch add || warn 'GRUB 里没有已存在的 vfio-pci.ids 项，未改动'
    register_grub
    echo '== 2. 域定义加入控制器 hostdev (managed=no) =='
    xml_edit add
    echo '== 3. 当前状态 =='
    printf '  %s 现在绑定: %s\n' "$PCI_ADDR" "$(readlink -f /sys/bus/pci/devices/$PCI_ADDR/driver 2>/dev/null | sed 's#.*/##' || echo 无)"
    cat <<EOF

完成。请重启一次让 vfio-pci 在开机时接管 $PCI_ID：
    sudo reboot
重启后确认：
    lspci -nnk -s 06:00.3        # 应为 Kernel driver in use: vfio-pci
    virsh start win11
Windows 起来后，后置 USB-C 口（及扩展坞上的键鼠）就是原生 USB 设备。
EOF
    ;;
disable)
    echo '== 1. 从 GRUB 去掉 '"$PCI_ID"' =='
    grub_patch remove || true
    register_grub
    echo '== 2. 域定义移除控制器 =='
    xml_edit remove
    cat <<EOF

完成。下次启动该 USB-C 口回到 Linux。如果刚才是预绑定启动的，
卸载 vfio 需要重启一次（vfio-pci 不会在运行时把设备还给 xhci）。
EOF
    ;;
status)
    echo "=== 控制器 ==="
    lspci -nnk -s "${PCI_ADDR#0000:}" 2>/dev/null || echo "  找不到 $PCI_ADDR"
    echo
    echo "=== 本次启动 cmdline 是否预绑定 ==="
    if tr ' ' '\n' < /proc/cmdline | grep -q "$PCI_ID"; then
        echo "  cmdline 含 $PCI_ID（开机即 vfio 接管）"
    else
        echo "  cmdline 不含 $PCI_ID（当前由 xhci_hcd 持有）"
        echo "  → 现在启动 win11 会干净失败（managed=no），不会挂内核"
    fi
    echo
    echo "=== 域定义 ==="
    if virsh -c "$CONN" dumpxml --inactive "$DOM" 2>/dev/null | grep -q '06:00.3'; then
        echo "  已包含 06:00.3 hostdev"
    else
        echo "  未包含 06:00.3 hostdev"
    fi
    echo
    echo "=== GRUB 条目 ==="
    grep -rn 'vfio-pci.ids' "${GRUB_FILES[@]}" 2>/dev/null | sed 's/^/  /' || echo '  （无）'
    ;;
-h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
*)
    die "未知参数：${1}（enable|disable|status）"
    ;;
esac
