# 小米路由器 R2D 整机软件与内核清点报告

- 设备：`root@192.168.3.2`（MiWiFi-R2D，固件 `2.25.209`）
- 采集时间：2026-11-08 23:14–23:16（Asia/Shanghai），设备 uptime 36 分钟
- 方式：仅 SSH 只读命令；未升级、未装包、未改配置、未重启、未触碰 `/etc/config/samba`、未动 `/userdisk/data` 与正在运行的 SMB
- 说明：本报告所有版本号均来自设备命令输出；无法从设备确认的项明确标注“无法确认”

---

## 一、结论先行

1. **官方固件已经没有更高版本可升。** 本机 `2.25.209` 是 R2D 开发分支的最末版（2018-10-17）；官方稳定分支 `2.24.11` 虽然发布时间更晚（2023-03），但版本号更低、属于另一条分支，不是“升级”。官方 CDN 三个包目前都还能下载。
2. **内核、C 库、Wi‑Fi/文件系统驱动是死结，不应动。** Linux 2.6.36 + uClibc 0.9.33.2 + 133 个厂商内核模块（含 5.7 MB 的闭源 `wl`、Tuxera `tntfs/tfat/texfat`）没有可替换的源码与配套工具链；动内核等于换整机固件，且会同时废掉 compat 层。
3. **真正可升级的空间只在“硬盘上的私有依赖树”。** 根分区只剩 20.1 MB，但 `/userdisk/data` 是独立的 931 GB 硬盘分区；Samba 4.0.21 → 4.25.1 已经用这种方式跑通，证明“新程序 + 私有 `.so` 放硬盘、不碰系统库”是这台机器唯一现实的升级模式。
4. **本机没有 WAN 口，公网不能直接打进来。** 它工作在无线 AP/旁路模式（`br-lan 192.168.3.2`，默认路由指向 `192.168.3.1`，无 WAN 地址）。真实暴露面是局域网（以及被防火墙规则部分放行的访客网）。
5. **安全上最该处理的不是 Samba，而是 22 端口的 Dropbear 2011.54 和 8443 的 OpenSSL 1.0.1j。** 139/445 已由 Samba 4.25.1 接管且只绑定 `192.168.3.2`；原厂 `nmbd 4.0.21` 却仍在跑 UDP 137/138。SambaCry（CVE-2017-7494）针对的是旧 `smbd`，本机旧 `smbd` 并未运行，不构成该漏洞的现实风险。

---

## 二、硬件与系统基线（实测）

| 项目 | 实测值 | 证据 |
|---|---|---|
| 内核 | `Linux 2.6.36 #3 MiWiFi-R2D-2.25.209 SMP PREEMPT Tue Oct 16 11:45:02 UTC 2018` | `cat /proc/version` |
| 内核编译 | GCC 4.8.2 20130603（prerelease），crosstool-NG 1.19.0 | `/proc/version` |
| CPU | 2 × ARMv7；`Hardware: Northstar Prototype`（Broadcom Northstar / R2D BCM4709 平台；固件包名 `brcm4709_r2d`） | `/proc/cpuinfo`、官方包名 |
| 内存 | MemTotal 254,448 kB，SwapTotal 262,140 kB | `/proc/meminfo` |
| 内核模块 | 133 个 | `wc -l /proc/modules` |
| 根分区 | `/dev/ubi1_0`，107.9 MB，已用 87.7 MB，**剩 20.1 MB（81%）**，只读 ubifs | `df -h`、`mount` |
| 系统数据分区 | `/dev/ubi2_0` 204.1 MB，已用 61.7 MB（31%）；同一卷同时挂载 `/data`、`/userdisk`、`/etc` | `df -h`、`mount` |
| 内置硬盘 | `/dev/sda1` 931.2 GB，已用 52%，挂载 `/userdisk/data` | `df -h` |
| 外接西数盘 | `/dev/sdb1` 931.5 GB，已用 43%，挂载 `/extdisks/sdb1` | `df -h` |
| NAND 分区 | `rootfs0/rootfs1` 各 128 MB；`os0/os1` 各 4 MB；overlay 240 MB | `/proc/mtd`、`/proc/partitions` |

