#!/usr/bin/env bash
# 修复 07 define 失败：
#   libvirt 报 “当固件自动选择禁用时，无法使用基于功能的固件自动选择”
#   原因是 XML 里残留了 <firmware><feature .../></firmware> 功能块。
#   使用显式 loader/nvram 时必须删除它。
#
# 用法：sudo bash 08-fix-secureboot-define.sh
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

if [[ ! -s "$ENROLLED" ]]; then
    echo "==> 生成带 Microsoft 密钥的 NVRAM"
    if ! command -v virt-fw-vars >/dev/null 2>&1; then
        pacman -S --needed --noconfirm virt-firmware
    fi
    virt-fw-vars --input "$VARS_TEMPLATE" --output "$ENROLLED" \
        --secure-boot --enroll-microsoft
    chmod 0644 "$ENROLLED"
fi

BACKUP=$(ls -t /root/win11-before-secureboot-*.xml 2>/dev/null | head -n1 || true)
if [[ -z "$BACKUP" ]]; then
    echo "错误：找不到 /root/win11-before-secureboot-*.xml。" >&2
    exit 1
fi
echo "使用备份 XML: $BACKUP"

python3 - "$BACKUP" "$STAMP" <<'PY'
import pathlib
import re
import sys

src, stamp = sys.argv[1], sys.argv[2]
xml = pathlib.Path(src).read_text()

# 1) 删除 <firmware> 功能块（含 <feature>）
xml = re.sub(r'\s*<firmware\b.*?</firmware>', '', xml, count=1, flags=re.S)
xml = re.sub(r'\s*<firmware\s*/>', '', xml, count=1)

# 2) 删除 <os> 上的 firmware 属性
xml = re.sub(r'<os\b[^>]*>', '<os>', xml, count=1)

# 3) 显式 secure OVMF loader（不加 secure='yes'，避免固件匹配）
xml, n1 = re.subn(
    r'<loader[^>]*>.*?</loader>',
    '<loader readonly="yes" type="pflash">/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd</loader>',
    xml, count=1, flags=re.S)

# 4) 已注册 Microsoft 密钥的 NVRAM 模板
xml, n2 = re.subn(
    r'<nvram[^>]*>.*?</nvram>',
    '<nvram template="/var/lib/libvirt/qemu/nvram/win11_VARS.enrolled.fd">/var/lib/libvirt/qemu/nvram/win11_VARS.fd</nvram>',
    xml, count=1, flags=re.S)

if n1 != 1 or n2 != 1:
    sys.exit(f'XML 修改失败：loader={n1}, nvram={n2}')

# 5) secure OVMF 需要 SMM
if '<smm ' not in xml:
    xml = xml.replace('<acpi/>', '<acpi/>\n    <smm state="on"/>', 1)

out = pathlib.Path(f'/root/win11-secureboot-fixed2-{stamp}.xml')
out.write_text(xml)
print(out)
PY

FIXED="/root/win11-secureboot-fixed2-$STAMP.xml"
virt-xml-validate "$FIXED" domain
echo "--- 关键配置（不应再有 <firmware>）---"
grep -nE '<os|loader|nvram|smm|firmware|hostdev' "$FIXED" | head -25

echo "==> 重新定义"
if virsh dominfo "$VM" >/dev/null 2>&1; then
    STATE=$(virsh domstate "$VM" | head -n1)
    if [[ "$STATE" != "shut off" ]]; then
        virsh destroy "$VM" >/dev/null 2>&1 || true
        sleep 2
    fi
    virsh undefine "$VM" --nvram
fi
virsh define "$FIXED"

echo "==> 启动并自动按键进入安装程序"
virsh start "$VM"
for _ in $(seq 1 24); do
    sleep 0.4
    virsh send-key "$VM" KEY_ENTER >/dev/null 2>&1 || true
done
sleep 12
virsh domstate "$VM" || true
virsh screenshot "$VM" "/tmp/win11-secureboot-fixed2-$(date +%H%M%S).ppm" 2>&1 || true

cat <<'EOF'

============================================================
VM 已用 Secure Boot 配置重新定义并启动。

安装程序应该不再提示“必须支持安全启动”。
外接 KTC 仍然要等 Windows 里装好 NVIDIA 驱动后才会亮。

如果仍然报错，把错误和这个文件发我：
  /root/win11-secureboot-fixed2-<时间戳>.xml
============================================================
EOF
