#!/usr/bin/env bash
# 第四阶段：把 RTX 5060 + HDMI 音频挂给 win11 虚拟机。
# 前置：
#   - 已重启进入 vfio 直通模式（lspci 显示 vfio-pci）
#   - Windows 已安装完成并关机
# 用法：sudo bash 04-attach-gpu.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

VM=win11

if ! virsh dominfo "$VM" >/dev/null 2>&1; then
    echo "错误：找不到虚拟机 $VM。请先运行 03-create-vm.sh。" >&2
    exit 1
fi

if ! lspci -nnk -d 10de:2d19 | grep -q 'vfio-pci'; then
    echo "错误：GPU 当前不在 vfio-pci 驱动下。" >&2
    echo "请重启进入直通模式（默认启动项），或运行：sudo vfio-boot-mode vm" >&2
    echo
    lspci -nnk -d 10de:2d19
    exit 1
fi

STATE=$(virsh domstate "$VM" | head -n1)
if [[ "$STATE" != "shut off" ]]; then
    echo "错误：虚拟机当前状态为 '$STATE'，请先在 Windows 里关机。" >&2
    exit 1
fi

if virsh dumpxml "$VM" | grep -q "bus='0x01' slot='0x00' function='0x0'"; then
    echo "GPU 已经挂载到 $VM，无需重复操作。"
    virsh dumpxml "$VM" | grep -A6 '<hostdev' | head -20
    exit 0
fi

cat >/tmp/win11-gpu.xml <<'EOF'
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
</hostdev>
EOF

cat >/tmp/win11-gpu-audio.xml <<'EOF'
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x1'/>
  </source>
</hostdev>
EOF

echo "==> 挂载 GPU (01:00.0)"
virsh attach-device "$VM" /tmp/win11-gpu.xml --config

echo "==> 挂载 HDMI 音频 (01:00.1)"
virsh attach-device "$VM" /tmp/win11-gpu-audio.xml --config

rm -f /tmp/win11-gpu.xml /tmp/win11-gpu-audio.xml

echo "==> 当前挂载的设备"
virsh dumpxml "$VM" | grep -A6 '<hostdev' | head -24

echo "==> 启动虚拟机"
virsh start "$VM"

cat <<'EOF'

============================================================
GPU 已挂载并启动虚拟机。

接下来在 Windows 里：
1. 打开「设备管理器」，应能看到一个未安装驱动的 3D 控制器 / 显示适配器。
2. 下载并安装 NVIDIA GeForce 驱动：
   - 在 Windows 里访问 nvidia.cn / nvidia.com
   - 产品类型：GeForce
   - 产品系列：GeForce RTX 50 Series (Notebooks)
   - 产品：GeForce RTX 5060 Laptop GPU
   - 操作系统：Windows 11
   安装时选「自定义（高级）」→ 勾选「执行清洁安装」。
3. 安装完成后重启 Windows。外接 KTC 显示器应该会点亮。
4. 在 Windows 显示设置里：
   - 按 Win+P 选择「扩展」或「仅第二屏幕」
   - 把外接屏设为主显示器，分辨率 2560x1440，刷新率选 200Hz
5. 打开 cmd 运行 `nvidia-smi`，确认能看到 RTX 5060。

如果设备管理器里出现 Code 43 或驱动安装失败：
   - 先确认 VM XML 里有 <kvm><hidden state='on'/></kvm>（已默认添加）
   - 把 libvirt 日志发给我：/var/log/libvirt/qemu/win11.log
   - 可能需要换一个 NVIDIA 驱动版本再试

关于音频：
   - 外接屏如果自带喇叭，NVIDIA HDMI 音频会走显示器。
   - VM 还有一个 Spice 模拟声卡，声音从宿主机的 virt-manager/virt-viewer 播放。
   - 游戏耳机建议用 USB 直通（virt-manager → Add Hardware → USB Host Device）。
============================================================
EOF
