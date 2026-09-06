# UFI RouterOS 虚拟机管理插件

在 **UFI（4G/5G 随身 WiFi）** 上用 QEMU + KVM 跑一台 MikroTik RouterOS CHR，并通过 UFI 后台的插件界面管理它。

支持两种形态：让 RouterOS 作为一台**独立设备**挂在旁边，或者让它**接管热点/USB 客户端**当主路由。

> 作者 [Enceka](https://github.com/enceka)

---

## 这是什么

UFI 是一类基于 Android 的随身 WiFi。这个项目把一台 RouterOS CHR 跑在它里面：

```
                ros-wan (点对点)
 RouterOS ether1 ─────────────── 192.168.66.1  Android ──→ 蜂窝上网
                                     (MASQUERADE)

 RouterOS ether2 ─── ros-lan ─── ros-br  192.168.42.1
                                    │
                                    └─ 网关模式下：热点 wlan0 / USB usb0 也挂上来
                                       客户端与 RouterOS 同一个二层
```

- **ether1 是上行**，对端只有 Android，走它的蜂窝口出网。
- **ether2 是客户端侧**，RouterOS 在这里是 `192.168.42.253`。

### 两种模式

| | 独立设备模式（默认） | 网关模式 |
|---|---|---|
| `STANDALONE` | `1` | `0` |
| 热点/USB 接口 | 不动，仍由 Android 管 | 摘掉 IP，挂进 `ros-br` |
| 客户端的 DHCP | Android 发 | **RouterOS 发**（Android 的应答被 DROP） |
| 客户端网关 | UFI 自己 | `192.168.42.253` |
| 怎么访问 RouterOS | 走端口映射 | 直连 `.253`，端口映射同时可用 |
| 切换风险 | 无 | **会短暂断掉所有客户端**，建议留 adb 兜底 |

独立模式下 RouterOS 自己能上网（NTP、更新、装包），但不碰你的客户端 —— 适合先装上试玩。

---

## 硬件要求

- **已 root** 的 Android UFI，arm64
- 内核支持 **KVM**（`/dev/kvm` 可用）
- 一个能装 JS 插件的 UFI 后台（本项目为其编写）

`/dev/vhost-net` 不是必需的 —— 没有时会自动退回 `vhost=off`。

---

## 安装

### 1. 装插件

把对应的 `.js` 装进 UFI 后台的插件目录：

| 文件 | 用在哪 |
|---|---|
| `【通用版UFI专用】RouterOS虚拟机管理(QEMU).js` | 一般 UFI |
| `【中兴UFI后台专用】RouterOS虚拟机管理(QEMU).js` | 中兴机型（直绑原生 `br0`） |

**同一台机器只装其中一个。** 两版共用 `/data/local/mikrotik` 和 `/sdcard/RouterOS_QEMU`，装两个会互相覆盖配置和磁盘。要换版先卸载再装。

管理脚本（`routeros.sh`）以 base64 内嵌在插件里，所以"仅更新脚本"不需要重新下载资源包。

### 2. 装资源包

资源包（约 44 MB）包含 QEMU 运行时、UEFI 固件、CHR 磁盘和几个辅助程序。插件界面里两种装法：

- **在线安装** —— 从配置的 URL 下载
- **从本地上传安装** —— 浏览器选文件上传，装完自动删掉上传副本

安装器**不会覆盖已有的 `routeros.img`**，也**不会重置已有的 `vm.conf`** —— 升级资源包不会抹掉你的 RouterOS 密码、DNS、端口等设置。

装完先点「**运行预检**」，再点「启动」。

---

## 怎么连上 RouterOS

**独立模式**下客户端和 RouterOS 不在同一个二层，`.253` 是 ping 不通的（设计如此）。连 **UFI 自己的地址**：

| 用途 | 地址 |
|---|---|
| WinBox | `<UFI地址>:8291` |
| Webfig | `http://<UFI地址>:8081` |
| SSH | `ssh admin@<UFI地址> -p 2224` |

USB tether 时 UFI 地址一般是 `192.168.42.1`，走 WiFi 是 `192.168.43.1`。

**网关模式**下上面这些照样能用，同时也可以直接访问 `192.168.42.253`。

### 串口终端

界面里的「打开终端」走 ttyd。默认监听 `0.0.0.0`，但**强制要凭据** —— 安装时随机生成一组 `ros:<12位随机>`，可在界面里改。绑非 loopback 而凭据为空时后端会拒绝启动 ttyd，不会出现裸奔的控制台。

### 第一件事：设密码

CHR 出厂是**空密码 admin**，而 WinBox 端口已经映射到热点上了。装完请立刻：

```
/user set admin password=你的密码
```

设完在插件界面里把 `ROS_PASSWORD` 同步改掉，否则以后改 IP 时的离线维护模式登录不进去。

---

## 自己打资源包

仓库里**不含 CHR 镜像**（MikroTik 的版权物，不在这里分发），也不含第三方预编译二进制。你需要自己准备。

### 1. 下载 CHR 镜像

从 <https://mikrotik.com/download?architecture=arm64> 下载 `chr-<版本>-arm64.img.zip`（ARM64 CHR 从 RouterOS 7.15 起提供），解压出 `.img`。

### 2. 打包

```sh
cd routeros-qemu
./build-package.sh /path/to/chr-7.24.2-arm64.img
# 或者把镜像放成 ./routeros.img 再直接跑 ./build-package.sh
```

脚本会校验它确实是一个 GPT 磁盘镜像（MBR 签名 + `EFI PART`），然后**在设备上就地组装**再拉回来 —— 这样省得 60 MB 的 QEMU 运行时经 adb 来回传两趟，也保证二进制跟设备 ABI 一致。

产物 `routeros-qemu-vm-arm64.tar.gz` 的内容：

```
routeros.img            CHR ARM64 裸盘
edk2-aarch64-code.fd    UEFI 固件
edk2-arm-vars.fd        UEFI 变量模板
qemu/usr/{bin,lib,share}
garp ra6 kvm-probe ttyd
```

QEMU 运行时和 UEFI 固件取自设备上已有的安装（`/data/local/mikrotik` 或 DroidVM）。辅助程序优先用本地 `vendor/` 目录里的副本，没有就从设备上已装的插件里取。

需要 `adb` 在 PATH 上，设备已授权 root。

### 3. 改代码后重新构建插件

```sh
cd routeros-qemu
./build.sh
```

一份 `plugin.src.js` 出两个变体，实际差异只有 `const VARIANT` 一行 —— **改界面只改 `plugin.src.js`，两个插件一起更新**。

`build.sh` 会：

1. `sh -n routeros.sh` 先做语法检查
2. 把后端 base64 内嵌进 JS
3. `node --check` 验证产物语法
4. 记录产物 sha256；下次构建发现产物被手改过就**拒绝覆盖**（要覆盖用 `--force`）
5. 把 `plugin.src.js` 快照进 `.snapshots/`

---

## 目录结构

```
ufi/
├─ 【通用版UFI专用】RouterOS虚拟机管理(QEMU).js    构建产物，装这个
├─ 【中兴UFI后台专用】RouterOS虚拟机管理(QEMU).js  同上，中兴机型
└─ routeros-qemu/
   ├─ routeros.sh          后端管理脚本（设备上跑）
   ├─ plugin.src.js        前端源码（唯一需要改的界面文件）
   ├─ build.sh             生成上面两个插件
   ├─ build-package.sh     组装资源包
   ├─ vm.conf.default      默认配置参考（仅文档，不被读取）
   ├─ ui-preview.html      界面预览，浏览器直接打开
   └─ PORT_NOTES.md        移植笔记与踩坑记录
```

`ufi/routeros/` 是更早的 crosvm 版本，保留作参考。

---

## 备份

备份存在 `/sdcard/RouterOS_QEMU/<名称>/`，含压缩后的磁盘镜像和当时的 `vm.conf`。卸载插件**不会**删除备份目录。

---

## 已知限制

- **网关模式切换会断网。** 切换瞬间热点/USB 接口的 IP 被摘掉、Android 的 DHCP 被屏蔽，客户端要重新拿地址。第一次切请留 adb 兜底：出问题跑 `adb shell su -c '/data/local/mikrotik/routeros.sh stop'`，`teardown_network` 会把接口地址和 Android DHCP 都还回去。
- **`AUTO_TAKEOVER` 会禁用 UFI 自身的 IPv6。** 接管期间会下 `ip -6 rule add prohibit`（只覆盖 IPv4 路由）。热点客户端的 IPv6 不受影响。
- **USB 直通的 QMP 路径未经真实设备验证。**
- 中兴专用版**未在真实中兴机型上实测** —— 逻辑与 br0 预检已就位，但缺实机验证。

---

## 许可

本仓库只包含作者自己写的脚本与插件源码。

不包含也不分发：MikroTik CHR 镜像（版权归 MikroTik）、QEMU / edk2 / ttyd / crosvm 等第三方二进制 —— 各自适用其自身许可，请从上游获取。
