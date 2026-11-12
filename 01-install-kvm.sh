#!/usr/bin/env bash
# 第一阶段：安装 KVM/QEMU/libvirt 环境并准备安装介质。
# 用法：sudo bash 01-install-kvm.sh
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

WIN_ISO_SRC="/path/to/zh-cn_windows_11_x64.iso"
IMG_DIR="/var/lib/libvirt/images"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_LOCAL="/path/to/virtio-win.iso"

echo "==> 1/6 安装软件包"
pacman -S --needed --noconfirm \
    qemu-full libvirt virt-manager edk2-ovmf swtpm virt-viewer dmidecode

echo "==> 2/6 启用 libvirtd"
systemctl enable --now libvirtd.service

echo "==> 3/6 配置用户组（pp 加入 libvirt/kvm）"
getent group kvm >/dev/null || groupadd -r kvm
usermod -aG libvirt,kvm pp

echo "==> 4/6 配置默认 NAT 网络"
if ! virsh net-list --all --name | grep -qx default; then
    if [[ -f /etc/libvirt/qemu/networks/default.xml ]]; then
        virsh net-define /etc/libvirt/qemu/networks/default.xml
    else
        cat >/tmp/libvirt-default-net.xml <<'EOF'
<network>
  <name>default</name>
  <bridge name='virbr0'/>
  <forward mode='nat'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
        virsh net-define /tmp/libvirt-default-net.xml
        rm -f /tmp/libvirt-default-net.xml
    fi
fi
virsh net-autostart default >/dev/null 2>&1 || true
if ! virsh net-list --name | grep -qx default; then
    if ! virsh net-start default; then
        echo "警告：default 网络启动失败，稍后检查（不影响安装）。" >&2
    fi
fi

echo "==> 5/6 准备镜像目录与驱动 ISO"
install -d -m 0755 "$IMG_DIR"

if [[ -s "$IMG_DIR/virtio-win.iso" ]]; then
    echo "    virtio-win.iso 已存在，跳过。"
elif [[ -s "$VIRTIO_LOCAL" ]]; then
    echo "    使用本地 virtio-win ISO：$VIRTIO_LOCAL"
    rm -f "$IMG_DIR/virtio-win.iso.part"
    cp --reflink=auto --sparse=always "$VIRTIO_LOCAL" "$IMG_DIR/virtio-win.iso.part"
    mv "$IMG_DIR/virtio-win.iso.part" "$IMG_DIR/virtio-win.iso"
else
    echo "    下载 virtio-win.iso（约 877 MB）..."
    rm -f "$IMG_DIR/virtio-win.iso.part"
    curl -L --fail --retry 3 --progress-bar \
        -o "$IMG_DIR/virtio-win.iso.part" "$VIRTIO_URL"
    mv "$IMG_DIR/virtio-win.iso.part" "$IMG_DIR/virtio-win.iso"
fi

if [[ -f "$WIN_ISO_SRC" ]]; then
    if [[ ! -s "$IMG_DIR/win11.iso" ]]; then
        echo "    复制 Windows 11 ISO（约 8.4 GB，btrfs 上会尝试 reflink）..."
        cp --reflink=auto --sparse=always "$WIN_ISO_SRC" "$IMG_DIR/win11.iso.part"
        mv "$IMG_DIR/win11.iso.part" "$IMG_DIR/win11.iso"
    else
        echo "    win11.iso 已存在，跳过复制。"
    fi
else
    echo "警告：未找到 Windows ISO：$WIN_ISO_SRC" >&2
fi

chown root:root "$IMG_DIR"/*.iso 2>/dev/null || true
chmod 0644 "$IMG_DIR"/*.iso 2>/dev/null || true

echo "==> 6/6 状态检查"
systemctl --no-pager --full status libvirtd.service | head -n 12 || true
echo
virsh net-list --all || true
echo
ls -lh "$IMG_DIR"
echo

cat <<'EOF'
============================================================
第一阶段完成。

下一步（必须，先不要创建虚拟机）：
1. 重启，开机时联按 F2 进入 BIOS（部分机型为 Del/F12）。
2. 找到 Advanced / Display Mode / Graphics Configuration / 显示模式。
3. 从「Discrete / 独显直连」改为「Hybrid / Switchable / 混合输出」。
4. F10 保存退出，启动回 CachyOS。
5. 回来后验证：
     cat /sys/bus/pci/devices/0000:01:00.0/boot_vga   # 应为 0
     cat /sys/bus/pci/devices/0000:06:00.0/boot_vga   # 应为 1
   并且 niri 的内屏应连接到 AMD 核显（eDP-1）。

如果 BIOS 里找不到该选项：
   启动现有的 Windows，使用「机械革命控制中心 → 常规设置 → 显示模式」
   切换到混合输出，然后重启回 CachyOS。

切换成功后告诉我，我会继续第二阶段（vfio 绑定 + 启动项 + 虚拟机创建）。
============================================================
EOF
