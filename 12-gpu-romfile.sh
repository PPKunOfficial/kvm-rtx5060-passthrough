#!/usr/bin/env bash
# 按 moper 文章：把真正的 NVIDIA vBIOS 作为 romfile 传给虚拟机。
#
# 优先级：
#   1) 如果给定了 vBIOS 文件参数，直接用它（GPU-Z/nvflash dump 出来的）
#   2) 否则尝试从宿主 /sys/bus/pci/devices/0000:01:00.0/rom 提取
#
# 背景：
#   GPU-Z 里 RTX 5060 的 BIOS Version 显示 SeaBIOS，说明 guest 没有拿到
#   NVIDIA vBIOS。之前按 Lantian 设了 <rom bar='off'/>，你的机器需要
#   真正的 vBIOS，所以改用 <rom bar='on' file='...'/>。
#
# 用法：
#   sudo bash 12-gpu-romfile.sh                 # 从宿主 ROM BAR 提取
#   sudo bash 12-gpu-romfile.sh /path/rtx.rom  # 使用 GPU-Z/nvflash 的 dump
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

VM=win11
STAMP=$(date +%Y%m%d-%H%M%S)
ROMDEV=/sys/bus/pci/devices/0000:01:00.0/rom
ROMFILE=/var/lib/libvirt/images/gpu-rtx5060.rom
ROMSRC="${1:-}"

echo "==> 1/6 关闭虚拟机（ACPI）"
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

echo "==> 2/6 备份 XML"
virsh dumpxml "$VM" > "/root/win11-before-romfile-$STAMP.xml"
echo "    /root/win11-before-romfile-$STAMP.xml"

echo "==> 3/6 准备 GPU vBIOS"
if [[ -n "$ROMSRC" ]]; then
    if [[ ! -f "$ROMSRC" ]]; then
        echo "错误：找不到外部 vBIOS 文件：$ROMSRC" >&2
        exit 1
    fi
    echo "    使用外部 vBIOS：$ROMSRC"
    cp -f "$ROMSRC" "$ROMFILE"
else
    echo "    宿主机 ROM BAR 提取（如果为空，需要先 dump vBIOS，见下方说明）"
    if [[ ! -e "$ROMDEV" ]]; then
        echo "错误：$ROMDEV 不存在。" >&2
        exit 1
    fi
    echo 1 > "$ROMDEV" 2>/dev/null || true
    rm -f "$ROMFILE"
    dd if="$ROMDEV" of="$ROMFILE" bs=1M count=2 status=none 2>/dev/null || true
    echo 0 > "$ROMDEV" 2>/dev/null || true
fi

SIZE=$(stat -c %s "$ROMFILE" 2>/dev/null || echo 0)
SIG=$(head -c 2 "$ROMFILE" 2>/dev/null | xxd -p || true)
echo "    ROM 大小：$SIZE 字节"
echo "    前 2 字节：$SIG"

if (( SIZE < 1024 )); then
    echo "错误：ROM 为空或太小。" >&2
    echo "这块笔记本 GPU 的 vBIOS 不在 ROM BAR 里，需要先 dump 出真正的 vBIOS：" >&2
    echo "  方法 A（推荐）：启动裸机 Windows，用 GPU-Z 选择 RTX 5060 → BIOS 图标 → Save to file" >&2
    echo "  方法 B：启动 host 模式 + nvflash --save /tmp/rtx5060.rom" >&2
    echo "  然后把文件路径作为参数运行本脚本：" >&2
    echo "    sudo bash $0 /path/to/rtx5060.rom" >&2
    exit 1
fi

if [[ "$SIG" != "55aa" ]]; then
    if grep -aiq 'NVIDIA' "$ROMFILE"; then
        echo "警告：ROM 头不是 55aa，但检测到 NVIDIA vBIOS 字符串；按 GPU-Z/nvflash dump 继续。"
    else
        echo "错误：ROM 头不是 55aa，也没有检测到 NVIDIA 字符串，可能不是 vBIOS 文件。" >&2
        exit 1
    fi
fi

chmod 0644 "$ROMFILE"

echo "==> 4/6 修改 XML：rom bar=on + romfile"
python3 - "$STAMP" <<'PY'
import pathlib
import re
import subprocess
import sys

stamp = sys.argv[1]
xml = subprocess.check_output(['virsh', 'dumpxml', 'win11'], text=True)

m = re.search(
    r"(<hostdev mode='subsystem' type='pci' managed='yes'>\s*<source>\s*"
    r"<address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>\s*</source>)(.*?)(</hostdev>)",
    xml, re.S)
if not m:
    sys.exit('未找到 GPU hostdev (01:00.0)')

inner = re.sub(r"\s*<rom\b[^>]*/>", '', m.group(2))
rom = "\n      <rom bar='on' file='/var/lib/libvirt/images/gpu-rtx5060.rom'/>"
xml = xml[:m.start()] + m.group(1) + rom + inner + m.group(3) + xml[m.end():]

out = pathlib.Path(f'/root/win11-romfile-{stamp}.xml')
out.write_text(xml)
print(out)
PY

FIXED="/root/win11-romfile-$STAMP.xml"
virt-xml-validate "$FIXED" domain
echo "--- 关键配置 ---"
grep -nE 'rom bar|vendor_id|ioapic|qemu:commandline|mem-reserve' "$FIXED" | head -12

echo "==> 5/6 重新定义"
virsh define "$FIXED"

echo "==> 6/6 启动"
virsh start "$VM"

cat <<'EOF'

============================================================
已把提取出来的 NVIDIA vBIOS 作为 romfile 传给 VM。

进 Windows 后：
  1. 打开 GPU-Z → RTX 5060 页面，看 BIOS Version：
     现在应该是 NVIDIA 的版本号（例如 86.07.xx.xx.xx），不再是 SeaBIOS
  2. 设备管理器看 Code 43 是否消失、资源是否出现
  3. 如果驱动仍异常：卸载 NVIDIA 驱动 → 重启 → 清洁安装
  4. 外接 KTC 应该在驱动正常后点亮

如果还是 Code 43 / 无资源：
  - 下一步按 Mathias 评论里的建议，进 BIOS 关闭 Re-Size BAR
  - 或者告诉我，我再试 Lantian 2022 的 guest 01:00.0 地址方案

回滚：
  sudo virsh undefine win11 --nvram
  sudo virsh define /root/win11-before-romfile-<时间戳>.xml
  sudo virsh start win11
============================================================
EOF
