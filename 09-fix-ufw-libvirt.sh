#!/usr/bin/env bash
# 允许 libvirt default 网络（virbr0）的 DHCP/DNS 和 NAT 转发通过 UFW。
# 用法：sudo bash 09-fix-ufw-libvirt.sh
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
    echo "未安装 ufw，无需处理。"
    exit 0
fi

echo "==> 放行 virbr0 入站（DHCP/DNS）"
ufw allow in on virbr0 comment 'libvirt default network DHCP/DNS'

echo "==> 放行 virbr0 转发（VM NAT 上网）"
ufw route allow in on virbr0 comment 'libvirt default network NAT forwarding'

echo "==> 当前状态"
ufw status verbose | sed -n '1,40p'
echo
echo "--- UFW 默认策略 ---"
grep -E 'DEFAULT_(INPUT|OUTPUT|FORWARD)_POLICY' /etc/default/ufw || true
echo
echo "--- 内核转发 ---"
sysctl net.ipv4.ip_forward
echo
echo "完成。VM 里应能通过 DHCP 拿到 192.168.122.x 并访问外网。"
echo "如果仍无网，在宿主机运行： virsh net-dhcp-leases default"
