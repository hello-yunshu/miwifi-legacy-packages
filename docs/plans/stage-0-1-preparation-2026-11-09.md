# 阶段 0–1 执行记录与构建输入清单

- 目标设备：MiWiFi R2D / 固件 2.25.209
- 记录日期：2026-11-09（Asia/Shanghai）
- 范围：阶段 0 只读现状复核；阶段 1 固定候选源、工具链和回滚设计
- 安全边界：没有写路由器、安装软件、改设备配置、重启服务或运行候选程序；未运行测试
- 总状态：**阶段 0 已取得认证现场快照，完成判定待逐项核对；阶段 1 源码准备已完成，完整逐包构建配方与恢复入口仍待补齐，不进入阶段 2**

## 1. 阶段 0：现状复核

### 1.1 现场复采结果

2026-11-09 14:29 已使用专用 `id_rsa_miwifi_r2d` 成功连接 `root@192.168.3.2`，并通过 stdin 执行只读采集脚本。先前认证失败是未选择该专用密钥；本机 SSH Host 配置已修正并验证直接连接。没有读取或输出私钥内容。

最新证据为[只读现场快照](../evidence/2026-11-09-stage0/readonly-capture.txt)：固件 2.25.209、内核 2.6.36、uptime 15:51；Samba 4.25.1 从 1.0.7-r2d 私有树运行并持有 139/445，二进制 MD5 为 `52e105576e190ab6b977be419b3144fe`；原厂 nmbd 4.0.21 持有 UDP 137/138。ACL 的两条 LAN 跳转、8 条设备 DROP、guest DROP 位于宽泛 ACCEPT 前，cron 同步条目存在。

当前 homes=1，生产配置为 browseable=no、read only=no；私有 smbpasswd 为 0 字节，pdbedit 未列出用户。Unix home 路径已采集，实际内容访问未测试。系统 curl 7.33.0/PolarSSL 1.3.16；扫描范围中发现 `/etc/init.d/miDebug.sh` 引用，不能据有限深度扫描宣称全盘无其他调用者。

运行树未提供根目录 MANIFEST.md5；现场可核对二进制和配置哈希，包级 MANIFEST 使用安装时既有证据。uptime 表明启动早于 03:10 安装，故仍无升级后冷启动证据。以下旧表保留为历史缺口索引；与最新快照冲突时以上述现场结果为准。

### 1.2 最近已有设备事实与缺口

| 项目 | 最新可用证据 | 当前判断 | 仍需补采 |
|---|---|---|---|
| 固件/内核/ABI | 2026-11-08 清点：2.25.209 / Linux 2.6.36 / ARMv7 / uClibc 0.9.33.2 | 内核、无线、文件系统模块不做单包升级 | 当前 uptime、挂载/容量与启动后状态 |
| Samba/SMB | 2026-11-09 03:10 安装后快照与 03:xx restart-selfcheck：1.0.7-r2d、Samba 4.25.1、139/445 归私有实例、ACL 状态正常 | 已部署；guest IPv4 规则与 cron 自愈有记录 | 整机冷启动后进程、端口与 cron；当前 nmbd 的 `/proc/PID/exe`/版本仍无最终核验 |
| guest SMB | 2026-11-09 guest BSS 启用尝试失败：`WLC_SET_VAR(bss): Invalid argument`，`br-guest` 无接口成员 | 访客客户端端到端拒绝测试 BLOCKED；无线配置已恢复 | 只能在有可用 guest BSS/客户端的条件下补测，不对当前设备继续改无线 |
| `[homes]` | 2026-11-09 macOS `smbutil view -N` 列出 `homes`；UCI `homes=1` 且适配器生成 `[homes]` | 共享名可见；内容访问权限未知 | 有效用户/home/passdb 与 guest/有效用户的 tree-connect、读写测试 |
| nmbd | 2026-11-08 初始清点记录原厂 4.0.21 在 UDP 137/138；后续包装器仍走原厂路径 | 是否需要换成私有 Samba 4.25.1 nmbd 未证实 | 实时 PID、`/proc/PID/exe`、映射库、版本与 UDP 端口归属 |
| Dropbear | 2026-11-08 清点为 2011.54、TCP 22；访客可达来自历史快照 | 候选价值仍高；当前状态未复核 | 当前进程/监听、启动入口和回滚入口 |
| curl | 2026-11-08 清点为 7.33.0 + PolarSSL 1.3.16；客户端工具 | 仓库内没有发现调用点，但仓库外厂商脚本/用户脚本调用者未盘完 | 设备上全路径搜索及 `curl --version` 能力集 |
| MiniDLNA | 2026-11-08 清点为 1.1.0、当时未运行；后续记录证明 App/shareUpdate 可生成配置并由 supervisord 拉起 | 用户是否实际使用未知，条件候选 | 先确认是否使用；若使用，再采集生成配置、进程、索引和调用链 |
| dnsmasq | 2026-11-08 清点为 2.71、未运行、无 53 监听 | 本轮继续暂缓 | 只有未来决定让本机承担 DNS/DHCP 时再重做拓扑审计 |
| WebDAV | 设备清点未报告 WebDAV 服务 | 作为新增服务候选，不能当作已存在 | 当前端口占用、磁盘挂载路径/属主、接口/防火墙入口仍需只读核对 |
| `macfilter` 开关 | 2026-11-09 已有 App 将设备 `option lan` 在 yes/no 间切换的证据；兼容层只对 SMB 端口接入 | WebDAV 必须额外接入设备规则和 guest/WAN 拒绝 | 现场当前模式、目标设备条目与撤权时延复采 |