> 需要纠正一个前提：这台机器**不是 16 MB 级 flash**。实测根文件系统容量 107.9 MB（对应 128 MB 的 `rootfs` 分区），剩余 20.1 MB。真正紧张的是剩余空间，不是总量。

关键驱动/模块（均为厂商闭源二进制）：

| 模块 | 版本/大小 | 作用 | 证据 |
|---|---|---|---|
| `wl` | 7.14.116（r549303 WLTEST，2018-10-16），5,689,440 B | Broadcom Wi‑Fi 驱动与固件接口 | `/proc/modules`、启动日志 |
| `et` | 48,196 B | Broadcom 以太网驱动 | `/proc/modules` |
| `dpsta` | 2,754 B | 双频/桥接辅助 | `/proc/modules` |
| `ctf` | 17,189 B | Cut-Through Forwarding | `/proc/modules` |
| `tntfs` | Tuxera NTFS 3015.1.29，429,592 B | NTFS 读写 | `/proc/modules` |
| `tfat` / `texfat` | 3014.1.24，167,655 / 170,253 B | FAT/exFAT | `/proc/modules` |

---

## 三、已装软件清单

`/bin`、`/sbin`、`/usr/bin`、`/usr/sbin` 中绝大多数入口是 busybox 软链接；以下为独立二进制/库的实测版本。

### 3.1 基础运行时

| 组件 | 版本 | 状态 | 证据 |
|---|---|---|---|
| BusyBox | **1.19.4**（2018-10-16 构建，154 个 applet） | 系统 init 与绝大多数命令 | `busybox` |
| uClibc | **0.9.33.2** | 全系统动态链接的 C 库 | `ldd --version`、`/lib/libuClibc-0.9.33.2.so` |
| libstdc++ | 6.0.18（GCC 4.8.2） | C++ 运行时 | `/lib/libstdc++.so.6.0.18` |
| OpenSSL | **1.0.1j（2014-10-15）** | 已被 `sysapihttpd` 实际加载；无 `openssl` 命令行 | `ssh -V`、`/proc/5753/maps` |
| OpenSSH | 6.1p1 | **仅客户端**（`ssh/scp/ssh-agent` 等），无 `sshd` | `ssh -V`、`ls /usr/sbin/sshd` |
| Dropbear | **2011.54** | SSH 服务端，监听 22 | `dropbear` 输出版本串 |

### 3.2 网络与服务组件

| 组件 | 版本 | 是否运行 | 说明/证据 |
|---|---|---|---|
| dnsmasq | **2.71** | **未运行** | `dnsmasq --version`；`ps` 无进程；`/proc/net/udp` 无 53 监听 |
| wpa_supplicant | **2.1-devel** | 未运行 | AP 模式由 Broadcom `nas`/`wl` 处理 |
| hostapd | 不存在 | — | `ls /usr/sbin/hostapd` 无 |
| iptables / ip6tables | **1.4.12.2** | 运行 | `iptables --version` |
| ipset | 6.20.1 | 运行 | `ipset --version` |
| nftables | 不存在 | — | 无 `nft` 命令 |
| iproute2 | `ss3.3.0` | — | `ip -V` |
| curl | **7.33.0**（PolarSSL 1.3.16、zlib 1.2.7） | 客户端 | `curl --version` |
| wget | BusyBox applet 1.19.4 | 客户端 | `which wget` |
| nginx（`sysapihttpd`） | **1.2.2** | 运行，80/8443 等 | `strings`、`/proc/5753/maps` |
| miniupnpd | 版本未暴露 | 未运行 | `ps` 无进程；`MINIUPNPD` 链为空 |
| minidlna | **1.1.0** | 未运行 | `minidlna -V` |
| shadowsocks-libev | **2.2.3**（`ss-server/ss-local/ss-redir/ss-tunnel`） | 未运行 | 二进制存在，`ps` 无进程 |
| uhttpd | 存在但未监听 | 未运行 | `ps` 无进程 |

