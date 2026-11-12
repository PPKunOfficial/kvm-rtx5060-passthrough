# RTX 5060 直通实战记录（Code 43 全过程与踩坑）

> 记录 2026-11-05 ~ 11-12 在 CachyOS + KVM + Windows 11 26H2 上把
> **NVIDIA RTX 5060 Laptop（10de:2d19）** 直通进虚拟机的完整过程。
> 最终结论：**Code 43 的根因是客户机 ACPI 里缺少电池设备**，不是 vBIOS、
> 不是 BAR 窗口、不是驱动装坏。修法是一张 161 字节的假电池 SSDT。
>
> 配置相关的通用步骤见 `README.md`；本文只记录"显卡从不动到能用"这一路。

---

## 1. 最终可用配置（先看结果）

### 1.1 libvirt 域（关键片段）

```xml
<features>
  <acpi/>
  <apic/>
  <hyperv mode='custom'>
    <relaxed state='on'/><vapic state='on'/>
    <spinlocks state='on' retries='8191'/>
    <vpindex state='on'/><runtime state='on'/><synic state='on'/>
    <stimer state='on'/><reset state='on'/>
    <vendor_id state='on' value='1234567890ab'/>
    <frequencies state='on'/><tlbflush state='on'/><ipi state='on'/>
  </hyperv>
  <kvm><hidden state='on'/></kvm>
  <vmport state='off'/>
  <smm state='on'/>
  <ioapic driver='kvm'/>
</features>

<devices>
  <!-- 关键 1：vBIOS。必须是 64K 的真实 option ROM，见 §3 -->
  <hostdev mode='subsystem' type='pci' managed='yes'>
    <source><address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/></source>
    <rom bar='on' file='/var/lib/libvirt/images/win11-gpu-vbios.rom'/>
    <address type='pci' domain='0x0000' bus='0x07' slot='0x00' function='0x0'/>
  </hostdev>
  <hostdev mode='subsystem' type='pci' managed='yes'>
    <source><address domain='0x0000' bus='0x01' slot='0x00' function='0x1'/></source>
    <address type='pci' domain='0x0000' bus='0x08' slot='0x00' function='0x0'/>
  </hostdev>
</devices>

<qemu:commandline>
  <!-- 关键 2：根端口窗口，BAR0 64M + BAR 对齐需要 -->
  <qemu:arg value='-global'/>
  <qemu:arg value='pcie-root-port.mem-reserve=134217728'/>
  <!-- 关键 3：假电池 SSDT，Code 43 的解法 -->
  <qemu:arg value='-acpitable'/>
  <qemu:arg value='file=/var/lib/libvirt/images/win11-ssdt-battery.aml'/>
</qemu:commandline>
```

### 1.2 生效证据

```
# 客户机内
> nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total --format=csv
NVIDIA GeForce RTX 5060 Laptop GPU, 621.14, 98.06.34.40.7a, 8151 MiB

# 设备状态
Status: OK    ConfigManagerErrorCode: 0    nvlddmkm: Running
显示: 2560x1440 @ 200Hz（外接 KTC，DP 物理接在独显上）

# 宿主侧
BAR0: 32 bit memory at 0x88000000 [0x8bffffff]        # 64M
BAR1: 64 bit prefetchable memory at 0x383000000000    # 8G ReBAR
BAR3: 64 bit prefetchable memory at 0x383200000000    # 512M
```

---

## 2. Code 43 的排查过程（按时间顺序）

### 2.1 阶段 A：常规手段（全部无效）

| 尝试 | 做法 | 结果 |
|---|---|---|
| A1 | 直通 GPU + HDMI 音频 | 设备能识别，驱动能装，**Code 43** |
| A2 | `10-fix-gpu-bar-window.sh`：根端口 `mem-reserve=128M` | 窗口从 64M 变 128M，但 BAR 仍 `not mapped` |
| A3 | `11-nvidia-code43-article-fixes.sh`：hyperv `vendor_id`、`ioapic kvm`、`<rom bar='off'/>` | 仍然 43 |
| A4 | `12-gpu-romfile.sh`：给 romfile | 仍然 43 |

