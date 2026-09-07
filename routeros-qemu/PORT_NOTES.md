# RouterOS 插件 QEMU 化 — 后端移植说明

基线：早先的 crosvm 版 `routeros.sh`（2046 行，已不在本仓库）
产物：`ufi/routeros-qemu/routeros.sh`（QEMU 版）

## 为什么换 QEMU

RouterOS CHR 的 ARM64 镜像是 GPT + ESP（`RouterOS Boot`，内含 `BOOTAA64.EFI`）+
`RouterOS` 根分区，必须经 UEFI 引导。crosvm 没有 pflash/MMIO 固件路径，
`--block root=true` 无法引导它。QEMU 走 `-drive if=pflash` 加载 edk2 即可。

## 保留未改的部分（约 1400 行）

Android 网络接管层**一行未动**：`ros-br` 网桥、`ros-wan`/`ros-lan` 双 TAP、
四种 tether 模式（bridge/routed/proxyarp/directbr0）、`ROS_*` iptables 链、
IPv6 passthrough、policy routing 表 1000、network monitor、watchdog、
garp/ra6、takeover/untakeover、USB 驱动解绑与厂商 watchdog 暂停逻辑。

## 改掉的部分

| 位置 | crosvm | QEMU |
|---|---|---|
| 启动 | `crosvm run --block/--rwdisk` | `-drive if=pflash` ×2 + `virtio-blk-pci` |
| 网卡 | `--tap-name ros-wan --tap-name ros-lan` | `-netdev tap,ifname=…,vhost=on,queues=N` + `virtio-net-pci,mq=on` |
| 控制通道 | crosvm 控制 socket | QMP（`qmp.sock`） |
| 关机 | `crosvm stop` | QMP `system_powerdown` → `quit` → SIGKILL 三级 |
| USB | `crosvm usb attach/detach` | QMP `device_add/device_del usb-host` + `qemu-xhci` |
| vCPU 绑核 | `--cpu-affinity/--cpu-capacity/--cpu-cluster` | `taskset` 进程掩码 + QMP `query-cpus-fast` 逐线程 `taskset -p` |
| 串口 | `--serial type=file` | `-chardev socket`（`logfile=` 留日志，socket 供 ttyd/维护接入） |

配置键：`CROSVM_PATH`→`QEMU_PATH`，`CROSVM_EXTRA_ARGS`→`QEMU_EXTRA_ARGS`，
子命令 `crosvm-path`→`qemu-path`。VNC 未引入（RouterOS 远程配置）。

## 新增

`version` `firmware-path` `console-write` `maint` `sync-network` `forwards`
`disk-info` `disk-resize` `disk-reclaim` `backup` `backups` `restore-backup`
`delete-backup` `ttyd-restart` `ttyd-stop`

端口映射：QEMU 的 `hostfwd` 只存在于 user-mode netdev，本方案在 TAP 上，
所以改用独立 iptables 链 `ROS_UPRE` 做 DNAT 到 `LAN_GUEST_IP`，
可独立于固定的 SSH/Webfig 规则重新下发。TSV 格式与 UEFI 插件一致：
`enabled<TAB>name<TAB>proto<TAB>bind<TAB>hostport<TAB>guestport`。

## 异构核处理（E5 上的实测差异）

crosvm 版按 capacity 排序取前 N 个核，在 E5（A55×6 + A76×2）上 `VM_CPUS=4`
会选出 2×A76 + 2×A55 —— 跨微架构，`-cpu host` 会报
`Failed to put registers after init`。

QEMU 版改为**选能装下 VM_CPUS 的最大同构簇**（装不下就取最大簇并把 VM_CPUS
钳到簇大小并告警），显式 `VM_CPU_AFFINITY` 跨簇时直接报错
（`VM_CPU_ALLOW_HETERO=1` 可强制）。E5 实测：`cpus=4 cpu_list=0 1 2 3 mask=f`。

## 已在 E5 上验证

设备：E5 / ums9158_1h10 / 已刷 nVHE 补丁内核 / QEMU 10.0.2

- `version` / `qemu-path` / `firmware-path` / `disk-info` / `status` ✅
- `preflight` ✅ →
  `qemu=… firmware=… accel=kvm cpus=4 cpu_list=0 1 2 3 mask=f net_queues=4 cellular=sipa_eth0 mode=bridge`
- `maint`（隔离维护引导）✅ —— UEFI → CHR → 登录 → 执行 CLI → 干净关机
- `sync-network 192.168.42.253` ✅ 写盘并持久化；改成 `.250` 再改回 `.253`
  验证是替换而非叠加
- guest 自报 `board-name: CHR QEMU KVM Virtual Machine`、`architecture-name: arm64`

**未验证**：`start`（会创建 ros-br/TAP、下发 iptables、动热点），
需要你确认时间窗口后再跑。USB 直通的 QMP 路径也还没接真实设备测过。

## 三个实现坑（都已修，但你的 crosvm 版可能也中招）

### 1. `/system shutdown` 是交互式的

它会问 `Shutdown, yes? [y/N]:`。不回 `y` 就不会关机，维护进程只能等超时被杀，
下次启动 RouterOS 报 `router was rebooted without proper shutdown`。
你现在 JS 里的 `networkSyncCommands` 结尾只有 `/system shutdown`，没有 `y`。

### 2. 维护模式必须带网卡

`-nic none`（以及 crosvm 维护模式不加 `--net`）时 RouterOS 只有 `lo`，
`/ip address add … interface=ether1` 会失败：`input does not match any value of interface`。
现在给维护 VM 挂两块 `hubport` 空网卡（有链路、无连通、无 DHCP），
顺序与正式 VM 一致。

