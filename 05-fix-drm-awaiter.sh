#!/usr/bin/env bash
# 修复 CachyOS drm-module-load.target 在 vfio 直通模式下等待 nvidia_drm 导致蓝屏的问题。
#
# 背景：
#   CachyOS 的 drm-module-awaiter-generator 生成的目标同时等待
#   sys-module-amdgpu.device 和 sys-module-nvidia_drm.device。
#   直通模式下 GPU 被 vfio-pci 占用，nvidia_drm 不会加载；target 30 秒超时后
#   drm-failure-handler 会进入救援界面（蓝色屏幕）。
#
# 修复：
#   1. 用静态 /etc/systemd/system/drm-module-load.target 覆盖生成的目标：
#      - 仍然等待 amdgpu（内屏必须）
#      - 不再硬等待 nvidia_drm
#   2. 新增 drm-wait-nvidia.service：
#      - ExecCondition 检查 cmdline：
#          非直通（host 模式）→ 继续等待 nvidia_drm
#          直通（含 vfio-pci.ids=）→ 服务被跳过
#
# 用法：sudo bash 05-fix-drm-awaiter.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)

echo "==> 1/5 备份可能存在的旧文件"
for f in /etc/systemd/system/drm-module-load.target \
         /etc/systemd/system/drm-wait-nvidia.service \
         /usr/local/bin/check-host-gpu-mode.sh \
         /usr/local/bin/wait-nvidia-drm.sh; do
    if [[ -e "$f" ]]; then
        cp -a "$f" "$f.bak-$STAMP"
        echo "    $f -> $f.bak-$STAMP"
    fi
done

echo "==> 2/5 写入模式判断脚本"
cat >/usr/local/bin/check-host-gpu-mode.sh <<'EOF'
#!/usr/bin/env bash
# exit 0 = host GPU 模式（没有 vfio-pci.ids），需要等待 nvidia_drm
# exit 1 = vfio 直通模式，跳过 nvidia_drm 等待
if grep -q 'vfio-pci.ids=10de:2d19,10de:22eb' /proc/cmdline; then
    exit 1
fi
exit 0
EOF
chmod 0755 /usr/local/bin/check-host-gpu-mode.sh

echo "==> 3/5 写入 nvidia_drm 等待脚本"
cat >/usr/local/bin/wait-nvidia-drm.sh <<'EOF'
#!/usr/bin/env bash
# 仅在 host GPU 模式下被 systemd 调用。
set -euo pipefail
for _ in $(seq 1 100); do
    [[ -d /sys/module/nvidia_drm ]] && exit 0
    sleep 0.15
done
echo "wait-nvidia-drm: nvidia_drm not loaded within 15s" >&2
exit 1
EOF
chmod 0755 /usr/local/bin/wait-nvidia-drm.sh

echo "==> 4/5 写入条件服务"
cat >/etc/systemd/system/drm-wait-nvidia.service <<'EOF'
[Unit]
Description=Wait for nvidia_drm (host GPU mode only)
After=sys-module-amdgpu.device

[Service]
Type=oneshot
# 直通模式下 check 脚本返回 1，systemd 会把本服务标记为 skipped，
# 不会失败，也不会阻塞 drm-module-load.target。
ExecCondition=/usr/local/bin/check-host-gpu-mode.sh
ExecStart=/usr/local/bin/wait-nvidia-drm.sh
TimeoutStartSec=25s
EOF

echo "==> 5/5 写入静态 target 覆盖生成的目标"
cat >/etc/systemd/system/drm-module-load.target <<'EOF'
[Unit]
Description=DRM module load target (vfio-aware override)
Documentation=man:systemd.special(7)
JobTimeoutSec=30s
OnFailure=emergency.target drm-failure-handler.service
OnFailureJobMode=replace-irreversibly

Before=getty@tty1.service kmsconvt@tty1.service display-manager.service
Wants=sys-module-amdgpu.device drm-wait-nvidia.service
After=sys-module-amdgpu.device drm-wait-nvidia.service plymouth-quit.service
EOF

systemctl daemon-reload

echo
echo "==> 验证"
echo "--- target 来源与依赖（FragmentPath 应为 /etc/systemd/system/drm-module-load.target）---"
systemctl show drm-module-load.target -p FragmentPath -p Wants -p After
echo
echo "--- 服务文件 ---"
systemctl --no-pager cat drm-wait-nvidia.service
echo
echo "--- 当前模式判断（host 模式应为 host mode）---"
if /usr/local/bin/check-host-gpu-mode.sh; then
    echo "host mode: 需要等待 nvidia_drm"
    systemctl start drm-wait-nvidia.service || true
    systemctl show drm-wait-nvidia.service -p Result -p ActiveState
    systemctl status drm-wait-nvidia.service --no-pager | head -n 12 || true
else
    echo "passthrough mode: nvidia 等待服务会被跳过"
fi

cat <<'EOF'

============================================================
修复已写入。现在重启，选择默认第一项（带 vfio 直通）测试：

    sudo reboot

预期：
  - 不再出现 “Failed to load your GPU driver(s)” 蓝色界面
  - 内屏正常进入 niri（AMD 核显）
  - 外接 KTC 黑屏（正常，VM 启动后才亮）
  - lspci -nnk -d 10de:2d19 显示 vfio-pci
  - ls /dev/vfio/ 里有 14

如果仍然蓝屏：
  1. 重启选 “CachyOS (Host GPU, no passthrough)” 进入 host 模式。
  2. 删除修复：
       sudo rm -f /etc/systemd/system/drm-module-load.target
       sudo rm -f /etc/systemd/system/drm-wait-nvidia.service
       sudo rm -f /usr/local/bin/check-host-gpu-mode.sh /usr/local/bin/wait-nvidia-drm.sh
       sudo systemctl daemon-reload
  3. 把日志发我：journalctl -b -1 -k | tail -200
============================================================
EOF