这一阶段最重要的**错误认知**：以为 `virsh qemu-monitor-command --hmp 'info pci'`
里 GPU 的 BAR 显示 `not mapped` 是"没分配资源"的原因。

**实际上 `not mapped` 是结果**：Windows 在驱动初始化失败后把设备停用（memory
decode 关闭），QEMU 才把 BAR 解映射。判断依据：

- 同一时刻音频 function（`01:00.1`）的 BAR0 是正常 mapped 的；
- 宿主机 `power_state=D0`、`runtime_status=active`，GPU 供电正常；
- 后来在 Basic Display 状态下 `info pci` 显示 BAR0/1/3 全部 mapped。

### 2.2 阶段 B：vBIOS 的发现

宿主上这块 GPU：

```
Region 0: Memory at f8000000 (32-bit, non-prefetchable) [disabled] [size=64M]
Region 1: Memory at fa00000000 (64-bit, prefetchable) [disabled] [size=8G]
Region 3: Memory at fc00000000 (64-bit, prefetchable) [disabled] [size=32M]
Expansion ROM at fc000000 [disabled] [size=512K]
```

ROM BAR 有 512K 窗口，但 `dd if=/sys/.../rom` 读出来 **0 字节**——BIOS 没有把
vBIOS 放进去。所以必须自己提供。

用户给的 `GB206.rom`（1,961,983 字节）**不是 ROM**：开头是 `4c c0 ff ff`，
不是 `55 aa`。它是个容器，真正的 x86 VGA option ROM 在 **偏移 0x35800、64000 字节**：

```
55 aa                      ← 合法 ROM 头
55 aa 7d eb ...            ← size 字段 0x7d × 512 = 64000
PCIR @ 0x18 偏移处         ← vendor=0x10DE device=0x2D19（正是这块卡）
"Version 98.06.34.40.7A"   ← vBIOS 版本
字节和 mod 256 = 0         ← 校验和正确
```

提取：

```bash
python3 - <<'EOF'
d=open('GB206.rom','rb').read()
open('gpu-rtx5060-vbios.rom','wb').write(d[0x35800:0x35800+64000])
EOF
```

同一容器里 0x45200 处还有一段 98304 字节的 EFI 映像（PCIR vendor=0），**不需要**。

> 仓库里**不包含任何 vBIOS 二进制**（厂商固件版权 + 与本机硬件绑定），
> 请从你自己机器的 GPU-Z 转储里按上面三行提取。

把整个 1.9MB 容器当 romfile 用是错的：QEMU 会把 1.9MB 塞进 512K 的 ROM BAR，
guest 从 ROM 头读到的是 `4c c0 ff ff`。

验证 QEMU 是否真的加载：

```bash
virsh -c qemu:///system qemu-monitor-command win11 \
  '{"execute":"qom-get","arguments":{"path":"/machine/peripheral/hostdev0","property":"romsize"}}'
# → 65536（64K 向上取整到 2 的幂）；romfile 属性应指向你给的路径
```

### 2.3 阶段 C：干净重装驱动（仍然 43）

到这一步还是 43，于是怀疑驱动是在"设备没有资源"的状态下装的，留下了坏状态：

```powershell
pnputil /delete-driver oem20.inf /uninstall /force   # 当前 NVIDIA 显示驱动
pnputil /delete-driver oem16.inf /uninstall /force   # 旧版残留
# 重启 → 设备落回 Microsoft Basic Display Adapter
# 再静默安装官方包：
C:\Users\<user>\Downloads\621.14-notebook-win10-win11-64bit-international-dch-whql.exe -s -clean -noreboot
```

结果：**仍然是 Code 43**。说明不是驱动安装状态的问题。

### 2.4 阶段 D：根因——移动版驱动需要 ACPI 电池

决定性线索来自一个现象：**连 Microsoft Basic Display Adapter 都起不来**
（Code 10，`0xC01E0438`）。这不是 NVIDIA 驱动的问题，而是设备在客户机里
根本没法完成初始化。

