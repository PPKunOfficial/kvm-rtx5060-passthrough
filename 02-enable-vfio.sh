#!/usr/bin/env bash
# 第二阶段：启用 vfio-pci 直通（GPU + HDMI 音频），并添加“宿主机显卡模式”启动项。
# 前置条件：BIOS 已从“独显直连”切换到“混合输出”，且已重启回 CachyOS。
# 用法：sudo bash 02-enable-vfio.sh
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"

# ---------------------------------------------------------------- 前置检查
NV_BOOT=$(cat /sys/bus/pci/devices/0000:01:00.0/boot_vga 2>/dev/null || echo '?')
IGPU_BOOT=$(cat /sys/bus/pci/devices/0000:06:00.0/boot_vga 2>/dev/null || echo '?')
if [[ "$NV_BOOT" != '0' || "$IGPU_BOOT" != '1' ]]; then
    cat >&2 <<EOF
错误：当前看起来仍是“独显直连”模式，直接启用 vfio 会让宿主机没有显示输出。

  NVIDIA 0000:01:00.0 boot_vga = $NV_BOOT   （混合模式下应为 0）
  AMD    0000:06:00.0 boot_vga = $IGPU_BOOT （混合模式下应为 1）

请先重启进入 BIOS，把 Display Mode / 显示模式 改为 Hybrid / 混合输出；
或者启动现有 Windows，用“机械革命控制中心 → 常规设置 → 显示模式”切换。
确认内屏由 AMD 核显驱动后，再运行本脚本。
EOF
    exit 1
fi

# ---------------------------------------------------------------- 定位启动文件
ROOT_UUID=$(sed -n 's/.*root=UUID=\([^ ]*\).*/\1/p' /proc/cmdline)
BOOT_IMAGE=$(sed -n 's/.*BOOT_IMAGE=\([^ ]*\).*/\1/p' /proc/cmdline)
if [[ -z "$ROOT_UUID" || -z "$BOOT_IMAGE" ]]; then
    echo "错误：无法从 /proc/cmdline 解析 root UUID / BOOT_IMAGE。" >&2
    exit 1
fi
PREFIX=${BOOT_IMAGE%/boot/vmlinuz-*}
KERNEL="$PREFIX/boot/vmlinuz-linux-cachyos"
INITRD="$PREFIX/boot/initramfs-linux-cachyos.img"
if [[ ! -f /boot/vmlinuz-linux-cachyos || ! -f /boot/initramfs-linux-cachyos.img ]]; then
    echo "错误：未找到 linux-cachyos 内核或 initramfs。" >&2
    exit 1
fi
echo "root UUID : $ROOT_UUID"
echo "GRUB 内核 : $KERNEL"
echo "GRUB initrd: $INITRD"

# ---------------------------------------------------------------- 备份
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a /etc/default/grub "/etc/default/grub.bak-$STAMP"
cp -a /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak-$STAMP"
cp -a /etc/grub.d/40_custom "/etc/grub.d/40_custom.bak-$STAMP"
echo "已备份：/etc/default/grub.bak-$STAMP 等"

# ---------------------------------------------------------------- modprobe
cat >/etc/modprobe.d/vfio.conf <<'EOF'
# 由 02-enable-vfio.sh 生成。
# 这里故意不写 ids=：具体 ID 由 GRUB 默认启动项的 vfio-pci.ids= 提供，
# 这样“宿主机显卡模式”启动项可以不占用 GPU。
softdep nvidia pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF

# ---------------------------------------------------------------- initramfs
install -d -m 0755 /etc/mkinitcpio.conf.d
cat >/etc/mkinitcpio.conf.d/20-vfio.conf <<'EOF'
# 由 02-enable-vfio.sh 生成：让 vfio-pci 在启动早期加载并抢占 GPU。
MODULES=(vfio_pci vfio_iommu_type1 vfio)
EOF

# ---------------------------------------------------------------- 默认启动项参数
python3 - <<'PY'
import pathlib
import re
import sys

p = pathlib.Path('/etc/default/grub')
s = p.read_text()
params = ['amd_iommu=on', 'iommu=pt', 'vfio-pci.ids=10de:2d19,10de:22eb']
lines = s.splitlines()
found = False

for i, line in enumerate(lines):
    m = re.match(r"^(GRUB_CMDLINE_LINUX_DEFAULT=)(['\"])(.*?)(\2)\s*$", line)
    if not m:
        continue
    found = True
    words = m.group(3).split()
    for param in params:
        if param not in words:
            words.append(param)
    lines[i] = f"{m.group(1)}{m.group(2)}{' '.join(words)}{m.group(2)}"
    break

if not found:
    sys.exit('未找到 GRUB_CMDLINE_LINUX_DEFAULT 行')

p.write_text('\n'.join(lines) + '\n')
PY

