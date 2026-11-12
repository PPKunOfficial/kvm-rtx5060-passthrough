# KVM + RTX 5060 直通（机械革命蛟龙 / CachyOS）

目标：在 CachyOS 上用 KVM 运行 Windows 11，把 **NVIDIA RTX 5060 Laptop + HDMI 音频**
直通给虚拟机，外接 KTC 显示器由 Windows 使用；同时提供一个脚本，让**下一次开机**
可以把独显交还给 Linux。

## 硬件/系统现状（配置前）

| 项目 | 值 |
|---|---|
| 系统 | CachyOS（Arch 系），内核 7.3.1-1-cachyos |
| CPU | AMD Ryzen 7 8840HX（12C/24T，AMD-V 已开） |
| 核显 | AMD Radeon 610M（`0000:06:00.0`，amdgpu） |
| 独显 | NVIDIA RTX 5060 Laptop（`0000:01:00.0`，10de:2d19） |
| 独显音频 | `0000:01:00.1`（10de:22eb） |
| IOMMU 分组 | group 14 只含 GPU + 音频，隔离完美 |
| 复位 | `reset_method = flr bus`，支持 FLR |
| ReBAR | 8 GB BAR1，已开启 |
| 当前显示 | 独显直连：内屏 eDP-2 + 外接 DP-3 都在 NVIDIA 上 |
| 现有 Windows | 双系统，NTFS UUID `<你的 NTFS 卷 UUID>`（本方案不修改、不直通它） |
| 目标 Windows | 全新安装到虚拟机磁盘 |

## 关键前提

直通后宿主机不能再使用独显。因此必须把 BIOS 的显示模式从
**“独显直连 / Discrete”** 改为 **“混合输出 / Hybrid”**，让 AMD 核显接管内屏。
之后：

- Linux 桌面 = 内屏（AMD 核显）
- Windows 虚拟机 = RTX 5060 + 外接 KTC 显示器（DP 口物理接在独显上）
- 直通模式下外接屏在 Linux 下是黑的，VM 启动后才亮

## 文件说明

| 文件 | 作用 |
|---|---|
| `01-install-kvm.sh` | 安装 QEMU/libvirt/virt-manager/OVMF/swtpm，准备 ISO，配置 libvirt 默认网络 |
| `02-enable-vfio.sh` | 配置 vfio-pci、initramfs、内核参数、GRUB 双启动项；安装 `vfio-boot-mode` |
| `03-create-vm.sh` | 创建 128G / 8GB / 8 vCPU 的 Windows 11 VM（OVMF + TPM 2.0 + virtio + Spice） |
| `04-attach-gpu.sh` | 把 RTX 5060 + HDMI 音频挂给 VM（**已废弃，勿重跑**，会重复挂载） |
| `05-fix-drm-awaiter.sh` | 修复直通启动时 CachyOS 等待 `nvidia_drm` 导致的蓝色救援界面 |
| `win11.xml` | libvirt 域定义模板（已通过 schema 校验） |
| `win11-working.xml` | 最终可用配置参考（含 vBIOS + 假电池 SSDT + 磁盘） |
| `vfio-boot-mode` | 切换下一次启动：`host`（Linux 用独显）/ `vm`（直通，默认）/ `status` |
| `gpu-rtx5060-vbios.rom` | 从 `GB206.rom` 偏移 0x35800 提取的 64K vBIOS（PCIR 10DE:2D19，校验和 0） |
| `ssdt-battery.aml` / `.dsl` | 假电池 SSDT，**Code 43 的关键** |
| `13-fix-rom-ssdt-paths.sh` | 把 vBIOS/SSDT 安装到 `/var/lib/libvirt/images` 并改写域定义 |
| `14-usb-controller-passthrough.sh` | USB-C 控制器直通配置（GRUB + XML，配套 15） |
| `15-usb-controller-bind.sh` | 运行时把 `0000:06:00.3` 从 xhci 交给 vfio（**必须先拔扩展坞**） |
| `vmctl` | 双端控制工具：QGA 命令/文件传输/截图。`./vmctl help` |
| `GPU-PASSTHROUGH-NOTES.md` | **Code 43 全过程、根因分析与踩坑清单** |
| `README.md` | 本文件 |