### 3.3 Samba 家族（重点）

| 组件 | 版本 | 运行状态 | 证据 |
|---|---|---|---|
| 原厂 `samba_multicall` / `smbd` / `nmbd` / `testparm` | **4.0.21** | `smbd` **未运行**；`nmbd` **仍在运行** | `/usr/sbin/smbd -V` → `Version 4.0.21`；`ps` PID 3304 `/usr/sbin/nmbd -D` |
| compat 层 `samba-s5d` | **4.25.1** | 运行，PID 3093 | `samba-s5d -V` → `Version 4.25.1` |
| compat 层私有库 | `libgnutls.so.30.42.0`（具体上游版本**无法确认**）、`libnettle`、`libhogweed`、`libgmp`、Samba 私有 `.so` | 由 `samba-s5d` 加载 | `/proc/3093/maps` |
| compat 安装根 | `/userdisk/data/s7root/versions/1.0.3-r2d/root` | 版本 `1.0.3-r2d` | 目录与 `-V` 输出 |

要点：

- 139/445 由 **Samba 4.25.1** 提供，且只监听 `192.168.3.2:139/445`，不是 `0.0.0.0`；访客网无法直接连。
- **原厂 `nmbd 4.0.21` 仍在跑**（UDP 137/138，`0.0.0.0`），这是 Samba 家族里唯一还在服役的老组件；compat 树里已有 4.25.1 的 `nmbd` 二进制但未使用。
- 原厂 `smbd 4.0.21` 没有运行，因此 CVE-2017-7494（SambaCry）对本机不是现实风险。

### 3.4 其他库/组件（存在但与本次升级关系不大）

按库 SONAME 可见：`libxml2.so.2.7.8`、`libsqlite3.so.0.8.6`、`libz.so.1.2.7`、`libMagickCore-6.Q16.so.1.0.0`（ImageMagick 具体上游版本无法确认）、`libavcodec.so.53.8.0`、`libboost_*.so.1.54.0`；`Perl 5.10.0`；`libmbedtls.so.9`（具体版本无法确认）。

opkg 命令存在，但 `/usr/lib/opkg/status` 无已装包数据库；`/etc/opkg.conf` 指向 OpenWrt AA 12.09 的 `brcm4709/R2D` 路径，该 URL 现 301 到 `archive.openwrt.org` 后返回 **404**。**实际没有可用的包管理器。**

---

## 四、官方固件情况

通过小米官方升级 API（`api.miwifi.com/upgrade/log/latest`）与官方 CDN 实际请求核实：

| 分支/包型 | 最新版本 | 官方记录时间 | CDN 实测 | 体积 | 与本机关系 |
|---|---|---|---|---|---|
| R2D 开发版 | **2.25.209** | 2018-10-17 | HTTP 200 可下载 | 36,068,576 B | **本机当前版本；分支内无更高版本** |
| R2D 稳定版 | **2.24.11** | Last-Modified 2023-03-30 | HTTP 200 可下载 | 37,492,824 B | 发布时间更晚，但版本号更低，属另一分支，不是升级 |
| R2D U 盘刷机包 | 2.10.14 | 2016-01 | HTTP 200 可下载 | 33,344,716 B | 远古版本，且会格式化硬盘 |

结论：