仓库级 `rg` 没有找到 curl 调用点；该结果仅覆盖此仓库，不能推断设备固件或用户磁盘上的脚本没有调用 curl。

## 2. 阶段 1：候选输入准备

### 2.1 目标构建环境

当前构建容器为 `miwifi-s1`，镜像 `ubuntu:24.04`，本地镜像 ID `sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`。

| 输入 | 记录值 |
|---|---|
| 交叉编译器 | `arm-xiaomi-linux-uclibcgnueabi-gcc` / crosstool-NG 1.19.0 / GCC 4.8.2 20130603 |
| 编译器 SHA-256 | `24636607478a89b5ac1638c6cddb1160cd7c4f4d341dab4bbc0882809ffb598a` |
| sysroot uClibc | 0.9.33.2，`libuClibc-0.9.33.2.so` SHA-256 `b48cc24dfafe21b3951497daf5ecc29bf80706ee4261dce5a69e7953c5cf0ed9` |
| QEMU | `/usr/bin/qemu-arm-static`，SHA-256 `47a63bcbdf3030cf42230a0521dae38ff9d62ba1268d5cafc7d8ccf7da7c761c` |
| 当前来源树 | `/work/sources` 有 Samba 4.25.1、GMP 6.3.0、Nettle 3.10.2、GnuTLS 3.8.13、zlib 1.4 的解压树；没有对应 Samba 4.25.1 源 tarball |
| 容器定义 | 仓库没有 Dockerfile/镜像构建配方；运行容器是可用环境，但当前容器状态本身还不能构成完整可复现环境定义 |

构建脚本 `recipes/samba/repro-build.sh` 会 `rm -rf /work/repro-work` 和指定的 `/work/repro-A` 或 `/work/repro-B`。阶段 2 前不得直接并行或重复调用该脚本；要先为候选构建准备隔离 workdir/输出目录，或给脚本添加不会碰现有构建记录的 ID 校验与路径门禁。

### 2.2 已锁定并暂存的优先源

候选源码、发布签名文件和发布公钥已放到构建容器：`/work/sources/stage0-1-20261109/`。`SHA256SUMS` 清单覆盖当前目录内所有源码归档、签名与公钥，容器中 `sha256sum -c` 可逐项复核。宿主与容器复算的源码 SHA-256 相同。尚未解包或编译。