用 `-netdev user,restrict=on` 也能出网卡，但它自带 DHCP，
RouterOS 会拿到一个多余的动态 `10.0.2.15`，所以改用了 `hubport`。

### 3. 串口输入必须按提示逐行喂

一次性把整段脚本灌进串口不行 —— RouterOS 的 getty 逐行读 login/password，
提示符没出来之前到达的输入会被丢弃。现在改成：单条持久连接（FIFO + `nc -U`），
轮询控制台日志等 `CHR Login:` / `Password:` / `[admin@` 提示符，
再逐行发送（`MAINT_LINE_DELAY` 默认 3s）。

## 网卡分工（已定）

QEMU 按命令行顺序枚举网卡：

```
                    ros-wan（点对点，只连 Android）
  RouterOS ether1 ──────────────────────── 192.168.66.1  Android
                                                │ MASQUERADE (ROS_POST)
                                                └──→ sipa_eth0 蜂窝上网

                    ros-lan ──┐
  RouterOS ether2 ────────────┤ ros-br  LAN_HOST_IP
                              └── 网关模式下热点/USB/转网口也挂进来
```

**ether1 = WAN、ether2 = LAN**。`LAN_GUEST_IP` 落在 ether2。
旧插件里的 `interface=ether1` 是从 OpenWrt 插件抄过来的遗留，已修正。
两个名字仍可用 `ROS_WAN_IFACE` / `ROS_LAN_IFACE` 覆盖。

## WAN 侧：不是遗留，是没写完

`WAN_GUEST_IP=192.168.66.2` 在 crosvm 版里**只被 echo 打印过，从未下发**，
且 ros-wan 上没有任何 DHCP 服务器，所以 RouterOS 一直没有上行。
这条链路不能删 —— 网关模式的转发出口就是它，Android 侧
`ROS_FWD` / `ROS_POST` / `UPSTREAM_RULE_PRIO` / `HOST_ROUTE_PRIO`
全部挂在 `WAN_TAP` / `WAN_SUBNET` 上。

关键约束：`iptables -t nat -A ROS_POST -s "$WAN_SUBNET" -j MASQUERADE`
只翻译 `192.168.66.0/24`。客户端的 `192.168.42.x` 源地址如果原样送到
ros-wan，宿主不会 MASQUERADE，直接不通。所以 RouterOS 必须自己先 NAT。

`sync-network` 现在按模式写完整配置：

| | ether1 (WAN) | ether2 (LAN) | 默认路由 | RouterOS NAT |
|---|---|---|---|---|
| `STANDALONE=1`（默认） | 不配置 | `LAN_GUEST_IP/24` | `LAN_HOST_IP` | 无 |
| `STANDALONE=0`（网关） | `WAN_GUEST_IP/24` | `LAN_GUEST_IP/24` | `WAN_HOST_IP` | `srcnat out-interface=ether1 masquerade` |

### 实测

独立模式：

```
0 192.168.42.253/24  192.168.42.0  ether2  main
0  As 0.0.0.0/0      192.168.42.1  main    1
```

网关模式：

```
0 192.168.42.253/24  192.168.42.0  ether2  main
1 192.168.66.2/24    192.168.66.0  ether1  main
0  As 0.0.0.0/0      192.168.66.1  main    1
0  chain=srcnat action=masquerade out-interface=ether1
```

连跑两次 `sync-network` 后计数仍是 address=2 / static route=1 / nat=1，
不会叠加（地址先 remove 再 add，路由按 static 清，NAT 用 `:if [:len …] = 0` 守卫）。

---

# 前端插件

源码 `plugin.src.js` → `build.sh` → `ufi/【通用版UFI专用】RouterOS虚拟机管理(QEMU).js`

后端脚本以 base64 内嵌在插件里（沿用 UEFI 插件的做法），所以"仅更新脚本"
不需要重新下载资源包。构建时校验：`sh -n routeros.sh` + `node --check` 输出，
内嵌内容 sha256 与 `routeros.sh` 逐字节一致。

## 界面分区

运行状态（启动/停止/重启/预检/日志/开机自启）、安装与资源包、网络、
虚拟机资源、端口映射、USB 直通、虚拟磁盘与备份、串口终端、保存/卸载。

**没有 VNC** —— RouterOS 用 SSH / Webfig / WinBox 远程配置。
ttyd 保留但默认只监听 `127.0.0.1`，用于首次配置和救急。

沿用旧插件的约定：`LAN_GUEST_IP` 默认 `192.168.42.253`、
`LAN_HOST_IP` 取 `UFI_DATA.lan_ipaddr`、`/24` 固定、`STANDALONE=1` 默认、
`SSH_DNAT_PORT=2224` / `WEB_DNAT_PORT=8081`（与 OpenWrt 插件的 2223/8080 错开）。

改 `LAN_GUEST_IP` 或切换独立/网关模式时，插件自动停机 → 跑维护实例写盘 →
恢复原运行状态。是否恢复由设备侧的 `WAS_RUNNING` 决定，不依赖 UI 的旧状态。

## 资源包（B 方案，自包含）

`build-package.sh` 在设备上就地组装再拉回，避免 60MB 运行时来回传两趟，
也保证二进制与设备 ABI 一致。产物 `routeros-qemu-vm-arm64.tar.gz`（43.8 MB）：

```
routeros.img              CHR ARM64 磁盘
edk2-aarch64-code.fd      UEFI 固件
edk2-arm-vars.fd          UEFI 变量模板
qemu/usr/{bin,lib,share}  QEMU 运行时
garp ra6 kvm-probe ttyd   网络层辅助程序
```

