#!/usr/bin/env bash
# 修复 NVIDIA Code 43：
#   GPU 所在 PCIe root port 的 32-bit memory window 只有 64MB，
#   而 GPU BAR0 就是 64MB，再加 512KB vBIOS ROM 就放不下，
#   Windows 资源分配失败 -> NVIDIA 驱动初始化失败 -> Code 43。
#
# 本脚本给所有 pcie-root-port 增加 mem-reserve=128MB（QEMU -global），
# 让 GPU 的 BAR0 + ROM 能一起映射。
#
# 用法：sudo bash 10-fix-gpu-bar-window.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

VM=win11
STAMP=$(date +%Y%m%d-%H%M%S)

if ! virsh dominfo "$VM" >/dev/null 2>&1; then
    echo "错误：找不到虚拟机 $VM" >&2
    exit 1
fi

echo "==> 1/5 关闭虚拟机（ACPI 正常关机）"
STATE=$(virsh domstate "$VM" | head -n1)
if [[ "$STATE" != "shut off" ]]; then
    virsh shutdown "$VM" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        sleep 2
        STATE=$(virsh domstate "$VM" | head -n1)
        [[ "$STATE" == "shut off" ]] && break
    done
    if [[ "$STATE" != "shut off" ]]; then
        echo "虚拟机还没有关机（当前：$STATE）。" >&2
        echo "请先在 Windows 里点击「关机」，然后再运行本脚本。" >&2
        exit 1
    fi
fi
echo "    已关机"

echo "==> 2/5 备份当前 XML"
virsh dumpxml "$VM" > "/root/win11-before-barfix-$STAMP.xml"
echo "    /root/win11-before-barfix-$STAMP.xml"

echo "==> 3/5 生成带 root port 内存窗口的 XML"
python3 - "$STAMP" <<'PY'
import pathlib
import re
import subprocess
import sys

stamp = sys.argv[1]
xml = subprocess.check_output(['virsh', 'dumpxml', 'win11'], text=True)

# 确保 qemu namespace
if 'xmlns:qemu=' not in xml:
    xml = re.sub(
        r"<domain\b([^>]*)>",
        r"<domain\1 xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>",
        xml, count=1)

# 删除可能存在的旧 commandline
xml = re.sub(r'\s*<qemu:commandline>.*?</qemu:commandline>', '', xml, flags=re.S)

cmdline = """  <qemu:commandline>
    <qemu:arg value='-global'/>
    <qemu:arg value='pcie-root-port.mem-reserve=134217728'/>
  </qemu:commandline>
</domain>"""
xml = xml.replace("</domain>", cmdline, 1)

out = pathlib.Path(f'/root/win11-barfix-{stamp}.xml')
out.write_text(xml)
print(out)
PY

FIXED="/root/win11-barfix-$STAMP.xml"
virt-xml-validate "$FIXED" domain
echo "--- 关键配置 ---"
grep -n -E 'qemu:commandline|mem-reserve|<domain' "$FIXED" | head

echo "==> 4/5 重新定义"
virsh define "$FIXED"

echo "==> 5/5 启动虚拟机"
virsh start "$VM"
sleep 25
echo "--- 当前 GPU 的 BAR 映射（应不再是 not mapped）---"
virsh -c qemu:///system qemu-monitor-command "$VM" --hmp 'info pci' 2>/dev/null \
    | grep -A10 '10de:2d19' || true

cat <<'EOF'

============================================================
已应用 root port 内存窗口修复并启动 VM。

进入 Windows 后：
  1. 打开设备管理器，看 RTX 5060 是否还是 Code 43。
  2. 如果还是 Code 43：右键显卡 →「禁用设备」，再「启用设备」；
     或者重启一次 Windows。
  3. 外接 KTC 应该在驱动正常后点亮；用 Win+P → 扩展，
     再把外接屏设为主显示器。

如果仍然是 Code 43，把下面内容发我：
  - 设备管理器 → 显卡 → 属性 →「资源」和「事件」标签截图
  - 宿主机：sudo tail -120 /var/log/libvirt/qemu/win11.log

回滚：
  sudo virsh undefine win11 --nvram
  sudo virsh define /root/win11-before-barfix-<时间戳>.xml
  sudo virsh start win11
============================================================
EOF