| 候选 | 锁定版本/源码 | SHA-256 | 来源与完整性状态 | 阶段 2 输入建议 |
|---|---|---|---|---|
| Dropbear | 2026.94 `dropbear-2026.94.tar.bz2` | `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81` | `.asc` 验签通过；签名密钥完整指纹 `F734 7EF2 EE2E 07A2 6762 8CA9 4493 1494 F29C 6773`，发布者 Dropbear SSH Release Signing。密钥来自上游 releases 目录 | 单独私有 prefix；候选端口并行运行；保留原厂 22 与恢复通道。SFTP 服务器能力须单独确认，不能假定 Dropbear 自带完整 SFTP 子系统 |
| curl | 8.23.0 `curl-8.23.0.tar.xz` | `8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5` | `.asc` 验签通过；完整指纹 `27ED EAF2 2F3A BCEB 50DB 9A12 5CC9 08FD B71E 12C2` 与 curl 官方 Verify 页公布的 Daniel Stenberg 密钥吻合 | 只构建已盘点调用者需要的 HTTP/HTTPS 能力；TLS 使用单独私有依赖。调用者未确认前不部署；当前方案不保留 SMB URL，先盘设备实际参数 |
| WebDAV/lighttpd | 1.4.85 `lighttpd-1.4.85.tar.xz` | `18de51b393bac4a6827879e1a7ff377c169e414bae92cd245091d80fc2601d13` | 官方发布页 SHA-256 一致；`.asc` 本地验签 `Good signature`。签名子钥完整指纹 `ACAA 8EC8 C970 3EAE B349 258E 86EF B5FB AF16 D0F0`；主钥 `649D 0DD7 67FF 2062 02A7 6C51 58F1 4A78 6FE1 98C8`，与 Debian 开发者身份背书记录一致 | 上游发布 tarball 含 `autogen.sh` / `configure.ac`，没有生成后的 `configure`；容器现已具备 Autotools。`mod_webdav` 独立实例需私有 TLS、libxml2、SQLite；完整属性/锁需这两项。独立 LAN 端口和 `macfilter`/guest/WAN 规则未实现 |

WebDAV 完整属性与锁所需的依赖源码也已下载、解包检查并复制到同一容器目录；宿主和容器均复算校验值一致，尚未编译：

| 依赖 | 锁定版本/归档 | SHA-256 | 上游校验依据 / 构建备注 |
|---|---|---|---|
| libxml2 | 2.15.4 `libxml2-2.15.4.tar.xz` | `98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821` | 与 GNOME 官方 `.sha256sum` 一致；源码带 `configure`。lighttpd 需要用交叉编译配置关闭 Python、ICU 等非必要功能；不启用压缩依赖时先评估无 zlib 的最小构建 |
| SQLite | 3.54.1 `sqlite-autoconf-3540100.tar.gz` | `926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e` | 官方公布 SHA3-256 `b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4` 一致；源码包自带 amalgamation 和 `configure`，适合交叉编译，无需 Tcl 构建系统 |

容器为准备 lighttpd 的生成构建脚本，仅在本地 `miwifi-s1` Ubuntu 容器内安装了 autoconf 2.71、automake 1.16.5、libtool 2.4.7、m4 1.4.19、pkg-config 1.8.1；没有改路由器。lighttpd 公钥已导出为 `lighttpd-release-key.asc` 并同源归档放入该容器目录。验签在隔离的临时 GPG keyring 中完成，签名有效但本机 GPG trust 仍为 unknown；主钥完整指纹另与 Debian 开发者身份背书记录交叉核对。该容器是现存可写实例，安装步骤尚未固化到 Dockerfile/镜像配方，因此后续可复现构建前仍需记录安装命令或制作环境定义。此次只准备和检查源文件，未运行 configure、编译或测试。

Dropbear / curl / lighttpd 的本地 GPG 检查均报告 `Good signature`；GPG 显示 key trust 为 unknown，这是本机尚未做 Web of Trust 签署，不是签名数学校验失败。lighttpd 主钥指纹 `649D 0DD7 67FF 2062 02A7 6C51 58F1 4A78 6FE1 98C8` 与 Debian 开发者身份背书记录所载上游签名钥吻合；签名子钥指纹从 1.4.85 官方 `.asc` 包内读取。SQLite 官方同时公布 SHA3-256，本记录另列本地常用 SHA-256 供归档逐字节复核。

### 2.3 不进入当前构建准备的项