BASE_CMDLINE=$(python3 - <<'PY'
import pathlib
import re

s = pathlib.Path('/etc/default/grub').read_text()
m = re.search(r"^GRUB_CMDLINE_LINUX_DEFAULT=['\"](.*?)['\"]\s*$", s, re.M)
print(m.group(1) if m else '')
PY
)
HOST_CMDLINE=$(printf '%s\n' "$BASE_CMDLINE" | sed 's/vfio-pci\.ids=[^ ]*//g' | xargs)
if [[ -z "$HOST_CMDLINE" ]]; then
    echo "错误：无法生成宿主机模式 cmdline。" >&2
    exit 1
fi
echo "默认项 cmdline: $BASE_CMDLINE"
echo "宿主项 cmdline: $HOST_CMDLINE"

# ---------------------------------------------------------------- 宿主机模式启动项
if grep -q 'VFIO HOST MODE ENTRY' /etc/grub.d/40_custom; then
    sed -i '/# >>> VFIO HOST MODE ENTRY >>>/,/# <<< VFIO HOST MODE ENTRY <<</d' /etc/grub.d/40_custom
fi

{
    echo ''
    echo '# >>> VFIO HOST MODE ENTRY >>>'
    echo "menuentry 'CachyOS (Host GPU, no passthrough)' --class cachyos --class gnu-linux --class gnu --class os {"
    echo '    insmod part_gpt'
    echo '    insmod btrfs'
    echo "    search --no-floppy --fs-uuid --set=root $ROOT_UUID"
    echo "    linux $KERNEL root=UUID=$ROOT_UUID rw rootflags=subvol=@ $HOST_CMDLINE"
    echo "    initrd $INITRD"
    echo '}'
    echo '# <<< VFIO HOST MODE ENTRY <<<'
} >> /etc/grub.d/40_custom
chmod +x /etc/grub.d/40_custom

# ---------------------------------------------------------------- 重建
echo "==> 重建 initramfs（两个内核）"
mkinitcpio -P

echo "==> 重建 GRUB 配置"
grub-mkconfig -o /boot/grub/grub.cfg

# ---------------------------------------------------------------- 安装模式切换脚本
if [[ -f "$SCRIPT_DIR/vfio-boot-mode" ]]; then
    install -m 0755 "$SCRIPT_DIR/vfio-boot-mode" /usr/local/bin/vfio-boot-mode
    echo "已安装：/usr/local/bin/vfio-boot-mode"
fi

# ---------------------------------------------------------------- 验证
echo "==> 验证配置"
ok=1
grep -q 'vfio-pci.ids=10de:2d19,10de:22eb' /boot/grub/grub.cfg \
    || { echo "错误：GRUB 默认项缺少 vfio-pci.ids" >&2; ok=0; }
grep -q 'CachyOS (Host GPU, no passthrough)' /boot/grub/grub.cfg \
    || { echo "错误：GRUB 中未找到宿主机模式启动项" >&2; ok=0; }
lsinitcpio /boot/initramfs-linux-cachyos.img 2>/dev/null | grep -qE 'vfio[-_]pci' \
    || { echo "错误：initramfs 中没有 vfio-pci 模块" >&2; ok=0; }
if [[ $ok -ne 1 ]]; then
    echo "验证失败，请先不要重启；把以上错误发给我。" >&2
    exit 1
fi

# ---------------------------------------------------------------- vBIOS ROM 检查（非致命）
echo "==> 检查 GPU vBIOS ROM"
if [[ -e /sys/bus/pci/devices/0000:01:00.0/rom ]]; then
    echo 1 > /sys/bus/pci/devices/0000:01:00.0/rom 2>/dev/null || true
    if dd if=/sys/bus/pci/devices/0000:01:00.0/rom of=/tmp/gpu-rom.bin \
          bs=1M count=4 status=none 2>/dev/null; then
        echo "    ROM 大小: $(stat -c %s /tmp/gpu-rom.bin 2>/dev/null || echo 0) 字节"
    else
        echo "    读取 ROM 失败（非致命；先继续，若 Windows 里 GPU 异常再处理）"
    fi
    echo 0 >/sys/bus/pci/devices/0000:01:00.0/rom 2>/dev/null || true
    rm -f /tmp/gpu-rom.bin
fi

cat <<'EOF'

============================================================
第二阶段配置完成。现在请重启：

    sudo reboot

重启后应看到：
  - 内屏正常显示 niri（AMD 核显）
  - 外接 KTC 显示器黑屏（它已归虚拟机，等 Windows 启动后才亮）
  - lspci -nnk -d 10de:2d19 显示 Kernel driver in use: vfio-pci

验证命令：
    lspci -nnk -d 10de:2d19
    lspci -nnk -d 10de:22eb
    ls /dev/vfio/
    niri msg outputs

如果重启后黑屏/没有桌面：
  1. 重启，在 GRUB 菜单选择 “CachyOS (Host GPU, no passthrough)”
     （菜单只显示 5 秒，可用方向键停留）。
  2. 或按 Ctrl+Alt+F2 进 TTY 登录，然后告诉我。
  3. 恢复配置的命令写在 README.md 的“回滚”一节。

确认重启正常后告诉我，我会继续创建 Windows 11 虚拟机。
============================================================
EOF