安装器容忍打包时多一层顶层目录；**已存在的 `routeros.img` 不会被覆盖**
（更新资源包不会抹掉用户数据）。

## 本地安装 = 浏览器上传

`uploadFileKano()` 从你的 crosvm 版原样移植（它依赖的 `KANO_baseURL`、
`common_headers`、`createFixedToast`、`runShellWithUser`、
`validateAlphaAndNumber`、`t` 全是宿主全局，插件里只是调用）。

点「从本地上传安装…」→ 浏览器文件选择框 → POST 到 `/upload_img` →
落到 `UPLOAD_DIR` → 安装 → **删掉上传副本**（40+ MB，每次装都留一份很快就满）。

沿用了你原来的两道校验：`.img.gz` / 备份文件名直接拒绝（那是备份不是资源包），
体积不在 1 MB ~ 512 MB 之间拒绝。宿主缺 `uploadFileKano` 依赖时给明确提示而不是静默失败。

## 前端已验证

- 构建：内嵌后端 sha256 与源文件一致，JS 语法通过
- 状态探测脚本在设备上实跑，所有标记正确解析
  （`__INSTALLED__` / `__MGRVER__=2026090610` / `__STATUS__` / 配置块 /
  端口映射块 / 磁盘大小 / `__CPUS__=0..7` / `__MEM__=1454`）
- `usb list` 解析：VM 未运行时 `USB_SUPPORT=0`，符合预期
- **在 stub 宿主里真跑了一遍插件**：注册按钮 → 开窗 → 渲染 7966 字符 →
  33 个元素 id、25 个表单项全部绑定成功（任何一个 `querySelector` 返回 null
  都会抛异常），无报错、无错误 toast
- 表单 `data-key` 与 `CONFIG_KEYS` 交叉核对：25/40 可在界面改，无拼写错误；
  其余 15 个是路径 / MAC / machine / cellular 自动探测这类高级项，
  保存时从已存的 vm.conf 原值写回（`collectForm()` 以 `state.config` 为底），
  **手工改过的值不会被界面保存冲掉**
- 任务后台化：launch 立即返回（0s，不是阻塞 6s），日志与退出码都正确落地
- 真实资源包安装：解包 → 部署 → **保留已有磁盘**（sha256 前后一致）
- 安装后 `qemu-path` / `firmware-path` 都指向包内副本，
  `preflight` 通过，`sync-network` 用包内 QEMU 跑通，无残留进程

## 两个前端 bug（写的时候踩到，已修）

1. **任务后台化写错**：`nohup sh X > log 2>&1 ; echo $? > done &` 在 sh 里
   只把 `echo` 放后台，前半段仍然阻塞，长任务会把调用卡到超时。
   改成 `nohup sh -c 'A; B' &`，实测 launch 0s 返回。
2. **保存时的恢复判断用了 UI 旧状态**：原本把 JS 侧的 `wasRunning` 插进脚本，
   与脚本自己算的 `WAS_RUNNING` 混用。统一成设备侧判断。

## 仍未验证

- `start`（会创建 ros-br/TAP、下发 iptables、动热点）
- USB 直通的 QMP `device_add usb-host` 路径（没接真实设备）
- 浏览器上传那一段（需要真实 UFI 后台的 `/upload_img`），只验证了逻辑与守卫
- 插件 UI 没在真实 UFI 后台里点过；用 stub 宿主跑通了加载、开窗、渲染和全部事件绑定


---

# 实机 start 调试（三个真 bug）

`start` 终于在 E5 上跑通了。过程中暴露三个问题，都已修。

## 1. vhost-net 这台机器没有

```
qemu-system-aarch64: -netdev tap,...,vhost=on,queues=4:
  tap: open vhost char device failed: No such file or directory
```

`/dev/vhost-net` 不存在，`vhost_net` 既没编进内核也没有可加载模块
（`modprobe vhost_net` 无 module 配置目录）。原来 `vhost=on` 是写死的。

改成探测：新增 `VM_VHOST`（`auto` / `on` / `off`，默认 auto）。
auto 时看 `/dev/vhost-net` 在不在；写死 `on` 而设备没有会直接报错说明原因，
不再让 QEMU 抛一句难懂的话。`preflight` 现在会打印 `vhost=off`。

实测各组合（SIGTERM = 跑到被 timeout 杀掉，即成功）：

| TAP 模式 | netdev 选项 | 结果 |
|---|---|---|
| multi_queue | `vhost=off,queues=4` | ✅ |
| plain | `vhost=off` | ✅ |
| plain | `vhost=off,queues=1` | ✅ |
| multi_queue | `vhost=off`（单队列） | ❌ `could not configure /dev/net/tun: Invalid argument` |

最后一行说明：**队列数必须和 TAP 创建方式一致**。`setup_network` 在多队列
TAP 建不出来时会把 `EFFECTIVE_NET_QUEUES` 降到 1，所以 `net_args` 必须在
`setup_network` 之后再拼（现在就是这个顺序，已加注释说明不能挪）。

## 2. 启动失败会把宿主网络扔在半配置状态

原来 `start_vm` 里 qemu 起不来就 `rm -f PIDFILE; exit 1`，但 `setup_network`
早就建好了 ros-wan / ros-lan / ros-br、下了 policy routing 规则和 iptables 链。
用户那次失败后设备上残留：两个 TAP + 网桥 + nat/filter 各若干链 + 11 条 ip rule。

（万幸 `STANDALONE=1` 下 `sync_tether_network` / `sync_dhcp_block` 提前返回，
没碰热点，影响面有限。用 `stop` 清干净了 —— 它本来就是为这种情况设计的。）

