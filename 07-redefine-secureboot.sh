#!/usr/bin/env bash
# 修复 06 脚本 define 失败的问题：
#   - 不使用 loader 的 secure='yes'（它会触发 libvirt 固件自动匹配）
#   - 直接使用 OVMF_CODE.secboot.4m.fd + SMM + 已注册 Microsoft 密钥的 NVRAM
#   - 从 /root/win11-before-secureboot-*.xml 恢复，保留 GPU/音频直通
#
# 用法：sudo bash 07-redefine-secureboot.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

VM=win11
NV_DIR=/var/lib/libvirt/qemu/nvram
ENROLLED="$NV_DIR/win11_VARS.enrolled.fd"
VARS_TEMPLATE=/usr/share/edk2/x64/OVMF_VARS.4m.fd
STAMP=$(date +%Y%m%d-%H%M%S)

echo "==> 1/5 确保 virt-firmware 和带密钥 NVRAM 存在"
if ! command -v virt-fw-vars >/dev/null 2>&1; then
    pacman -S --needed --noconfirm virt-firmware
fi
if [[ ! -s "$ENROLLED" ]]; then
    rm -f "$ENROLLED"
    virt-fw-vars --input "$VARS_TEMPLATE" --output "$ENROLLED" \
        --secure-boot --enroll-microsoft
    chmod 0644 "$ENROLLED"
fi
ls -lh "$ENROLLED"

echo "==> 2/5 找到最近一次直通 XML 备份"
BACKUP=$(ls -t /root/win11-before-secureboot-*.xml 2>/dev/null | head -n1 || true)
if [[ -z "$BACKUP" ]]; then
    echo "错误：找不到 /root/win11-before-secureboot-*.xml。" >&2
    echo "请把 06 脚本的完整输出发我。" >&2
    exit 1
fi
echo "    使用：$BACKUP"

echo "==> 3/5 生成修复后的 XML"
python3 - "$BACKUP" "$STAMP" <<'PY'
import pathlib
import re
import sys

src, stamp = sys.argv[1], sys.argv[2]
xml = pathlib.Path(src).read_text()

# 移除 <os firmware='efi'> 的自动固件匹配属性（如果有）
xml = re.sub(r'<os\b[^>]*>', '<os>', xml, count=1)

xml, n1 = re.subn(
    r'<loader[^>]*>.*?</loader>',
    '<loader readonly="yes" type="pflash">/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd</loader>',
    xml, count=1, flags=re.S)

xml, n2 = re.subn(
    r'<nvram[^>]*>.*?</nvram>',
    '<nvram template="/var/lib/libvirt/qemu/nvram/win11_VARS.enrolled.fd">/var/lib/libvirt/qemu/nvram/win11_VARS.fd</nvram>',
    xml, count=1, flags=re.S)

if n1 != 1 or n2 != 1:
    sys.exit(f'XML 修改失败：loader={n1}, nvram={n2}')

if '<smm ' not in xml:
    xml = xml.replace('<acpi/>', '<acpi/>\n    <smm state="on"/>', 1)

out = pathlib.Path(f'/root/win11-secureboot-fixed-{stamp}.xml')
out.write_text(xml)
print(out)
PY

FIXED="/root/win11-secureboot-fixed-$STAMP.xml"
virt-xml-validate "$FIXED" domain
echo "--- 关键配置 ---"
grep -nE '<os|loader|nvram|smm|hostdev' "$FIXED" | head -20

echo "==> 4/5 清理旧定义（如有）并重新定义"
if virsh dominfo "$VM" >/dev/null 2>&1; then
    STATE=$(virsh domstate "$VM" | head -n1)
    if [[ "$STATE" != "shut off" ]]; then
        virsh destroy "$VM" >/dev/null 2>&1 || true
        sleep 2
    fi
    virsh undefine "$VM" --nvram
fi
virsh define "$FIXED"

echo "==> 5/5 启动并自动按键进入安装程序"
virsh start "$VM"
for _ in $(seq 1 24); do
    sleep 0.4
    virsh send-key "$VM" KEY_ENTER >/dev/null 2>&1 || true
done
sleep 12
virsh domstate "$VM" || true
virsh screenshot "$VM" "/tmp/win11-secureboot-fixed-$(date +%H%M%S).ppm" 2>&1 || true

cat <<'EOF'

============================================================
VM 已用 Secure Boot 配置重新定义并启动。

现在安装程序应该不再提示“必须支持安全启动”。
如果仍显示旧提示，在 virt-manager 里点“上一步”再继续，或重启安装程序。

外接 KTC 仍然要等 Windows 里装好 NVIDIA 驱动后才会亮；
安装过程继续看 virt-manager 的 QXL 窗口。

如果 define 仍然失败，把错误和下面文件发我：
  /root/win11-secureboot-fixed-<时间戳>.xml
  /root/win11-before-secureboot-<时间戳>.xml
============================================================
EOF
