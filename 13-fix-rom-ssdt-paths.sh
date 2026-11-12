#!/usr/bin/env bash
# 13-fix-rom-ssdt-paths.sh
#
# 把 vBIOS 和假电池 SSDT 从 /tmp（tmpfs，重启即失）安装到
# /var/lib/libvirt/images/，并把 win11 的域定义指向稳定路径。
#
# 同时移除 "在运行时解绑 xhci 控制器" 的 USB hostdev —— 这个控制器
# (0000:06:00.3) 的 reset_method 只有 pm，libvirt managed='yes' 会先把
# xhci_hcd 解绑，扩展坞挂着时实测会把内核挂死、整机重启。USB 口直通请用
# 14-usb-controller-passthrough.sh（改成开机时 vfio 预绑定）。
#
# 用法：sudo bash 13-fix-rom-ssdt-paths.sh
set -euo pipefail

[[ ${EUID} -eq 0 ]] || exec sudo -- "$0" "$@"

PROJ=$(cd "$(dirname "$0")" && pwd)
IMGDIR=/var/lib/libvirt/images
DOM=win11
VBIOS_SRC="$PROJ/gpu-rtx5060-vbios.rom"
SSDT_SRC="$PROJ/ssdt-battery.aml"
VBIOS_DST="$IMGDIR/win11-gpu-vbios.rom"
SSDT_DST="$IMGDIR/win11-ssdt-battery.aml"

ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [警告] %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

echo '== 1. 安装文件到 /var/lib/libvirt/images =='
[[ -f $VBIOS_SRC ]] || die "缺少 $VBIOS_SRC（从 GB206.rom 偏移 0x35800 提取的 64K vBIOS）"
[[ -f $SSDT_SRC  ]] || die "缺少 $SSDT_SRC（假电池 SSDT，Code 43 的关键）"
install -m 644 -o libvirt-qemu -g libvirt-qemu "$VBIOS_SRC" "$VBIOS_DST"
install -m 644 -o libvirt-qemu -g libvirt-qemu "$SSDT_SRC"  "$SSDT_DST"
ok "$VBIOS_DST ($(stat -c%s "$VBIOS_DST") B)"
ok "$SSDT_DST ($(stat -c%s "$SSDT_DST") B)"

echo '== 2. 改写域定义 =='
TMPXML=$(mktemp --suffix=.xml)
trap 'rm -f "$TMPXML"' EXIT
virsh -c qemu:///system dumpxml --inactive "$DOM" > "$TMPXML"

python3 - "$TMPXML" "$VBIOS_DST" "$SSDT_DST" <<'PY'
import re, sys
path, vbios, ssdt = sys.argv[1:4]
s = open(path).read()

# 1) 路径：/tmp -> images
s = s.replace("/tmp/gpu-rtx5060-vbios.rom", vbios)
s = s.replace("/tmp/ssdt-battery.aml", ssdt)

# 2) 删掉 USB-C 控制器的 hostdev（会触发运行时解绑 xhci，导致整机挂起）
s2 = re.sub(r"\n\s*<hostdev mode='subsystem' type='pci' managed='[^']*'>\s*"
            r"<source>\s*<address domain='0x0000' bus='0x06' slot='0x00' function='0x3'/>\s*"
            r"</source>(?:\s*<address [^>]*/>)?\s*</hostdev>", "", s)
removed_hostdev = s2 != s
s = s2

# 3) 删掉为它加的 pcie-root-port index 9（没有 hostdev 就不需要）
s2 = re.sub(r"\n\s*<controller type='pci' index='9' model='pcie-root-port'>.*?</controller>",
            "", s, flags=re.S)
removed_rootport = s2 != s
s = s2

open(path, "w").write(s)
print(f"  hostdev 移除: {removed_hostdev}")
print(f"  rootport 移除: {removed_rootport}")
PY

virsh -c qemu:///system define "$TMPXML" >/dev/null
ok '域定义已更新'

echo '== 3. 校验 =='
virsh -c qemu:///system dumpxml --inactive "$DOM" | grep -E "rom bar=|acpitable|file=.*(vbios|ssdt)" | sed 's/^/  /'
if virsh -c qemu:///system dumpxml --inactive "$DOM" | grep -q '06:00.3'; then
    warn '定义里仍有 06:00.3，请检查'
else
    ok '不再包含 USB 控制器 hostdev'
fi

cat <<'EOF'

完成。现在可以正常启动 win11（GPU 直通 + 假电池 SSDT + 有效 vBIOS）。
如果还想直通后置 USB-C，继续跑 14-usb-controller-passthrough.sh。
EOF