现在失败路径会 `stop_ttyd` + `teardown_network` 再退出。

## 3. LAN 地址和 usb0 撞车，宿主路由走错网卡

`LAN_HOST_IP` 默认取 `UFI_DATA.lan_ipaddr` = `192.168.42.1`，
而这台机器的 **`usb0` 已经占着 `192.168.42.1/24`**。ros-br 再配同一个地址
同一个网段，内核就有两条等价路径：

```
$ ip route get 192.168.42.253
192.168.42.253 dev usb0 src 192.168.42.1     ← 走错了
```

结果 ping 不通（`-I ros-br` 绑定就通，3/3 ~2.7ms，说明虚拟机侧完全正常）。
更要命的是 SSH/Webfig/端口映射的 DNAT 目标是 `192.168.42.253`，
宿主路由错了这些转发也全都到不了虚拟机。

网关模式下热点/USB 口会被桥进 ros-br，是同一个二层，本来不冲突；
**独立模式不桥接，才暴露出来**。

修法是给客户机加一条 /32 主机路由钉住出接口：

```sh
ip route replace "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE"
```

`teardown_network` 里对应删掉。`LAN_BRIDGE` 在各模式下始终是客户机 LAN 侧
所在的接口（普通模式 ros-br、directbr0 模式 br0），所以四种模式都成立。

顺带一提：原版 crosvm 脚本里 `sync_proxyarp_tethers` 已经有这一行，
但只在 proxyarp 模式下用。现在提升成所有模式通用。

## start 实测结果

```
RouterOS VM started (PID 2394, WAN 192.168.66.2, LAN 192.168.42.253, SSH host port 2224)
running ... tether_mode=bridge bridge=ros-br ports=ros-lan net_queues=4
        standalone=1 ssh=localhost:2224 web=localhost:8081 cpu_list=0 1 2 3 ttyd=127.0.0.1:7682
```

- 串口走到 `MikroTik 7.24.2 (stable) / CHR Login:`
- 宿主 ping `192.168.42.253`：3/3，~1.1ms（不用绑接口了）
- 客户机端口：22 OPEN、80 OPEN、8291 OPEN；Webfig `HTTP/1.0 200 OK`
- `stop` → 路由、网桥、TAP、iptables 链全部清干净，再 `start` 可重复

## 仍未验证

- 网关模式（`STANDALONE=0`）的真实接管 —— 会动热点，需要单独安排
- USB 直通的 QMP `device_add usb-host` 路径
- 从外部客户端经 2224/8081 打 DNAT（宿主本机 loopback 走 OUTPUT 链，
  碰不到 PREROUTING 里的 ROS_PRE，测不了）

---

# 卸载按钮没反应

## 原因：依赖了一个你这版后台可能没有的宿主全局

我写的确认框用的是 `fixedConfirm()`。查了一下：

- 你的 **RouterOS 插件（crosvm 版）压根没用过 `fixedConfirm`** ——
  它自己实现了 `askCountdown()`，底层是 `createFixedToast()`
- 只有 **UEFI 插件**用 `fixedConfirm`，那可能是另一个后台版本

`fixedConfirm` 不存在时，`await fixedConfirm(...)` 抛 ReferenceError，
而它在 async 的 onclick 里 —— **Promise 静默 reject，按钮就是没反应**。
受影响的不止卸载：回收空间、恢复备份、删除备份、脚本更新提示全中。

## 修法

### 1. 自带确认框，不依赖宿主

新增 `confirmAsk()`，参照你的 `askCountdown` 做倒计时防误触，
优先用 `createFixedToast`，**没有就退回自建 overlay** —— 两个宿主全局都缺也能用。
卸载的倒计时给了 8 秒，文案标红说明不可撤销。

### 2. 所有点击回调套 `guard()`

```js
const guard = (fn, label) => async (...args) => {
  try { return await fn(...args); }
  catch (e) { console.error(...); toast(`${label}：${e.message}`, false); if (state.busy) setBusy(false); }
};
```

19 个按钮 + USB 的动态按钮 + 启动器按钮全部包上。**以后任何异常都会弹提示，
不会再出现"点了没反应"**；顺带把卡住的 busy 状态也解开。

`toast()` 自己也加了 try/catch —— 它是 guard 的报错通道，
自己抛异常会把要报的错又吞掉。

## 验证

改造 stub 宿主，**把 `fixedConfirm` 和 `createFixedToast` 都删掉**
（模拟你的环境），再点卸载：

```
confirm dialog shown, ok button: true        ← 退回自建 overlay 成功
toasts after uninstall click: [ 'green:已卸载' ]
uninstall reached the shell: YES             ← 命令真的执行了
```

修复前这条路径在 `await fixedConfirm` 就抛异常了，一个 shell 都发不出去。

---

# 备份路径改到 /sdcard/RouterOS_QEMU

不再和 UEFI 插件共用 `DroidVM_UFI`。后端 `BACKUP_ROOT`、插件 `BACKUP_DIR`
和安装器的 `mkdir` 都改了（可用 `ROS_BACKUP_DIR` 覆盖）。

实测：备份 → 列出 → 恢复 全通，产物
`/sdcard/RouterOS_QEMU/<名称>/{routeros.img.gz, vm.conf, .payload}`。
运行中备份会被拒绝（`请先停止虚拟机再备份`）。

## 改这个时暴露的两个真 bug

### 1. `backup_path_valid()` 可以路径穿越（严重）

原实现：

```sh
case "$1" in
    "$BACKUP_ROOT"/*) [ -z "$(printf '%s' "$1" | tr -d 'A-Za-z0-9_./-')" ] && return 0 ;;
esac
```

