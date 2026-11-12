#!/usr/bin/env bash
# 为 win11 虚拟机启用 Secure Boot：
#   - 安装 virt-firmware，生成带 Microsoft 密钥的 OVMF NVRAM
#   - 切换到 OVMF_CODE.secboot.4m.fd + SMM
#   - 保留现有 GPU/音频直通设备
#
# 用法：sudo bash 06-secure-boot.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

VM=win11
NV_DIR=/var/lib/libvirt/qemu/nvram
ENROLLED="$NV_DIR/win11_VARS.enrolled.fd"
TARGET="$NV_DIR/win11_VARS.fd"
SEC_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
VARS_TEMPLATE=/usr/share/edk2/x64/OVMF_VARS.4m.fd
STAMP=$(date +%Y%m%d-%H%M%S)

if ! virsh dominfo "$VM" >/dev/null 2>&1; then
    echo "错误：找不到虚拟机 $VM" >&2
    exit 1
fi

echo "==> 1/6 安装 virt-firmware（如果尚未安装）"
if ! command -v virt-fw-vars >/dev/null 2>&1; then
    pacman -S --needed --noconfirm virt-firmware
fi

for opt in --secure-boot --enroll-microsoft; do
    if ! virt-fw-vars --help 2>&1 | grep -q -- "$opt"; then
        echo "错误：当前 virt-fw-vars 不支持 $opt，请把下面的帮助发我：" >&2
        virt-fw-vars --help >&2 || true
        exit 1
    fi
done

echo "==> 2/6 关闭虚拟机（安装尚未开始，强制关闭不会丢进度）"
STATE=$(virsh domstate "$VM" | head -n1)
if [[ "$STATE" != "shut off" ]]; then
    virsh destroy "$VM" >/dev/null
    sleep 2
fi

echo "==> 3/6 备份当前 XML 和 NVRAM"
virsh dumpxml "$VM" >"/root/win11-before-secureboot-$STAMP.xml"
echo "    XML: /root/win11-before-secureboot-$STAMP.xml"
if [[ -f "$TARGET" ]]; then
    cp -a "$TARGET" "$TARGET.bak-$STAMP"
    echo "    NVRAM: $TARGET.bak-$STAMP"
fi

echo "==> 4/6 生成带 Microsoft 密钥的 NVRAM"
rm -f "$ENROLLED"
virt-fw-vars \
    --input "$VARS_TEMPLATE" \
    --output "$ENROLLED" \
    --secure-boot \
    --enroll-microsoft
chmod 0644 "$ENROLLED"
ls -lh "$ENROLLED"

echo "==> 5/6 修改 domain XML（secure OVMF + SMM + 已注册密钥的 NVRAM）"
python3 - "$STAMP" <<'PY'
import pathlib
import re
import subprocess
import sys

stamp = sys.argv[1]
xml = subprocess.check_output(['virsh', 'dumpxml', 'win11'], text=True)

xml, n1 = re.subn(
    r'<loader[^>]*>.*?</loader>',
    '<loader readonly="yes" secure="yes" type="pflash">/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd</loader>',
    xml, count=1, flags=re.S)
xml, n2 = re.subn(
    r'<nvram[^>]*>.*?</nvram>',
    '<nvram template="/var/lib/libvirt/qemu/nvram/win11_VARS.enrolled.fd">/var/lib/libvirt/qemu/nvram/win11_VARS.fd</nvram>',
    xml, count=1, flags=re.S)
if n1 != 1 or n2 != 1:
    sys.exit(f'XML 修改失败：loader={n1}, nvram={n2}')

if '<smm ' not in xml:
    xml = xml.replace('<acpi/>', '<acpi/>\n    <smm state="on"/>', 1)

pathlib.Path(f'/root/win11-secureboot-{stamp}.xml').write_text(xml)
print(f'/root/win11-secureboot-{stamp}.xml')
PY

SECURE_XML="/root/win11-secureboot-$STAMP.xml"
virt-xml-validate "$SECURE_XML" domain
grep -nE 'loader|nvram|smm' "$SECURE_XML" | head

echo "==> 6/6 重新定义并启动虚拟机"
virsh undefine "$VM" --nvram
virsh define "$SECURE_XML"
virsh dumpxml "$VM" | grep -E 'loader|nvram|smm|hostdev' | head -20
virsh start "$VM"

# 自动在 ISO 的 “Press any key” 提示期间按键，进入安装程序
echo "==> 自动按键，进入 Windows 安装程序"
for _ in $(seq 1 24); do
    sleep 0.4
    virsh send-key "$VM" KEY_ENTER >/dev/null 2>&1 || true
done

sleep 12
virsh domstate "$VM"
virsh screenshot "$VM" "/tmp/win11-secure-$(date +%H%M%S).ppm" 2>&1 || true

cat <<'EOF'

============================================================
Secure Boot 已配置并启动。

现在 Windows 安装程序应该不再提示“该电脑必须支持安全启动”。
如果仍停在旧界面，在 virt-manager 里点“上一步”或重启安装程序即可。

外接 KTC 仍然要等 Windows 里装好 NVIDIA 驱动后才会亮；
安装过程继续看 virt-manager 的 QXL 窗口。

安装完成后：
  1. 运行 virtio-win CD 里的 virtio-win-guest-tools.exe
  2. 安装 NVIDIA GeForce RTX 5060 Laptop 驱动
  3. 外接屏点亮后，把它设为主显示器

回滚 Secure Boot（如需要）：
  sudo cp -a /root/win11-before-secureboot-<时间戳>.xml /root/win11-rollback.xml
  sudo virsh undefine win11 --nvram
  sudo virsh define /root/win11-rollback.xml
  sudo virsh start win11
============================================================
EOF
