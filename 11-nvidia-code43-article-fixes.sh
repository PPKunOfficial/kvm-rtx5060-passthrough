#!/usr/bin/env bash
# 参考三篇文章修复 NVIDIA Code 43：
#   - Lantian: MUX 笔记本 hostdev 使用 <rom bar='off'/>，hyperv vendor_id 用随机值
#   - Mathias: q35 加 <ioapic driver='kvm'/>，kvm hidden
#   - 保留之前 10 脚本的 root port mem-reserve=128MB
#
# 用法：sudo bash 11-nvidia-code43-article-fixes.sh
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

echo "==> 1/5 关闭虚拟机（ACPI）"
STATE=$(virsh domstate "$VM" | head -n1)
if [[ "$STATE" != "shut off" ]]; then
    virsh shutdown "$VM" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        sleep 2
        STATE=$(virsh domstate "$VM" | head -n1)
        [[ "$STATE" == "shut off" ]] && break
    done
    if [[ "$STATE" != "shut off" ]]; then
        echo "虚拟机未关机（当前：$STATE）。请先在 Windows 里关机，再重跑。" >&2
        exit 1
    fi
fi
echo "    已关机"

echo "==> 2/5 备份 XML"
virsh dumpxml "$VM" > "/root/win11-before-c43fix-$STAMP.xml"
echo "    /root/win11-before-c43fix-$STAMP.xml"

echo "==> 3/5 修改 XML"
python3 - "$STAMP" <<'PY'
import pathlib
import re
import subprocess
import sys

stamp = sys.argv[1]
xml = subprocess.check_output(['virsh', 'dumpxml', 'win11'], text=True)
changed = []

# 1) 随机 Hyper-V vendor id（12 字符）
if re.search(r"<vendor_id state='on' value='[^']*'/>", xml):
    xml = re.sub(r"<vendor_id state='on' value='[^']*'/>",
                 "<vendor_id state='on' value='1234567890ab'/>", xml, count=1)
    changed.append('vendor_id=1234567890ab')

# 2) q35 ioapic kvm
if '<ioapic ' not in xml:
    xml = xml.replace('<apic/>', '<apic/>\n    <ioapic driver="kvm"/>', 1)
    changed.append('ioapic=kvm')

# 3) GPU hostdev 使用 <rom bar='off'/>（Lantian 的 MUX 笔记本做法）
#    找到 function 0x0 的 hostdev，删除已有 rom，再在 </source> 后插入
m = re.search(
    r"(<hostdev mode='subsystem' type='pci' managed='yes'>\s*<source>\s*"
    r"<address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>\s*</source>)(.*?)(</hostdev>)",
    xml, re.S)
if not m:
    sys.exit('未找到 GPU hostdev (01:00.0)')
inner = re.sub(r"\s*<rom\b[^>]*/>", '', m.group(2))
new_hostdev = m.group(1) + "\n      <rom bar='off'/>" + inner + m.group(3)
xml = xml[:m.start()] + new_hostdev + xml[m.end():]
changed.append('rom bar=off')

out = pathlib.Path(f'/root/win11-c43fix-{stamp}.xml')
out.write_text(xml)
print('changes:', ', '.join(changed))
print(out)
PY

FIXED="/root/win11-c43fix-$STAMP.xml"
virt-xml-validate "$FIXED" domain
echo "--- 关键配置 ---"
grep -nE 'ioapic|vendor_id|rom bar|qemu:commandline|mem-reserve' "$FIXED" | head -12

echo "==> 4/5 重新定义"
virsh define "$FIXED"

echo "==> 5/5 启动"
virsh start "$VM"

cat <<'EOF'

============================================================
已应用参考文章的 Code 43 修复：
  - Hyper-V vendor_id = 1234567890ab
  - q35 ioapic = kvm
  - GPU hostdev rom bar = off（Lantian 的 MUX 笔记本做法）
  - 保留 root port mem-reserve=128MB

进 Windows 后：
  1. 设备管理器看 RTX 5060 是否还 Code 43
  2. 如果还是：右键 → 禁用设备 → 启用设备；或重启 Windows
  3. 检查显卡属性 → 资源，看是否出现 Memory Range

如果仍然 Code 43 / 无资源，下一步按 moper 文章：
  从宿主机 /sys/bus/pci/devices/0000:01:00.0/rom 提取 vBIOS，
  作为 romfile 传给 VM（<rom bar='on' file='/path/gpu.rom'/>）。
  告诉我，我来做这个。

另外，Mathias 文章评论里提到 BIOS 关闭 Re-Size BAR 也能解决 Code 43；
如果 romfile 也不行，就关 BIOS 的 Resizable BAR 再试。

回滚：
  sudo virsh undefine win11 --nvram
  sudo virsh define /root/win11-before-c43fix-<时间戳>.xml
  sudo virsh start win11
============================================================
EOF