> 显卡从"设备可见但 Code 43"到"nvidia-smi 正常"的完整过程，见
> [`GPU-PASSTHROUGH-NOTES.md`](GPU-PASSTHROUGH-NOTES.md)。

## 阶段 1：安装 KVM 环境

```bash
sudo bash ~/Projects/kvm-windows/01-install-kvm.sh
```

脚本会：

1. 安装 `qemu-full libvirt virt-manager edk2-ovmf swtpm virt-viewer dmidecode`
2. 启用 `libvirtd.service`
3. 把 `pp` 加入 `libvirt` / `kvm` 组（重新登录后生效）
4. 配置并启动 libvirt 默认 NAT 网络 `192.168.122.0/24`
5. 下载 `virtio-win.iso` 到 `/var/lib/libvirt/images/`
6. 把 Windows 11 ISO 复制为 `/var/lib/libvirt/images/win11.iso`

> 这一步不需要重启。完成后继续阶段 2。

## 阶段 2：BIOS 切换到混合输出

1. 重启，开机时连续按 **F2** 进入 BIOS（部分版本是 Del/F12）。
2. 找到 `Advanced` → `Display Mode` / `Graphics Configuration` / `显示模式`。
3. 从 `Discrete` / `独显直连` 改为 `Hybrid` / `Switchable` / `混合输出`。
4. `F10` 保存退出，启动回 CachyOS。

如果 BIOS 里找不到该选项：启动现有的 Windows，打开
**机械革命控制中心 → 常规设置 → 显示模式 → 混合输出**，重启回 CachyOS。

### 验证切换成功

```bash
cat /sys/bus/pci/devices/0000:01:00.0/boot_vga   # 应该是 0
cat /sys/bus/pci/devices/0000:06:00.0/boot_vga   # 应该是 1
niri msg outputs                                 # 内屏应该叫 eDP-1，走 AMD
glxinfo -B | grep -E 'OpenGL renderer|Vendor'    # 应该显示 AMD Radeon 610M
```

> 注意：切换后内屏可能短暂出现分辨率/旋转不对，这是 niri 连接器改名导致的；
> 配置里已经预先加了一份 `output "eDP-1"`，重新登录/重启 niri 后应恢复。

## 阶段 3：启用 vfio 直通

确认 `boot_vga` 检查通过后运行：

```bash
sudo bash ~/Projects/kvm-windows/02-enable-vfio.sh
```

脚本会：

1. 再次检查当前确实是混合输出（否则拒绝执行）
2. 备份 `/etc/default/grub`、`/boot/grub/grub.cfg`、`/etc/grub.d/40_custom`
3. 写入 `/etc/modprobe.d/vfio.conf`（让 vfio-pci 先于 nvidia/snd_hda_intel 加载）
4. 写入 `/etc/mkinitcpio.conf.d/20-vfio.conf`（把 vfio 模块放进 initramfs）
5. 给默认启动项加内核参数：
   `amd_iommu=on iommu=pt vfio-pci.ids=10de:2d19,10de:22eb`
6. 在 `/etc/grub.d/40_custom` 增加“宿主机显卡模式”启动项
7. 重建 initramfs 和 GRUB 配置
8. 安装 `/usr/local/bin/vfio-boot-mode`
9. 验证 GRUB/initramfs 配置并打印结果

然后重启：

```bash
sudo reboot
```

### 重启后验证

```bash
lspci -nnk -d 10de:2d19     # Kernel driver in use: vfio-pci
lspci -nnk -d 10de:22eb     # Kernel driver in use: vfio-pci
ls /dev/vfio/               # 应有 14
niri msg outputs            # 应只剩 eDP-1；DP-3 消失
```