移动版 NVIDIA 驱动会检查 ACPI 里是否存在 `PNP0C0A`（Control Method Battery）。
虚拟机默认没有电池设备，驱动就拒绝初始化移动 GPU → Code 43 /
`CM_PROB_FAILED_POST_START`。

修法是注入一张假电池 SSDT：

```bash
# 161 字节，签名 SSDT，OEM BOCHS/BXPCSSDT，
# 设备 \_SB.PCI0.BAT0，_HID = PNP0C0A，_STA 返回 0x1F
# 源码在 ssdt-battery.dsl，用 `iasl -tc ssdt-battery.dsl` 重编译过校验和
```

挂给 QEMU（`-acpitable`），**必须整机断电重启**（ACPI 表在 QEMU 启动时固定）：

```bash
virsh -c qemu:///system shutdown win11
virsh -c qemu:///system start win11
```

结果：设备 `Code 0`，`nvlddmkm` Running，`nvidia-smi` 正常。

> 这就是本次的核心结论：**vBIOS 解决了"ROM BAR 是空的"，SSDT 解决了 Code 43**。
> 两者缺一不可。

---

## 3. 双端联调：在 Linux 上一次看两边

排查过程中搭了一套"同时操控宿主和客户机"的通道，避免来回让用户截图/念日志：

- **客户机侧**：virtio-win 自带的 qemu-guest-agent 已经装好，XML 里本来就有
  `org.qemu.guest_agent.0` 通道。于是宿主可以直接：
  - `virsh qemu-agent-command win11 '{"execute":"guest-exec",...}'` 跑命令（SYSTEM 权限）
  - `guest-file-open/read/write` 传文件
  - `virsh screenshot` 截控制台画面
- **工具**：`vmctl`（见文件说明）。

```bash
./vmctl status                 # 域/agent/GPU 绑定/IP
./vmctl ps -- "Get-PnpDevice ..."   # 客户机 PowerShell
./vmctl run -- "ping -n 4 223.5.5.5"
./vmctl shot /tmp/w.png
./vmctl get 'C:\path\file.log' /tmp/
./vmctl pci                    # 宿主侧 info pci
./vmctl usb                    # USB 设备 → 控制器映射
```

几个能直接用的诊断动作：

```bash
# 客户机设备状态/资源
./vmctl ps -- "pnputil /enum-devices /instanceid 'PCI\VEN_10DE&DEV_2D19...' /resources"
# 设备重枚举
./vmctl ps -- "pnputil /disable-device '<id>'; pnputil /enable-device '<id>'"
# 宿主侧 QEMU 看到的 BAR
virsh -c qemu:///system qemu-monitor-command win11 --hmp 'info pci'
# 直接读 guest 物理地址（验证 GPU 是否真的在响应）
virsh -c qemu:///system qemu-monitor-command win11 --hmp 'xp /16xb 0x88000000'
```

---

## 4. 其它直通项与各自的坑

### 4.1 后置 USB-C 控制器（`0000:06:00.3`）

目标：把扩展坞（第二套键鼠）整个口给 Windows。

**坑 1：`managed='yes'` 会把整机挂死。** 连续两次 `virsh start` 直接硬重启主机，
journal 在重置前没有任何 panic/oops，ESP 的 dirty bit 被置位。

原因：

```
/sys/bus/pci/devices/0000:06:00.3/reset_method = pm      # 只有 pm，没有 flr/bus
```

libvirt 会先把 `xhci_hcd` 从控制器上解绑；而 USB-C 扩展坞（带 DP alt-mode
billboard）挂着时解绑，内核直接 hang。

**坑 2：GRUB 的 `vfio-pci.ids=1022:15b6` 没用。** 本机内核配置：

```
CONFIG_USB_XHCI_PCI=y     # 内置，不是模块
```

内置驱动在 PCI 枚举时就绑定，vfio-pci 在 initramfs 里再加载已经晚了
（独显能抢到是因为 nvidia 是模块、initramfs 里根本没加载）。

**可行做法**：运行时绑定，且**必须先拔掉扩展坞**：