字符白名单里有 `.` 和 `/`，所以 `..` 合法。
`delete-backup /sdcard/RouterOS_QEMU/../DroidVM_UFI` 直接通过校验并
`rm -rf` 掉了 `/sdcard/DroidVM_UFI` —— **我自己测的时候真删了一次**
（里面只有四个空目录，UEFI 插件的实际数据在 `/data/local/uefi-vm`，没受影响，
目录树已按原属主 `u0_a134:media_rw` 重建）。

改成要求路径必须是 `BACKUP_ROOT` 的**直接子项**：单段、非 `.`/`..`、
不含 `/`、字符白名单。六种恶意路径全部拒绝，正常路径正常通过。

`restore-backup` 走同一个校验函数，等于同一个洞 —— 一起修了。

### 2. 就地覆盖管理脚本会把它写坏（严重）

`cp` 直接盖 `routeros.sh` 时，watchdog / network monitor 仍在执行它。
结果：`Text file busy`，脚本被写成 128018 字节的半成品，
`sh -n` 报 `syntax error: unexpected 'fi'`。

插件里的 `deployManager()`（"仅更新脚本"和安装都走它）原来是
`: > MANAGER` 再逐段追加 —— **一模一样的问题，而且先截断再写，更糟**。

改成写 `.routeros.sh.new` → `sh -n` 校验 → `mv -f` 原子替换。
rename(2) 是原子的：正在跑的进程继续用旧 inode，下次调用拿到新的；
内容不完整时直接删掉暂存文件，不会顶掉能用的旧脚本。

---

# 独立模式下客户端连不上 RouterOS

## 现象

热点 / USB 客户端 ping 不到 `LAN_GUEST_IP`，WinBox 也连不上。

## 两层原因

### 1. 二层不通（设计使然）

独立模式下 `sync_tether_network` 提前返回，**热点/USB 接口不会挂进 ros-br**。
所以：

```
ros-br 上只有:  ros-lan            ← RouterOS 在这
客户端在:       usb0 192.168.42.1/24 / wlan0 192.168.43.1/24
```

两个独立的二层域。客户端 ARP `192.168.42.253` 没人应答 —— **这是预期行为**，
独立模式本来就不接管客户端。想让客户端直连 `LAN_GUEST_IP` 必须切网关模式。

### 2. 端口转发的回包路径是断的（真 bug，已修）

按设计，独立模式下客户端应该走 UFI 地址 + 转发端口。但实测这条路也不通。

DNAT 命中了（`ROS_PRE` 计数器 2224 有 1 包、8081 有 5 包），
但 SNAT 规则 **0 包**：

```
0  SNAT  all  --  *  ros-br  !192.168.42.0/24  0.0.0.0/0  to:192.168.42.1
```

条件是 `! -s $LAN_SUBNET`。独立模式下 `LAN_HOST_IP` 就是 UFI 自己的
tether 地址，**客户端恰好落在 LAN_SUBNET 里面**，被这个 `!` 排除掉了。
于是 RouterOS 直接回包给 `192.168.42.160`，在 ether2 上 ARP 它，
而它在 usb0 上 —— 回包丢失。

修法：改按"这条连接是否被 DNAT 过"来判断，而不是按源地址网段：

```sh
iptables -t nat -A ROS_POST -o "$LAN_BRIDGE" -m conntrack --ctstate DNAT \
    -j SNAT --to-source "$LAN_HOST_IP"
```

精确命中端口转发的回包路径，同时不影响网关模式下同网段的真实客户端流量
（那里 RouterOS 需要看到客户端真实地址来做 DHCP / 防火墙）。
设备的 iptables 支持 conntrack match，不支持时会告警而不是静默失败。

## 顺带加了 WinBox 内置转发

RouterOS 主要靠 WinBox 管理，所以和 SSH / Webfig 一样给它一个内置转发：
`WINBOX_DNAT_PORT=8291` → `LAN_GUEST_IP:8291`。

## 实测（本机就是一台 USB tether 客户端，192.168.42.160）

修复前：

```
192.168.42.253      ping 100% loss     ← 二层不通，符合独立模式设计
192.168.42.1:2224   closed             ← 回包路径断了
192.168.42.1:8081   closed
```

修复后：

```
192.168.42.1:2224  -> OPEN
192.168.42.1:8081  -> OPEN
192.168.42.1:8291  -> OPEN
Webfig HTTP 200
```

## 用法

独立模式下从客户端管理 RouterOS，连 **UFI 的地址**，不是 `LAN_GUEST_IP`：

| 用途 | 地址 |
|---|---|
| WinBox | `<UFI地址>:8291` |
| Webfig | `http://<UFI地址>:8081` |
| SSH | `ssh admin@<UFI地址> -p 2224` |

（帮助页里也写了这段。）


---

# 上行（WAN）配置 — 实测修正

## 症状

装完之后 RouterOS 连不上网。

## 原因

我原先让**独立模式**的默认路由指向 `LAN_HOST_IP`（192.168.42.1，走 ros-br）。
这条路走不通，宿主侧两样东西都没有：

```
ip rule:     1050: from all iif ros-wan lookup sipa_eth0     ← 只有 ros-wan
iptables:    ROS_POST -s 192.168.66.0/24 -j MASQUERADE       ← 只翻译 WAN 网段
```

从 ros-br 出去的包既没有策略路由指向蜂窝口，也不会被 MASQUERADE，直接丢掉。

## 修正

**两种模式的上行都走 ether1（ros-wan）**，这条链路本来就有策略路由和 NAT，
而且不碰任何客户端：