如果黑屏/进不了桌面：

1. 重启，在 GRUB 菜单（5 秒内）选择
   **“CachyOS (Host GPU, no passthrough)”**。
2. 或按 `Ctrl+Alt+F2` 进 TTY 登录。
3. 回滚见文末“回滚”一节。

### 已知问题：直通启动出现蓝色 “Failed to load your GPU driver(s)”

现象：用默认直通项启动后，停在一个蓝色救援界面，日志里有：

```
NVRM: GPU 0000:01:00.0 is already bound to vfio-pci.
drm-module-load.target: Job drm-module-load.target/start timed out.
```

原因：CachyOS 的 `drm-module-awaiter-generator` 生成的目标同时要求
`amdgpu` **和** `nvidia_drm` 加载。直通模式下 GPU 归 vfio，`nvidia_drm`
不会加载，30 秒后 target 超时并触发 `drm-failure-handler`。
这不是 vfio 失败，硬件和绑定本身是正常的。

修复（已应用）：运行

```bash
sudo bash 05-fix-drm-awaiter.sh
```

它做了三件事：

- 用 `/etc/systemd/system/drm-module-load.target` 覆盖生成的目标
- 保留对 `amdgpu` 的等待，移除对 `nvidia_drm` 的硬等待
- 新增 `drm-wait-nvidia.service`：host 模式（cmdline 无 `vfio-pci.ids=`）
  等待 `nvidia_drm`；直通模式由 `ExecCondition` 跳过

回滚：

```bash
sudo rm -f /etc/systemd/system/drm-module-load.target \
           /etc/systemd/system/drm-wait-nvidia.service \
           /usr/local/bin/check-host-gpu-mode.sh \
           /usr/local/bin/wait-nvidia-drm.sh
sudo systemctl daemon-reload
```

## 阶段 4/5：创建 Windows 11 虚拟机、挂载 GPU

在 vfio 绑定验证通过后继续（脚本已生成）：

- `03-create-vm.sh`：创建 128G qcow2、OVMF + TPM 2.0、virtio 磁盘/网卡、
  Spice 虚拟显示，安装 Windows 11。
- `04-attach-gpu.sh`：把 `01:00.0` + `01:00.1` 挂给 VM。**已废弃，不要重跑**
  （会重复挂载设备）；当前 GPU 直通配置已固化在域定义里。

> 资源现状：**8 vCPU（8c1t，一对一钉在物理核 0-7）+ 12 GiB**。
> 宿主只有 22 GiB，给到 16 GiB 会让 Linux 只剩 200 MB 余量，不建议。
> 磁盘可用 `qemu-img resize` / `virsh vol-resize` 扩容。

安装 Windows 时需要从 virtio-win CD 加载 `viostor` 驱动才能看到虚拟磁盘；
详细步骤见 `03-create-vm.sh` 的输出。

> ⚠️ **装好 NVIDIA 驱动后仍然 Code 43？** 那是客户机缺 ACPI 电池设备，
> 不是驱动或 vBIOS 的问题。完整排查与修法见
> [`GPU-PASSTHROUGH-NOTES.md`](GPU-PASSTHROUGH-NOTES.md)。

## 模式切换脚本

```bash
sudo vfio-boot-mode status   # 查看当前 GPU 绑定 + 下一次启动设置
sudo vfio-boot-mode host     # 下次启动让 Linux 使用独显（vfio 关闭）
sudo vfio-boot-mode vm       # 下次启动恢复直通（默认启动项）
```

说明：

- `host` 模式**只对下一次启动生效**，之后自动回到直通模式。
- 该模式只切换 vfio 绑定，**不切换 BIOS MUX**；MUX 仍是混合输出。
  所以宿主机拿到的是“混合模式下的独显”，不是“独显直连”。