```bash
sudo ./15-usb-controller-bind.sh status   # 有设备挂着会提示
sudo ./15-usb-controller-bind.sh bind     # driver_override=vfio-pci + unbind + bind
virsh -c qemu:///system start win11
# 起来后把扩展坞插回去，Windows 热插拔识别
```

域定义里对应 `managed='no'`——万一是 xhci 持有，只会干净地启动失败，不会挂内核。
绑定是运行时的，**宿主每次重启都要重做**。

### 4.2 物理磁盘（`nvme0n1`，裸机 Windows 盘）

**坑：只传分区不行。** `/dev/nvme0n1p3` 传进去，Windows 看到的是一个从偏移 0
开始的裸块设备、没有 MBR/GPT，Disk Management 显示"未初始化"，不给盘符
（Linux guest 能直接 mount，Windows 不行）。必须传**整盘** `/dev/nvme0n1`。

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
  <source dev='/dev/nvme0n1'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

结果：Windows 里 Disk 1（GPT/Online），原 `C:` 显示为 `F:` 952G NTFS。

注意：

- 裸机 Windows 必须**真正关机**（快速启动/休眠会让 NTFS 脏，VM 写入可能损坏）；
- VM 运行时不要用裸机启动那个 Windows；
- libvirt 会把 `/dev/nvme0n1` 临时 chown 给 `libvirt-qemu`，VM 停止后还原。

### 4.3 性能：vCPU / 内存 / TGP

实测数据（VALORANT 对局中）：

| 指标 | 值 | 说明 |
|---|---|---|
| GPU 3D 引擎 | 34% | 不是 GPU 瓶颈 |
| GPU 功耗 | 23-28 W / 上限 50 W | 没撞功耗墙 |
| GPU 频率 | 1712-1912 MHz（max 3090） | 有余量 |
| 客户机 CPU | ~35% | 有余量 |
| 宿主 CPU | 4.4-4.6 GHz，Tctl 91°C | 睿频正常，偏热 |
| DPC / 中断 | 0.8% / 1.2%，MSI 已启用 | 干净 |
| 网络 | 客户机 15ms = 宿主 15ms | 不是网络 |

**TGP 天花板**：`nvidia-smi -q -d POWER` 显示 Default/Current 50 W、Max 115 W。
移动版 GPU 的默认 TGP 靠平台 EC / Dynamic Boost 抬升，虚拟机里没有那个 ACPI
设备（裸机上的 `nvpcf` 在 VM 里是 problem 0x1F），而且 `nvidia-smi -pl` 对
移动版 GeForce 直接报 "Changing power management limit is not supported"。
这是虚拟机里基本无法绕过的限制。

**内存**：宿主只有 22 GiB。给 VM 16 GiB 时宿主只剩 205 MB free / 1.7 GB
available（QEMU RSS 16.3 GB、754 MB swap），已降到 **12 GiB**，宿主回到
6 GB available。

**CPU**：最终 **8 vCPU（8c1t）+ 12 GiB + 一对一钉核**：

```xml
<vcpu placement='static'>8</vcpu>
<cputune>
  <vcpupin vcpu='0' cpuset='0'/> ... <vcpupin vcpu='7' cpuset='7'/>
  <emulatorpin cpuset='8-11,20-23'/>
</cputune>
<topology sockets='1' dies='1' clusters='1' cores='8' threads='1'/>
```

宿主机 12C/24T：0-11 是物理核、12-23 是 SMT 兄弟；给 guest 8 个物理核，
留 8-11 号核（及兄弟）给宿主和 QEMU 的 emulator 线程。

**已排除**：VBS/HVCI（`VirtualizationBasedSecurityStatus = 0`，没有嵌套 hypervisor）。

---