- **“2.25.209 之上”没有新固件。** 官方下载页仍列出 R2D（“小米路由器 Pro”）的稳定版入口，开发版包也仍可通过官方 API/CDN 获取；但开发分支止于 2.25.209。
- 若把机器切到 `2.24.11`：版本号回退、跨分支，存在配置/插件/SSH 兼容风险；这不是推荐路径。
- 官方帮助页明确说明：**U 盘刷机会 reset 路由器并格式化硬盘**；普通的 OTA/手动上传升级不会。项目的既有结论是“OTA 会覆盖 `/etc`，compat 的 init 包装器被还原成原厂，139/445 回到原厂实现，需要重装 compat 层”。该结论**本次未做 OTA 实测**（只读任务，不升级），标注为“项目文档结论，未在本机复测”。
- `/userdisk/data` 位于独立硬盘 `/dev/sda1`，不在 NAND 上：**手动 OTA 理论上不抹掉它**；**U 盘刷机会按官方说明格式化硬盘，连同 `/userdisk/data/s7root`、compat 包与用户文件一起丢失**。

---

## 五、可升级性评估（本机约束下）

本机升级的现实模型是：**不替换系统库、不换内核；新程序与其私有 `.so` 全部放在 `/userdisk/data` 的私有目录里，用 `LD_LIBRARY_PATH` 启动。** Samba 1.0.3-r2d 就是这样做的。

| 组件 | 能否升 | 结论与理由 | 工作量（粗略） |
|---|---|---|---|
| Samba `nmbd` 4.0.21 → 4.25.1 | **能，且最容易** | compat 树里已有 4.25.1 `nmbd`；只需改启动接线并验证 NetBIOS 名称/发现行为。仍需变更窗口与回滚 | 0.5 人日 |
| Dropbear 2011.54 → 2022/2025 版 | **能** | 体量小，可交叉编译为 uClibc 动态或静态；但换 SSH 服务端有锁死风险，必须保留原 binary + 带外回滚 | 1–2 人日 |
| dnsmasq 2.71 → 2.90 | 能，但当前无收益 | 本机 AP 模式且 dnsmasq **未运行**，DNS/DHCP 由上游 `192.168.3.1` 提供；只有未来启用本机 DHCP/DNS 才需要 | 0.5–1 人日 |
| curl 7.33 → 8.x | 能 | 需配 mbedTLS/私有 OpenSSL 交叉编译；纯客户端，收益有限 | 1–2 人日 |
| minidlna 1.1.0 → 1.3.x | 能 | 当前未运行；仅在启用 DLNA 时值得做 | 1 人日 |
| OpenSSL 1.0.1j → 1.1.1/3.x（系统级替换） | **不可行** | `libssl.so.1.0.0/libcrypto.so.1.0.0` 的 ABI 被全系统消费；换库必须重编所有依赖者（nginx、OpenSSH 客户端等），等于重建发行版 | >10 人日，且高风险 |
| OpenSSL 私有新版（只给某个新程序用） | 能 | 不动系统库，只在新程序目录带私有 `libssl/libcrypto`；对现有 `sysapihttpd` 无效（它仍链系统库） | 2–4 人日 |
| nginx / `sysapihttpd` 1.2.2 | **不建议** | 这是小米 MiWiFi 管理 API 的定制 nginx，配置与模块与固件强耦合；替换会破坏 Web 管理/APP | 不可估，风险极高 |
| BusyBox 1.19.4 | 能但高危 | init、shell、所有 applet 都依赖它；升级失败等于设备不可启动 | 2–5 人日 |
| iptables 1.4.12.2 | 能但高危 | 需要与 2.6.36 厂商内核模块匹配；nftables 在这套内核上不可用 | 3–5 人日 |
| wpa_supplicant 2.1-devel | 不建议 | 当前未运行；AP 由 Broadcom `nas`/`wl` 闭源栈处理，替换无意义 | 2–3 人日 |
| 内核 2.6.36 | **不可行** | 无 BCM4709 BSP 源码/内核配置；`wl` 5.7 MB、`tntfs/tfat/texfat` 均是闭源、按此内核 ABI 编译的模块；换内核会让 133 个模块全部失效 | 不可行 |
| uClibc 0.9.33.2 | **不可行** | 所有二进制都链 `/lib/ld-uClibc-0.9.33.2.so`；换 C 库必须全量重编固件 | 不可行 |
| Tuxera NTFS / FAT 模块 | **不可行** | 闭源二进制内核模块，无源码、无重编条件 | 不可行 |
| Broadcom `wl` 驱动/固件 | **不可行** | 闭源，随原厂固件发布 | 不可行 |