- `host` 模式下带 GPU 直通的 Windows VM **无法启动**（GPU 不在 vfio 手里）。
- 如果希望长期保持 host 模式，每次启动前运行一次 `host`，或修改 GRUB 默认项。

## 重要说明

- **外接屏归属**：直通后外接 KTC 由 Windows 独占；Linux 只有内屏。
- **Windows 激活**：全新 VM 的 SMBIOS 与物理机不同，OEM 数字许可证通常不会自动继承。
  请在 Windows 里用你自己的密钥激活；未激活的 Windows 11 功能受限但不影响直通。
- **反作弊**：部分带内核级反作弊的游戏会检测虚拟机，可能拒绝运行或封号；
  本方案不处理这类规避。
- **音频**：GPU 的 HDMI 音频随 GPU 直通；虚拟机还会有一个 Spice 模拟声卡，
  声音从宿主机播放。游戏耳机建议用 USB 直通。
- **网络**：默认走 libvirt NAT（`192.168.122.0/24`），宿主机当前默认路由是
  `ppp0/mihomo`，VM 的流量会经宿主机路由。需要低延迟/局域网联机时可再调。
- **双系统 Windows**：本方案不动现有 Windows 分区（NTFS UUID
  `<你的 NTFS 卷 UUID>`）；该分区目前被自动挂载在 `/run/media/<user>/...`，
  建议在 VM 使用期间卸载以避免误写。

## 关于 AtlasOS

- 技术上可以在 VM 里使用，但截至 2026-11，官方 **Atlas Playbook 0.5.0**
  只支持 Windows 11 **24H2（build 26100）/ 25H2（build 26200）**，
  **不支持 26H2**。当前 `win11.iso` 是 26H2，直接套 AtlasOS 属于未支持组合，
  可能安装失败或系统不稳定。
- AtlasOS 官方分发的是安装后运行的 Playbook（AME Wizard），不是官方 ISO；
  不建议使用来源不明的“AtlasOS ISO”。
- 如果确实要用：先安装官方 Windows 11 Pro/Enterprise（25H2），
  装好 virtio 驱动和 guest tools，再运行官方 Playbook。
  GPU 直通本身与是否使用 AtlasOS 无关。
- 注意：AtlasOS 会关闭 Defender、Windows Update 和部分服务，属于修改版系统；
  反作弊兼容性、安全性和可维护性需要自行权衡，建议先做 VM 快照/备份。
- 参考：<https://docs.atlasos.net>、<https://github.com/Atlas-OS/Atlas/releases>

## 回滚

### 只回滚 vfio（保留 KVM）

```bash
sudo rm -f /etc/modprobe.d/vfio.conf /etc/mkinitcpio.conf.d/20-vfio.conf
sudo cp -a /etc/default/grub.bak-<时间戳> /etc/default/grub
sudo cp -a /etc/grub.d/40_custom.bak-<时间戳> /etc/grub.d/40_custom
sudo mkinitcpio -P
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

备份文件在：

- `/etc/default/grub.bak-*`
- `/boot/grub/grub.cfg.bak-*`
- `/etc/grub.d/40_custom.bak-*`

### 临时绕过

重启时在 GRUB 菜单选择 **“CachyOS (Host GPU, no passthrough)”**，
或在默认项上按 `e`，删掉 `vfio-pci.ids=...` 后按 `Ctrl+X` 启动。

### 恢复独显直连

进 BIOS / 机械革命控制中心，把显示模式改回 `Discrete / 独显直连`。
（Linux 下没有 MUX 驱动，无法用脚本切换这一步。）

## 备注

- niri 配置已备份到 `~/.config/niri/config.kdl.bak-*`，并新增了一份
  `output "eDP-1"`（混合模式下 AMD 内屏）配置。
- 所有脚本都可以重复执行；vfio 脚本会先检查是否真的处于混合模式。