| | ether1 (WAN) | ether2 (LAN) | 默认路由 | DNS | RouterOS NAT |
|---|---|---|---|---|---|
| `STANDALONE=1` | `WAN_GUEST_IP/24` | `LAN_GUEST_IP/24` | `WAN_HOST_IP` | `ROS_DNS` | 无（自身流量源地址就是 66.2，宿主已翻译）|
| `STANDALONE=0` | `WAN_GUEST_IP/24` | `LAN_GUEST_IP/24` | `WAN_HOST_IP` | `ROS_DNS` | `srcnat out-interface=ether1 masquerade` |

新增配置键 `ROS_DNS`（默认 `223.5.5.5,119.29.29.29`）——
ros-wan 上没有任何东西应答 DNS，必须给客户机写真实解析器。
界面「网络」卡片里可改，改动会触发停机写盘。

## 实测（冷启动后）

```
0  As 0.0.0.0/0        192.168.66.1  main   1
  DAc 192.168.42.0/24  ether2        main   0
  DAc 192.168.66.0/24  ether1        main   0

/ping 223.5.5.5   → sent=2 received=2 packet-loss=0%  TTL 54  25~50ms
:put [:resolve mikrotik.com]  → 159.148.172.205
```

## ttyd 两个 bug

1. 跳转地址用了 `TTYD_BIND`。那是**设备侧绑定地址**，不是浏览器可达地址 ——
   绑 `127.0.0.1` 时浏览器打开的是用户自己的电脑。改成一律用 `location.hostname`。
2. 默认绑 `127.0.0.1` 导致远程根本连不上，按钮形同虚设。改为默认 `0.0.0.0`，
   但**强制凭据**：安装时自动生成 `ros:<随机>`，后端对非 loopback 且无凭据的
   情况直接拒绝启动。实测 401 / 200 均符合预期。

## MANAGER_VERSION 必须跟着后端改

改了 `routeros.sh` 却没动 `MANAGER_VERSION`，插件就判断不出设备上的脚本已过期，
装旧插件会把新脚本覆盖回去（这次就是这么丢掉 WinBox 和 conntrack 规则的）。
**改后端必须同时提版本号。**

## 网关模式的 DHCP（新增）

切到 `STANDALONE=0` 时，宿主侧会**主动让位**：

```sh
# bridge_attach
ip -4 addr flush dev "$iface"           # 抹掉热点/USB 口的 IP
ip link set dev "$iface" master ros-br  # 挂进 ros-br
# sync_dhcp_block
iptables -A ROS_OUT -o <热点/usb/wlan> -p udp --sport 67 --dport 68 -j DROP
```

也就是说 Android 不再是那个网段的网关，DHCP 应答也被掐掉 —— 前提是
RouterOS 那头接手。但 CHR 出厂**只有 ether1 上的 DHCP 客户端，没有 server**
（早期用 `-netdev user` 测试时它拿到过一个 dynamic `10.0.2.15`，就是这个客户端）。

原来的 `sync-network` 也没配 server，三件事凑一起 = 客户端拿不到 IP，全部掉线。

现在 `sync-network` 按模式收发这组对象（固定名字 `rosq-lan-pool` /
`rosq-lan-dhcp`，只动插件自己建的，不碰用户手工建的）：

| | 网关模式 `STANDALONE=0` | 独立模式 `STANDALONE=1` |
|---|---|---|
| `/ip pool` | 建 `rosq-lan-pool` | **删除** |
| `/ip dhcp-server network` | 建（gateway/dns 都指向 `LAN_GUEST_IP`） | **删除** |
| `/ip dhcp-server` | 建 `rosq-lan-dhcp` on `ROS_LAN_IFACE` | **删除** |
| `/ip dns allow-remote-requests` | `yes` | 不动 |

**独立模式必须删**：那边 Android 恢复发 DHCP，如果 RouterOS 里还留着一个
server，同一个二层上就有两个 DHCP 服务器在抢客户端。

### 地址池会自动避开已用地址

`dhcp_pool_ranges()` 从 `LAN_GUEST_IP` 的 /24 推导，把宿主和客户机的末位
挖掉，最多切成三段。实测：

```
guest=.253 host=.1     -> 192.168.42.100-192.168.42.200
guest=.150 host=.1     -> …100-…149,…151-…200
guest=.150 host=.120   -> …100-…119,…121-…149,…151-…200
guest=.150 host=.151   -> …100-…149,…152-…200
guest=.100（池首）      -> …101-…200
guest=.200（池尾）      -> …100-…199
池只有一个地址且被占用   -> 空 → 直接报错，不下发
```

新配置键：`ROS_DHCP_ENABLED`(1) `ROS_DHCP_POOL_START`(100)
`ROS_DHCP_POOL_END`(200) `ROS_DHCP_LEASE`(1h)，界面「网络」卡片里可改。
`ROS_DHCP_LEASE` 会校验格式（`^([0-9]+[smhdw])+$`）—— 否则 RouterOS 会在脚本
中途拒绝这条命令，而 sync 只检查地址，会误报成功。

### 验证方式

没在设备上切模式（会断网）。用本地 harness 把 `sync_network_config` 的
脚本生成部分单独跑出来，两种模式的 CLI 都逐行核对过；`dhcp_pool_ranges`
的边界情况单独测了 8 组。**真机切换未测**，第一次切建议留 adb 兜底。

---

## 接口改名 ether1/ether2 → wan/lan

同步脚本开头先下发：

```
/interface set [find default-name=ether1] name=wan
/interface set [find default-name=ether2] name=lan
```