### 明确属于“必须配套重建 C 库/内核才能动”的死结

1. **内核与内核模块**：`wl`、`et`、`dpsta`、`ctf`、`tntfs`、`tfat`、`texfat`、全部 iptables/ipset 扩展。
2. **uClibc 及其 ABI**：任何想链接 glibc、或依赖新内核 syscall（`getrandom`、`statx`、`seccomp` 等）的现代程序。
3. **`sysapihttpd`/MiWiFi 管理面**：与固件、证书、API 模块强耦合。
4. **系统级 OpenSSL**：1.0.1 → 1.1/3.x 的 ABI 断裂，必须重编所有消费者。
5. **原厂 `samba_multicall` 与 `/etc/config/samba` 语义**：属于 MiWiFi 集成层，compat 层已在不动它的前提下接管 139/445；不应反向改动。

---

## 六、安全角度：哪些是真能被打的

### 6.1 网络位置

- `br-lan = 192.168.3.2/24`，默认路由 `192.168.3.1`，**没有 WAN 地址**，无线为 AP 模式；访客网 `br-guest = 192.168.19.1/24`。
- 因此：**本机不直接面对公网**。只有上游 `192.168.3.1` 做了端口转发时，相关端口才会公网可达；这一点本机无法确认。

### 6.2 监听端口与真实可达性

| 端口/协议 | 服务与版本 | 监听地址 | 局域网 | 访客网 | 判断 |
|---|---|---|---|---|---|
| 22/TCP | Dropbear **2011.54** | `0.0.0.0`、`::` | 可达 | **可达**（见 6.3） | **高风险：版本 EOL；实测必须显式启用 `diffie-hellman-group14-sha1` 才能握手，现代 KEX 不可用** |
| 80/TCP | nginx **1.2.2**（`sysapihttpd`） | `0.0.0.0` | 可达 | **可达** | 中：管理面老旧，无 TLS |
| 8443/TCP | nginx 1.2.2 + **OpenSSL 1.0.1j**，`TLSv1/1.1/1.2` | `0.0.0.0` | 可达 | 不可达（访客默认拒绝） | **中高：TLS 仍开 TLSv1/1.1，库已 EOL** |
| 139/445/TCP | **Samba 4.25.1** | `192.168.3.2` | 可达 | 不可达（无监听） | 低：版本新；CVE‑2017‑7494 不适用 |
| 137/138/UDP | **nmbd 4.0.21** | `0.0.0.0`/广播 | 可达 | 部分可达 | 中：老 nmbd 仍在服役 |
| 1900/UDP、3478/UDP、988/UDP、42000+ 等 | `wps_monitor`、`stunserver`、`xqbc`、`eapd`、`acsd`、`nas`、`bcm_bsd` | 本机/`0.0.0.0` | 可达 | 多数不可达 | 低：小米私有发现/加速服务，非公网协议 |
| 53/UDP、53/TCP | **无监听**（dnsmasq 未运行） | — | — | 防火墙放行但无服务 | 无 |
| 8080/8384/8188–8198/8899/8999/7080 等 | nginx 1.2.2 的 MiWiFi 内部 API | `0.0.0.0` | 可达 | 仅 8999/8300/7080 放行 | 低–中：管理/发现面 |

### 6.3 防火墙的实际语义（重要）

`iptables -L INPUT -v` 显示：