| 组件 | 当前处置 | 原因/重新进入条件 |
|---|---|---|
| Samba 本体 | 不重复构建 4.25.1；当前官方 stable 仍为 4.25.1 | 仅在上游出现更新 stable 或安全修复时重锁源/依赖/补丁；1.0.7 是兼容层版本，不是新 Samba payload |
| `nmbd` | 先复核进程；若确认为原厂 4.0.21，优先复用已验证的私有 Samba 4.25.1 树 | 当前运行身份未知；设备安装树还未重新读取。现有容器没有 Samba 4.25.1 tarball，不能在此声称能干净重建 |
| MiniDLNA / ReadyMedia | 条件暂停；候选上游为 1.3.3 | SF 记录 SHA-256 `39026c6d4a139b9180192d1c37225aa3376fdf4f1a74d7debbdbb693d996afa4`；只有用户确认实际使用后才下载/锁依赖并准备构建 |
| dnsmasq | 暂停，不准备源码 | 本机未运行且无 53 监听；若未来立项，应选经 2026 安全修复的 dnsmasq 2.92rel2，而不是未经修复的 2.92 |
| 内核、uClibc、BusyBox、iptables/ipset、系统 OpenSSL、管理 Web 栈 | 排除 | 固件/BSP/模块耦合，不属于可安全单包构建候选 |
| rclone WebDAV | 排除为本机首选 | 官方 Go Linux/ARM 支持要求高于 Linux 2.6.36；WebDAV 先评估 lighttpd C 实现 |

## 3. 回滚/部署设计已固定的约束

- 新候选只能装在 `/userdisk/data` 的版本化私有目录；不覆盖 `/usr/bin`、`/usr/sbin`、系统库或小米管理 Web 文件。
- 每个服务保留原厂入口，使用单独的启动/停止/状态命令、PID/log/state/config 路径和 MANIFEST；候选不在阶段 2/3 自动改成开机默认。
- Dropbear 必须先用备用端口并行测试，不能在没有恢复入口时接管 TCP 22。
- WebDAV 使用独立端口，root 只映射到批准的硬盘目录；`lan=no` 设备拒绝访问，`lan=yes` 仍需 WebDAV 认证，guest/WAN 默认拒绝；策略异常时服务关闭。
- 一次只部署一个组件；回滚以版本目录/原厂入口为目标，不改内核、无线和网络核心配置。

## 4. 完成判定

阶段 0 已取得认证现场快照；冷启动、访客客户端和 homes 内容访问属于后续验证，仍保留待验/BLOCKED。现场采集不等于这些功能已通过验收；独立恢复通道也不能由一次成功 SSH 登录证明。

阶段 1 目前只完成优先源码与工具链清点。必须按总计划的逐包准入表补齐可重建环境、完整依赖与准确构建命令、运行布局、安装/停止/卸载/回滚入口和持久数据兼容设计，再判定该包可进入阶段 2。

只读采集脚本 [`tools/stage0-readonly-capture.sh`](../../tools/stage0-readonly-capture.sh) 已在设备执行，输出保存在证据目录；没有部署候选服务。当前阶段数仍为 0–5，共 6 阶段。本轮只修订计划，不启动构建或部署。

## 5. 上游依据

- [Samba release history](https://www.samba.org/samba/history/)
- [Dropbear releases](https://github.com/mkj/dropbear/releases)
- [curl releases](https://curl.se/docs/releases.html) · [curl signature verification](https://curl.se/docs/verify.html)
- [lighttpd 1.4.85 release](https://www.lighttpd.net/2026/07/08/1.4.85/) · [WebDAV module](https://redmine.lighttpd.net/projects/lighttpd/wiki/Mod_webdav)
- [lighttpd 1.4.85 release metadata and signature link](https://redmine.lighttpd.net/versions/90) · [Debian developer key identity endorsement](https://nm.debian.org/process/1391/keycheck/)
- [libxml2 2.15.4 source directory](https://download.gnome.org/sources/libxml2/2.15/) · [official SHA-256 list](https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.sha256sum)
- [SQLite 3.54.1 chronology](https://sqlite.org/chronology.html) · [SQLite downloads](https://sqlite.org/download.html)
- [ReadyMedia 1.3.3 source](https://sourceforge.net/projects/minidlna/files/minidlna/1.3.3/)
- [dnsmasq 2.92rel2 security-fix announcement](https://lists.thekelleys.org.uk/pipermail/dnsmasq-discuss/2026q2/018471.html)
- [Go Linux/ARM minimum requirements](https://go.dev/wiki/Linux)