`default-name` 是只读属性，无论改名多少次都还是 `ether1`/`ether2`，所以这两条是
幂等的，也能修复仍在用旧名字的安装。哪块网卡是哪个由 qemu 参数顺序决定（`wan0`
netdev 在前），设备上核对过：`ether1` 的 MAC 是 `WAN_MAC`、`ether2` 是 `LAN_MAC`。

实测改名后 RouterOS 内部的引用**会自动跟随**（按 id 引用而非名字字符串）：

```
/ip firewall nat   chain=srcnat action=masquerade out-interface=wan
/ip dhcp-server    rosq-lan-dhcp  lan  rosq-lan-pool
/ip address        192.168.42.253/24 → lan   192.168.66.2/24 → wan
```

## 手机拿不到 IPv6：ra6 的 RA 生存期过短

现象：USB 上的笔记本有公网 IPv6，WiFi 上的手机全都没有。

抓包看 `ra6` 发出的 RA：

```
pref low, router lifetime 45s
prefix <运营商/64> [onlink, auto], valid 120s, pref 45s
（无 RDNSS）
```

**Android 15 起把 `accept_ra_min_lft` 设为 180 秒，生存期低于该值的 RA 整条丢弃。**
45s 远低于门槛，所以新手机等于从未收到过 RA；macOS 无此过滤，照常工作。

排除过的其他可能（都不是）：wlan0 上没跑 ra6、RA 没发出 wlan0、网桥挡组播、
Android 在 usb0 另发了更好的 RA、v6 转发路径断。两个口收到的 RA 字节级相同。

`ra6` 是剥符号的静态二进制，用法只有 `ra6 OUTPUT_IF ROUTER_IF PREFIX`，没有生存期
参数；`.rodata` 里也搜不到 RA 模板字节（值是代码里的立即数），无法安全 patch。

## managed 模式：客户机侧补完

`sync_network_config` 原先一条 `/ipv6` 都不下发，所以关掉直通等于客户端彻底没有
IPv6（Android 的 RA 被屏蔽、RouterOS 又不发）。现在网关分支按 `IPV6_PASSTHROUGH`
分流，managed 时下发：

```
/ipv6 settings set forward=yes accept-router-advertisements=yes
/ipv6 address add address=<ULA>::1/64 interface=lan advertise=yes comment="rosq-lan-ula"
/ipv6 nd add interface=lan ra-lifetime=30m advertise-dns=yes dns=<ULA>::1 comment="rosq-lan-nd"
/ipv6 nd set [find where interface=all] disabled=yes
/ipv6 firewall nat add chain=srcnat out-interface=wan action=masquerade comment="rosq-nat66"
```

独立分支与直通分支调用同一个 `sync_ipv6_teardown_cli`，与上面严格 1:1 对称。

几个实测得到的约束：

* **`accept-router-advertisements` 必须显式设 `yes`。** RouterOS 默认
  `yes-if-forwarding-disabled`，而 CHR `forward=yes`，等于不接受 RA —— WAN 口就
  拿不到公网 v6，NAT66 也就没有可用的源地址。
* **`/ipv6 nd` 不能按 comment 查找删除。** RouterOS 会用自己的状态文本覆盖该表的
  comment（实测 `find where comment="rosq-lan-nd"` 返回 0），所以按 `interface=`
  匹配；默认那条是 `interface=all`，不会被误伤。
* **`advertise-dns=yes` 必须配合显式 `dns=`。** 只开 `advertise-dns` 时 RA 里的
  RDNSS 生存期是 **0**（即"停止使用该 DNS"），并伴随
  `automatic dns option advertising is not started` 警告，重新下发 `/ip dns set`
  也不恢复。显式给 `dns=<ULA>::1` 后 RDNSS 生存期变为 1800s。
* **默认那条 `interface=all` 的 nd 要禁用**，否则 RouterOS 也会朝 WAN 侧（Android）
  宣告自己是路由器。

## 为什么 LAN 用 ULA 而不是运营商 /64

运营商只给一个 /64 且**没有 PD**，RouterOS 无法切出第二段给 LAN。

理论上可以让 LAN 直接用那个公网 /64（客户端拿公网地址、免 NAT66），但
`sync_network_config` 只能经 `maint_run`（离线维护引导）写入 RouterOS —— 前缀一变
就要重启一次虚拟机。实测该前缀确实会变（`a13:36d6` → `a20:2202`）。

ULA 则完全静态：RouterOS 侧写一次即可，WAN 侧的公网地址由 SLAAC 自动跟随前缀变化，
不需要任何配置推送。代价是 NAT66。

## 模式切换的状态跟踪

`sync_ipv6_passthrough` / `sync_ipv6_managed` 原先只比对前缀，于是**前缀未变而模式
改变时整段 teardown 被跳过**——两种模式把 `fe80::1`、`/64` 路由和策略规则挂在不同
接口上（ros-br vs ros-wan），跳过就会留下上一模式的接线，且旧的下游 ra6 进程继续
发 45s 的 RA，与 RouterOS 的 RA 打架。新增 `$VM_DIR/ipv6-mode` 单独记录模式，前缀或
模式任一变化都触发完整 teardown。

## 补丁 ra6：保住公网 IPv6

前一节的结论（"改由 RouterOS 发 RA"）只解决了生存期，代价是客户端从公网地址退成
ULA + NAT66。后来发现 ra6 其实可以精确补丁，于是公网地址能保住，managed 模式降级
为可选项。

三个生存期是三条相邻指令里的立即数，与抓包逐字段对得上：