```text
ACCEPT tcp * * 0.0.0.0/0 0.0.0.0/0 multiport dports 22,80,135:139,445 /* mixbox-firewall */
delegate_input all ...
```

这条规则在 zone 规则之前，对**任意入接口**放行 22/80/135–139/445。随后 `zone_guest_input` 虽然默认拒绝，但 22/80 已经先被放行，**访客网可以访问 SSH 与管理 Web（80）**；445 因监听绑定在 `192.168.3.2`，访客仍连不上。这是“访客隔离被部分绕过”的实际配置缺陷，属于低成本可修项（但本次任务禁止改配置，仅记录）。

### 6.4 理论 CVE 与“本机真能被打”

- **OpenSSL 1.0.1j**：已于 2016-12-31 停止维护。其历史问题包括 FREAK（CVE‑2015‑0204）、Logjam（CVE‑2015‑4000）、CVE‑2016‑2107（Lucky13）、CVE‑2022‑0778 等。本机是否可利用取决于谁在用它：
  - `sysapihttpd` 的 8443 确实加载了 `libcrypto/libssl.so.1.0.0`（`/proc/5753/maps`），且启用 TLSv1/1.1/1.2 → **这是 OpenSSL 在本机唯一真实的服务端暴露面**。
  - Dropbear **不链接** OpenSSL（`/proc/6121/maps` 只有 uClibc/libcrypt/libutil），所以 OpenSSL 漏洞不影响 22 端口。
  - `samba-s5d` 使用私有 GnuTLS，不用系统 OpenSSL。
  - OpenSSH 6.1p1 仅客户端，OpenSSL 风险只在主动出站时存在。
  - 具体到 CVE‑2022‑0778：服务端仅在解析攻击者提供的证书/参数时触发，而 nginx 配置为 `ssl_verify_client off`，本机该路径是否可利用**未验证**，不应直接判为“能打”。
  - DROWN 需要 SSLv2；配置只开 TLSv1/1.1/1.2，SSLv2 未启用，**该路径不成立**。
- **Dropbear 2011.54**：EOL，且客户端必须显式加 `KexAlgorithms=+diffie-hellman-group14-sha1` 才能握手（现代 KEX 不被接受）；存在多个 2016 年后才修复的 CVE（如 CVE‑2016‑7406/7407/7408）。它是本机**唯一对访客网也开放**的高价值服务，属于“真能被打”的第一优先级。
- **nmbd 4.0.21**：EOL。SambaCry 针对 `smbd`，本机旧 `smbd` 未运行，**不适用**；但老 nmbd 的 NetBIOS 解析面仍在 LAN 可达，属于中等风险。
- **nginx 1.2.2**：2012 年版本，厂商补丁状态无元数据可查；是否存在“确定可利用”的 CVE，**无法确认**。但它是管理面核心，不建议独立替换。
- **curl 7.33.0**：纯客户端；只有在主动访问恶意服务器时才构成风险，不是服务端暴露。
- **dnsmasq / wpa_supplicant / miniupnpd / minidlna / hostapd**：未运行或不存在，**当前不构成攻击面**。

---

## 七、分级结论

### 第一类：建议升级（低风险、收益明确）

| 项 | 动作 | 理由 | 工作量 |
|---|---|---|---|
| 1. `nmbd` 4.0.21 → 4.25.1 | 用 compat 树已有二进制替换原厂 nmbd，或确认其必要性后停用它 | 消除 Samba 家族最后一个老组件；139/445 已是 4.25.1 | 0.5 人日 |
| 2. Dropbear 2011.54 → 新版 | 交叉编译新版，私有目录部署；同时把 22 限制到 LAN | 当前唯一对访客网开放的老服务；旧 KEX 弱 | 1–2 人日 |
| 3. 收窄 `mixbox-firewall` 的 22/80 任意接口放行 | 加 `-i br-lan` 限制，恢复访客隔离 | 现状让访客网能 SSH/访问管理 Web | 0.5 人日（配置变更，需变更窗口） |
| 4. dnsmasq（仅当启用本机 DNS/DHCP） | 2.71 → 2.90，私有部署 | 当前未运行，暂无收益；启用时再升 | 0.5–1 人日 |

