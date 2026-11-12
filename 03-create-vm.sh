#!/usr/bin/env bash
# 第三阶段：创建 Windows 11 虚拟机（暂不挂 GPU，先完成系统安装）。
# 用法：sudo bash 03-create-vm.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
VM=win11
IMG_DIR=/var/lib/libvirt/images
DISK="$IMG_DIR/win11.qcow2"
DOMAIN_XML="$SCRIPT_DIR/win11.xml"

for f in "$DOMAIN_XML" "$IMG_DIR/win11.iso" "$IMG_DIR/virtio-win.iso" \
         /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do
    if [[ ! -f "$f" ]]; then
        echo "缺少文件：$f" >&2
        exit 1
    fi
done

if ! systemctl is-active --quiet libvirtd.service; then
    systemctl start libvirtd.service
fi

if virsh dominfo "$VM" >/dev/null 2>&1; then
    echo "虚拟机 $VM 已存在，跳过创建。当前状态："
    virsh dominfo "$VM" | sed -n '1,12p'
    exit 0
fi

if [[ ! -f "$DISK" ]]; then
    echo "==> 创建 128G qcow2 磁盘：$DISK"
    qemu-img create -f qcow2 \
        -o preallocation=metadata,lazy_refcounts=on \
        "$DISK" 128G
else
    echo "==> 磁盘已存在：$DISK"
fi

chown root:root "$DISK"
chmod 0644 "$DISK"

echo "==> 定义虚拟机 $VM"
virsh define "$DOMAIN_XML"

echo "==> 启动虚拟机（安装 Windows）"
virsh start "$VM"

cat <<'EOF'

============================================================
虚拟机已启动。用下面的方式打开图形控制台：

    virt-manager --connect qemu:///system
    或
    virt-viewer --connect qemu:///system --wait win11

如果当前终端里没有 libvirt 组权限，先注销重新登录，或用
`newgrp libvirt` 开一个新 shell。

------------------------------------------------------------
Windows 11 安装要点：

1. 从 Windows ISO 启动，选择「安装 Windows 11」。
2. 产品密钥选「我没有产品密钥」，版本选 Windows 11 专业版。
3. 到了「选择安装位置」时看不到硬盘是正常的：
   - 点「加载驱动程序」→「浏览」
   - 选择 virtio-win 的 CD 盘 → viostor\w11\amd64 → 确定
   - 磁盘出现后选中它，下一步。
4. 安装过程会自动重启；出现 "Press any key to boot from CD" 时不要按键。
5. OOBE 要求联网时，按 Shift+F10 打开命令行，执行：
       start ms-cxh:localonly
   在弹出的窗口里创建本地账户；如果该命令不可用，改用：
       reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f
       shutdown /r /t 0
   重启后选择「我没有 Internet 连接」→「继续执行受限设置」。
6. 进入桌面后，打开 virtio-win 的 CD 盘，运行
   virtio-win-guest-tools.exe，安装完成后重启。
   这会装上网络、气球、串口、QEMU guest agent 等驱动。
7. 建议关闭 Windows 的「快速启动」：
   控制面板 → 电源选项 → 选择电源按钮的功能 → 更改当前不可用的设置
   → 取消勾选「启用快速启动」→ 保存。

------------------------------------------------------------
安装完成并进入桌面后：

  sudo bash 04-attach-gpu.sh

脚本会把 RTX 5060 + HDMI 音频挂给 VM，然后再次启动虚拟机。
之后在 Windows 里安装 NVIDIA 驱动即可。
============================================================
EOF