## 5. 踩坑清单

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | 开机黑屏、以为直通坏了 | Windows Update 正在装 | 等它装完；`virsh screenshot` 看画面 |
| 2 | `info pci` 里 GPU BAR `not mapped` | 驱动失败后设备被停用 | 是结果不是原因；看音频 function 是否 mapped |
| 3 | NVIDIA 音频 BAR 读全 `ff`，以为卡死了 | HDA codec 空闲时不响应 | 读 BAR0 的 `0x1b6000a1` 才是判据 |
| 4 | `GB206.rom` 不是合法 ROM | 是容器，ROM 在 0x35800 | 提取 64000 字节 |
| 5 | romfile 放在 `/tmp` 重启后 VM 起不来 | `/tmp` 是 tmpfs | 放 `/var/lib/libvirt/images/` |
| 6 | 把 1.9MB 容器当 romfile | 超出 512K ROM BAR，头是 `4cc0ffff` | 用提取出的 64K ROM |
| 7 | 设备有资源了仍 Code 43 | 移动版驱动缺 ACPI 电池 | 假电池 SSDT (`-acpitable`) |
| 8 | Clean install 驱动无效 | 不是驱动状态问题 | 同 #7 |
| 9 | 连 Basic Display 都 Code 10 | 同 #7 | 同 #7 |
| 10 | 直通 USB 控制器后整机重启 | xhci 解绑时扩展坞挂着，`reset_method=pm` | 先拔坞，用 `15-...bind.sh` 运行时绑 |
| 11 | GRUB 加 `vfio-pci.ids=1022:15b6` 不生效 | `CONFIG_USB_XHCI_PCI=y` 内置 | 同上 |
| 12 | `virsh start` 报"无法获得域" | 裸 `virsh` 连 `qemu:///session` | 加 `-c qemu:///system` |
| 13 | 单传分区 Windows 不给盘符 | 没有分区表 | 传整盘 |
| 14 | 宿主内存只剩 205MB | 22GiB 里给 VM 16GiB | 降到 12GiB |
| 15 | `nvidia-smi -pl 115` 不支持 | 移动版 GeForce 限制 | 无法绕，接受 50W |

---

## 6. 日常操作流程

### 6.1 正常启动（直通模式）

```bash
# 宿主默认启动项已带 vfio-pci.ids=10de:2d19,10de:22eb
virsh -c qemu:///system start win11
```

### 6.2 要用后置 USB-C（每次宿主重启后）

```bash
# 1. 拔掉后置 USB-C 上的扩展坞
./15-usb-controller-bind.sh status     # 确认 "空的，可以安全 bind"
sudo ./15-usb-controller-bind.sh bind
# 2. 起 VM
virsh -c qemu:///system start win11
# 3. 插回扩展坞
```

### 6.3 把独显还给 Linux

```bash
sudo vfio-boot-mode host && sudo reboot   # 只对下一次启动生效
```

### 6.4 让 USB-C 还给 Linux（VM 关机后）

```bash
sudo ./15-usb-controller-bind.sh unbind
```

---

## 7. 文件说明补充

| 文件 | 作用 |
|---|---|
| `gpu-rtx5060-vbios.rom` | 从 `GB206.rom` 0x35800 提取的 64K vBIOS（校验和 0） |
| `ssdt-battery.aml` / `.dsl` | 161 字节假电池 SSDT（源码 + 编译产物） |
| `win11-working.xml` | 可用的完整域定义参考（路径为正式路径） |
| `13-fix-rom-ssdt-paths.sh` | 把 vBIOS/SSDT 装到 `/var/lib/libvirt/images` 并改写域定义 |
| `14-usb-controller-passthrough.sh` | 改 GRUB + XML 做 USB 控制器直通（配套 15） |
| `15-usb-controller-bind.sh` | 运行时把 `06:00.3` 从 xhci 交给 vfio（先拔坞） |
| `vmctl` | 双端控制工具（QGA 命令/文件/截图） |

---

## 8. 未解决 / 待确认

- **游戏帧率偏低（~100 FPS，GPU 仅 34%）**：已排除 GPU 算力、功耗墙、网络、
  VBS、DPC。下一步可用 PresentMon 抓 frametime，并确认游戏是否跑在
  "无边框窗口 + 帧率限制"模式；也要确认宿主 vCPU 在负载时是否维持睿频。
- **TGP 50W**：虚拟机内无法通过驱动提升，除非修改 vBIOS 功率表（高风险）。
- **反作弊**：不处理虚拟机检测规避（违反游戏条款且存在封号风险）。