### 第二类：可升但成本/风险高（需评估）

| 项 | 结论 | 理由 | 工作量 |
|---|---|---|---|
| curl 7.33 → 8.x | 可做，优先级低 | 纯客户端；需私有 TLS 库 | 1–2 人日 |
| minidlna 1.1.0 → 1.3.x | 可做，仅在用 DLNA 时 | 当前未运行 | 1 人日 |
| OpenSSL 私有 1.1.1/3.x | 只能给“新程序”用 | 系统库不能换；对 `sysapihttpd` 无效 | 2–4 人日 |
| BusyBox 1.19.4 | 高危，不建议单独动 | init/shell/applet 全依赖，失败即变砖 | 2–5 人日 |
| iptables 1.4.12.2 | 高危 | 需匹配 2.6.36 厂商内核模块；nftables 不可用 | 3–5 人日 |
| wpa_supplicant 2.1-devel | 不建议 | AP 由闭源 `nas`/`wl` 处理 | 2–3 人日 |

### 第三类：不建议动（动了会破坏 compat 层或超出硬件约束）

| 项 | 原因 |
|---|---|
| **内核 2.6.36 与 133 个模块** | 无 BSP 源码/配置；`wl`、`tntfs/tfat/texfat` 是闭源 ABI 模块；换内核=换整机固件，compat 层与 SMB 全部失效，且有变砖风险 |
| **uClibc 0.9.33.2** | 全系统 ABI 基座；替换必须全量重编固件 |
| **系统级 OpenSSL 1.0.1j** | ABI 断裂，所有消费者需重编；不具现实性 |
| **`sysapihttpd` / MiWiFi 管理 API** | 定制 nginx 与固件强耦合，换掉会破坏 Web/APP 管理 |
| **原厂 `samba_multicall` 与 `/etc/config/samba`** | MiWiFi 集成层；compat 已在不碰它的前提下接管 139/445，反向改动只会增加回归 |
| **Tuxera NTFS/FAT、Broadcom `wl`** | 闭源二进制，无源码 |
| **USB 刷机路径（2.10.14）** | 官方明确会格式化硬盘，抹掉 `/userdisk/data` 与 compat 包 |

### 第四类：官方固件层面的唯一正解

**不升级，维持 `2.25.209`。** 这是 R2D 开发分支的终点；官方没有更高版本。若将来因系统损坏必须重刷：

1. 只走“手动上传同版本 OTA 包”，不做 U 盘刷机（后者格式化硬盘）。
2. 升级/重刷后 `/etc` 的 compat 包装器会失效，139/445 回到原厂实现；`/userdisk/data/s7root` 若在，可重装 `1.0.3-r2d` 恢复。
3. `2.24.11` 是另一条稳定分支（发布时间 2023-03），版本号更低，属于跨分支回退，不作为“升级”推荐；`2.10.14` U 盘包更不应使用。

### 为什么“内核不该动”要说清楚

- 这台机器的内核不是通用 OpenWrt 内核，而是 Broadcom BCM4709 的厂商 BSP：133 个模块里，Wi‑Fi（5.7 MB 的 `wl`）、NTFS/FAT、以太网加速（`et`/`ctf`/`dpsta`）都是**闭源、按 2.6.36 ABI 编译**的二进制。没有源码、没有内核配置、没有可用的同版本重建工具链，就没有“只升内核”的路径。
- 唯一能换内核的方式是刷另一版官方固件——而官方已经没有更高版本；换分支（2.24.11）是回退，风险大于收益。
- 2.6.36 确实非常老（2010 年），但在本机“无 WAN、服务面有限”的部署里，内核远程攻击面远小于 22/8443 上的用户态服务。**把 22 和 8443 的口子收紧、把能换的用户态组件换掉，比追求不可能的内核升级更有效。**
- 强行替换内核还会同时破坏 compat 层（SMB 依赖当前内核的 ABI 与模块），得不偿失。