```
mov  w11, #-0x7a              ; strb → [0xa6] = 0x86 = ICMPv6 type 134
mov  w10, #0x1840
movk w10, #0x2d00, lsl #16    ; stur → [0xaa..0xad] = 40 18 00 2d
                              ;   hop=64  flags=0x18(pref low)  router lifetime=45
mov  x9,  #0x403
movk x9,  #0xc040, lsl #16
movk x9,  #0x7800, lsl #48    ; stur → [0xb6..0xbd] = 03 04 40 c0 00 00 00 78
                              ;   前缀选项 type=3 len=4 plen=64 flags=onlink|auto valid=120
mov  w8,  #0x2d000000         ; stur → [0xbe..0xc1] = 00 00 00 2d  preferred=45
```

`patch-ra6.py` 按这 12 字节整体签名匹配（要求全文件唯一，实测偏移 `0x7cc`），
改成 1800 / 7200 / 3600 秒。字段是大端进包的，所以立即数取其字节交换值。

**编码上限 65535 秒**：valid/preferred 的 bits47:32 恒为 0（没有任何指令写它），
再大就需要多插一条指令，原地补丁做不到。1800/7200/3600 远够用。

实测（同一次抓包里前后两条）：

```
旧 ra6 :  router lifetime 45s,   valid 120s,  pref 45s
补丁版 :  router lifetime 1800s, valid 7200s, pref 3600s
```

之后 REDMI-K90（Android 15）在邻居表里出现 `2409:…:aa6c:…` 且 `REACHABLE`，
即手机拿到了公网 IPv6。

安装形态：不改仓库里的 `vendor/ra6`（保持上游原样），补丁在 `build-package.sh`
打包时施加；本地没有 vendor 副本时会从设备上把 ra6 拉下来补好再推回去。
`ra6_lifetime_state()` 扫描前 16 KiB 判断 patched / short / unknown，
`preflight` 输出 `ra6=…`，避免装了旧 helper 又静默踩同一个坑。

`pref low` 没有动（保持最小补丁面）。它的含义是：**任何以 medium 宣告的路由器都会
压过 ra6**。测试 managed 模式时 RouterOS 正是 medium，客户端于是把默认路由指向
RouterOS；清掉 RouterOS 的 v6 配置后，那条路由变成黑洞。

## managed 模式切回直通有 30 分钟空窗

RouterOS **只在某个接口上存在 `advertise=yes` 的地址时才广播 RA**（实测：删掉 ULA
地址后，即使 `/ipv6 nd` 条目还在、`ra-lifetime=0s` 也照样一个包都不发）。

所以 `sync_ipv6_teardown_cli` 删掉地址的瞬间 RouterOS 就静默了，**发不出撤销**；
而同步是离线维护引导，那一刻 RouterOS 根本不在网上，想撤也没机会。客户端会保留
RouterOS 作为默认 v6 路由器直到 `ra-lifetime` 到期（30 分钟）。

这条无解（除非把配置改成在线推送），已在 README 里写明，并把默认值定回直通。

## 开机自启延迟

开机脚本 `/sdcard/ufi_tools_boot.sh` 原来写的是 `routeros.sh start`，两个问题：
没有 `&`，会**阻塞**后续开机项直到虚拟机起来；而且开机瞬间蜂窝、热点、USB 都还在
初始化，`setup_network` 要和不断变化的接口赛跑。

新增子命令 `boot`：读 `BOOT_DELAY`（0-900 秒），大于 0 时把等待放进 detach 的子进程，
自己立刻返回，所以不管延迟设多久都不占开机流程。实测 `BOOT_DELAY=15` 时 `boot`
2 秒返回，15 秒后子进程调起 `start`，日志留下
`RouterOS VM is already running (PID …)`（当时虚拟机本来就在跑）。

前端把开机行从 `… start` 换成 `… boot`，并保留 `BOOT_LINE_LEGACY` 用于识别与迁移：

* 探测时两种写法都算"已开启"，否则旧安装升级后会在界面上显示成"未开启"
* 开关时先把两种写法都删掉再写入新行，所以不会出现两行各启动一次虚拟机

在真实开机脚本的副本上验证：旧行被换成新行、其它 9 行（含 UEFI 插件那条）原样保留、
重复开启幂等、关闭后清零。

校验前后端一致（整数、上限 900），后端实测拒绝 `abc` / `-5` / `901`、接受 `30`。

## 同步触发条件漏了新键

`networkChanged` 原本只比对 `LAN_GUEST_IP` / `STANDALONE` / `ROS_DNS` /
`ROS_DHCP_*`。加了 IPv6 之后没同步更新这个列表，于是在界面改 `IPV6_PASSTHROUGH`
再保存，配置写进了 vm.conf、界面提示"已保存"，**但从不下发到 RouterOS** ——
客户机行为完全没变。已补上 `IPV6_PASSTHROUGH` 和 `ROS_ULA_PREFIX`。

接口改名是另一种情况，补列表也解决不了：`ROS_WAN_IFACE` 不在表单里，
`collectForm()` 以 `state.config` 为底，而 `parseConfig` 在读取时就已经把
`ether1` 迁移成 `wan` 了 —— 两边永远相等，比不出差异。

所以加了「同步网络配置并重启」按钮（`syncNetworkNow`），主动跑一次同步。
同步任务本身抽成 `runSyncJob()` 由保存路径和按钮共用，避免两份会漂移的实现。

本地 dump 过它生成的 CLI，改名两行在最前、后续引用全部用 wan/lan：

```
/interface set [find default-name=ether1] name=wan
/interface set [find default-name=ether2] name=lan
/ip address add address="192.168.42.253/24" interface=lan
/ip dhcp-server add name=rosq-lan-dhcp interface=lan …
:if ([:len [/ip firewall nat find where … out-interface="wan" …]] = 0) do={ … }
```