---

## 八、无法确认 / 未做的事项

| 项 | 状态 |
|---|---|
| 官方 OTA 是否覆盖 `/etc` 并导致 compat 失效 | 项目文档结论，本次未实测（只读任务） |
| 上游 `192.168.3.1` 是否对本机做端口转发 | 无法从本机确认；因此“公网是否可达 22/80/8443”不能下定论 |
| nginx 1.2.2 是否存在确定可利用的 CVE | 无法确认：无厂商补丁记录/包元数据 |
| GnuTLS 私有库的具体上游版本（仅见 `libgnutls.so.30.42.0`） | 无法确认 |
| `libmbedtls.so.9` 的具体版本 | 无法确认 |
| CVE‑2022‑0778 在本机 8443 配置下是否可利用 | 未验证；`ssl_verify_client off`，不应直接判“能打” |
| 原厂 nmbd 的 NetBIOS 解析是否存在可利用漏洞 | 未做漏洞验证；仅按 EOL 版本与 LAN 可达性判为中风险 |

---

## 九、证据附录（本次实际执行的只读命令）

```sh
# 连接（旧算法）
ssh -i ~/.ssh/id_rsa_miwifi_r2d \
  -o KexAlgorithms=+diffie-hellman-group14-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.3.2

# 系统
cat /proc/version; cat /etc/openwrt_release; head -30 /proc/cpuinfo
wc -l < /proc/modules; cat /proc/modules; head -6 /proc/meminfo
df -h; mount; cat /proc/mtd; cat /proc/partitions

# 版本
busybox; dropbear; ssh -V; curl --version; dnsmasq --version
iptables --version; ip6tables --version; ipset --version; ip -V
minidlna -V; wpa_supplicant -v; ldd --version
/usr/sbin/smbd -V
LD_LIBRARY_PATH=/userdisk/data/s7root/current/lib:/userdisk/data/s7root/current/lib/private \
  /userdisk/data/s7root/current/sbin/samba-s5d -V
strings /usr/lib/libcrypto.so.1.0.0 | grep -i "OpenSSL 1"
strings /usr/sbin/sysapihttpd | grep -i "nginx"
ls -l /lib/libuClibc* /usr/lib/libssl* /usr/lib/libcrypto*

# 运行态与暴露面
ps; netstat -lntp; cat /proc/net/tcp; cat /proc/net/udp
iptables -L INPUT -n -v; iptables -L delegate_input -n -v
iptables -L zone_lan_input -n -v; iptables -L zone_guest_input -n -v
cat /proc/5753/maps; cat /proc/6121/maps; cat /proc/3304/maps; cat /proc/3093/maps
grep -nE "listen|ssl|8443|443" /tmp/sysapihttpdconf/sysapihttpd.conf

# 官方固件（本机侧只读 + 官方 API/CDN 探测）
curl -s "https://api.miwifi.com/upgrade/log/latest?typeList=R2DDEV"
curl -s "https://api.miwifi.com/upgrade/log/latest?typeList=R2DSTA"
curl -sI "http://bigota.miwifi.com/xiaoqiang/rom/r2d/brcm4709_r2d_all_ba6b5_2.25.209.bin"
curl -sI "http://cdn.cnbj1.fds.api.mi-img.com/xiaoqiang/rom/r2d/brcm4709_r2d_all_1148b_2.24.11.bin"
```

本次操作全程只读：没有升级、没有安装、没有写配置、没有重启；`uptime` 前后保持连续，SMB 进程 PID 3093 与 `/etc/config/samba` 未被触碰。
