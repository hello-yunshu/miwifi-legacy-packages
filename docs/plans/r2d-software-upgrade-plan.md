# R2D 软件升级总计划与可行性审计

- 基线设备：MiWiFi R2D / 固件 2.25.209 / ARMv7 EABI / uClibc 0.9.33.2 / Linux 2.6.36
- 计划日期：2026-11-10（第三版：恢复 A0、A1、B1–B6 八项正式候选；B1 于 11-10 接管 22）
- 本轮范围：候选范围维持八项不变；阶段 2/3 完成离线构建与隔离验证，阶段 4 完成维护窗口部署与一次整机冷启动，阶段 5 完成收口核对
- 状态：Samba 4.25.1 / 1.0.7-r2d 在设备运行；**nmbd 已切换为私有 4.25.1**（冷启动后仍归私有树）；**curl 仅 `miDebug.sh` 切到私有 HTTP-only，全量替换判定不可行**；**B1 已接管 22：原厂备份到位、2026.94 在 22 运行、看护与回退实测**；**B6 WebDAV 已上线：`192.168.3.2:5005`，Digest 认证，开机自启与冷启动均通过**；B4 MiniDLNA 本轮推迟、未触碰；B5 未触发
- 阶段 2/3 执行记录：[2026-11-09 构建与隔离验证](stage-2-3-execution-2026-11-09.md)
- 阶段 4/5 执行记录：[2026-11-09 维护窗口与收口](../evidence/2026-11-09-stage4/README.md)
- 事实来源：[2026-11-08 设备清点](../device-inventory-2026-11-08.md)、[固件 2.24.11 可行性比对](../firmware-2.24.11-feasibility-2026-11-08.md)、[Samba 发布就绪复核](../release-readiness-2026-11-08.md)
- 最新只读现场证据：[2026-11-09 14:29 快照](../evidence/2026-11-09-stage0/readonly-capture.txt)
- SMB 当前状态审计：[1.0.7-r2d 审计](../audits/smb-1.0.7-audit-2026-11-09.md)
- 说明：设备清点、固件可行性、阶段 0 快照与 SMB 审计已随本轮收口纳入版本控制，链接可直达；原始输出索引见 [证据目录](../evidence/README.md)。
- **路径变更（2026-11-10）**：设备开发产物已全部迁入 `/userdisk/data/.dev/`（见 `decisions.md` S14）。本文历史章节中的 `/userdisk/data/s7root`、`/userdisk/data/s8compat`、`/userdisk/data/dropbear-2026.94`、`/userdisk/data/r2d-cand` 分别对应当前的 `.dev/live/samba`、`.dev/live/s8compat`、`.dev/live/dropbear`、`.dev/candidates`；新命令请直接用新路径。

## 0. 本版改动

| 项 | 内容 |
|---|---|
| 阶段 2/3 执行 | 八项范围不变：B1/B2/B4/B5/B6 在私有树完成离线构建并做设备隔离验证，B3 复用现役 4.25.1 并记录哈希，A1 无上游新版本；B4 的构建依赖新增 ffmpeg 6.1.2（仅为最小静态库），不改变候选范围 |
| 阶段 4/5 执行 | 维护窗口内按“单项切换、单项验证、单项可回退”部署：B3 nmbd 切换 PASS（含 `samba restart` 与整机冷启动）；B2 curl 仅切 `miDebug.sh`；B1/B4 记 BLOCKED 并已退回；B5/B6 未触发。八项最终状态见 §11 |
| 候选范围 | **恢复八项正式候选**：A0、A1、B1、B2、B3、B4、B5、B6；每项都有目标、依赖与验收要点，不再以“政策表 / 决策门 / 明确不做 / 移出立项”降级或移出 |
| 保留的审计改进 | 阶段 0 回滚硬前置、证据路径与判定、容量预算、内联回归矩阵、构建序与部署序两张表、跨组件交互矩阵、Dropbear 接管点与超时恢复脚本、已删除 S1–S8 文档的断链修复 |
| 两张序表 | 八项全部纳入；按可执行性排序，真阻塞的条目标 BLOCKED 并写明原因，不删除 |
| 范围外 | 仅 §3 的系统级组件（内核、uClibc、BusyBox、iptables/ipset、系统 OpenSSL、管理 Web 栈、固件分支）保持不可单包升级的既有结论 |

## 1. 决策摘要

现有证据支持的路线是：**维持官方固件、内核、uClibc 和系统共享库；只在 `/userdisk/data` 上构建和安装可回滚的私有用户态程序。** `/userdisk/data` 是独立 ext4 分区（约 446 GB 可用）；根分区只剩 20 588 KB 且为只读 ubifs，不能把新依赖装入根分区。

### 1.1 候选总表（八项）

| 编号 | 组件 | 当前状态 | 目标 | 依赖 | 验收要点 |
|---|---|---|---|---|---|
| A0 | Samba 服务与 1.0.7 兼容层 | Samba 4.25.1 运行；139/445 归 `samba-s5d`；ACL 与 cron 自愈有设备证据 | 完成 1.0.7 收尾：冷启动核对、`homes` 隐藏并持久化（产品去留已定，见 `decisions.md` S15） | 阶段 0 回滚资产（§4.1） | 冷启动后端口/ACL/cron 保持；`homes` 配置与枚举一致、去留已有记录；访客端到端在无 BSS 时保持 BLOCKED |
| A1 | Samba 上游维护与 4.25.1 复核 | 设备与上游当前 stable 同为 4.25.1 | 上游出现新 stable 或安全修复时重锁源码、迁移 SDK 补丁并发布新 payload | A0 验收；构建容器与复现脚本 | 新版本通过 §5 全套回归并独立窗口部署；无新 upstream 时不产生部署对象 |
| B1 | Dropbear SSH 服务端 | 2011.54，TCP 22 对 LAN/访客网可达；候选 2026.94 源已锁定并验签 | 私有树构建候选，备用端口并行验证后接管 22 | 不依赖候选的回退通道（字节级备份 + 原厂二进制原位 + 独立看护 + `rollback-22.sh`） | 已接管：banner/密钥登录/进程归属/认证方法/管理面/回退链均实测；冷启动未重启验证 |
| B2 | curl | 7.33.0 + PolarSSL 1.3.16；仓库内未见调用点，设备侧只见 `/etc/init.d/miDebug.sh` 引用 | 先盘点调用方，再决定升级范围；如需升级，独立前缀 + 私有 TLS | 调用方清单与协议/选项需求 | 每个调用方比对退出码、输出与副作用；`/usr/bin/curl` 保持 7.33.0 |
| B3 | `nmbd` | 原厂 4.0.21（PID 2071 / `/usr/sbin/samba_multicall`）持有 UDP 137/138；私有 4.25.1 `nmbd` 已在现役树 | 评估并执行切换到私有 `nmbd` | 发现功能影响评估（电视/旧客户端） | 137/138 归私有树、单实例、`samba restart` 与冷启动后不被拉回原厂 |
| B4 | MiniDLNA / ReadyMedia | 1.1.0；配置启用，管理链可拉起；**按在用处理** | 构建 1.3.3 候选并验证 App/电视发现 | 私有依赖（libexif/libjpeg/libid3tag/flac/vorbis/sqlite）与私有树布局 | `shareUpdate` 生成配置、索引、电视发现、重启持久性、App 门控 |
| B5 | dnsmasq | 2.71；未运行、无 53 监听 | **低优先级候选**：仅当本机承担 DNS/DHCP 或出现明确的解析需求时构建 | 网络拓扑变更决定 | 构建 2.92rel2（含 2026 安全修复）并在隔离环境验证 DNS/DHCP/IPv6 与租约 |
| B6 | WebDAV | 设备无 WebDAV 服务 | 新增独立 WebDAV 实例（lighttpd `mod_webdav`） | 端口盘点、撤权语义定稿、看护进程设计、认证/TLS 方案 | 撤权时延与 SMB 语义一致或明确记载差异；策略异常 fail-closed；并发读写与掉盘回归 |

详细设计（B6）：[WebDAV 立项材料](webdav-proposal-unfiled-2026-11-09.md)。

### 1.2 优先级与依赖关系

1. **A0 先收尾**：它决定 Samba 侧的基线是否可信，也是 A1 的前置。
2. **B3 零构建、风险中**：产物已在现役树，唯一未决是发现功能影响。
3. **B4 在用、依赖较多**：构建链最长，但收益明确。
4. **B2 先盘点再定范围**：不盘点就构建属于盲目升级。
5. **B1 高价值高风险**：技术准备可先做，接管必须等回退通道落地。
6. **B5 低优先级**：当前没有部署对象。
7. **B6 功能新增**：前置未决项见 §2.8，未解决前不进入窗口。
8. **A1 由上游触发**：没有新版本就没有部署对象，但仍保留为候选。

### 1.3 回滚资产是硬前置

2026-11-09 清理后，设备只保留 1.0.7 现役树，`state/previous` 已删除，`rollback` 返回 6。**在该状态恢复并实测通过前，§4.3 中所有写入或重启类动作都不得开始。** 恢复方式与判定标准见 §4.1；安装器已加入门禁，防止在回滚指针悬空时静默升级。

## 2. 候选详述

### 2.1 A0：Samba 1.0.7-r2d 收尾

设备当前运行 Samba **4.25.1**；`1.0.7-r2d` 是兼容层/安装包版本，Samba payload 与 1.0.6 相同（SHA-256 `0101e0a7…eb2d58`），改动是访客网 SMB 规则与自愈。上游当前 stable 同为 4.25.1，因此**当前没有需要立即部署的 Samba 上游升级**。[Samba 发布记录](https://www.samba.org/samba/history/)

| 工作项 | 现状 | 判定方式 | 完成标准 |
|---|---|---|---|
| 升级后整机冷启动 | 现有证据只覆盖安装、`samba restart`、cron 同步；装包早于当前 uptime，无冷启动记录 | `uptime -s`、`readlink /userdisk/data/s7root/current`、`netstat -ltnp \| grep -E ':(139\|445) '`、`iptables -S INPUT`、`crontab -l \| grep diskacl-sync` | 冷启动后 139/445 仍归 `samba-s5d`；`diskacl-status` 为 `chain=present jumps=2 legacy_chain=absent guest=enforced`；cron 行存在；SSH 22 与 Web 80/8443 正常 |
| `homes` 运行时确认 | UCI `samba.@samba[0].homes=1`；适配器据此输出 `[homes]`（comment/browseable=no/read only=no/create mode=0750，无 `path`）；macOS `smbutil view -N` 列出 `homes`。已于 2026-11-10 改为隐藏（`homes=0`，枚举不再出现，见 S15） | `uci get samba.@samba[0].homes`；`testparm -s $ROOT/etc/smb.conf \| sed -n '/^\[homes\]/,/^\[/p'`；`smbutil view -N //guest@192.168.3.2` | 生产 smbd 实际加载的配置、渲染结果与枚举三者一致 |
| `homes` 产品决策 | 设备私有 `smbpasswd` 为 0 字节、`pdbedit -L` 无用户；内容访问只能在隔离实例建测试用户 | 决策记录（保留 / 隐藏 / 删除）；**已选隐藏**：`homes=0` 由 `/etc/init.d/samba-homes-fix`（START=97 + 有界复检）在冷启动后恢复，不改 payload、不递增包版本（S15） | 决策有书面记录；改动走独立窗口并回归普通共享、App 与回滚 |

访客网 SMB 端到端仍 BLOCKED：Broadcom 驱动 `WLC_SET_VAR(bss)` 失败，`wl1.2` 无法创建，`br-guest` 无成员。不得为补测继续改这台设备的无线配置。

### 2.2 A1：Samba 上游维护

A1 是正式候选，不是政策附注：上游一旦发布新 stable 或影响本构建所启用功能的安全修复，就执行下列动作，产出可部署的新 payload。

- **触发条件**：Samba 发布新 stable；或安全公告涉及本构建启用的模块/协议。
- **执行内容**：重核发布记录与源码签名 → 重锁源码与依赖 → 迁移 SDK 适配补丁（`cross-asn1`、`codegen-executor`、`generic-selection`、`reflink-guard`、`spawn`）→ 干净构建 → §5 全套回归 → 独立窗口部署。
- **依赖**：A0 收尾完成；构建容器与 `recipes/samba/repro-build.sh` 可用；阶段 0 回滚资产就绪。
- **验收**：新版本 `smbd -b` 前缀正确；两次构建 `sha256sum` 一致；§5 矩阵无回归；切换后可回滚。
- **当前状态**：上游 stable 仍为 4.25.1，无可部署对象；候选保留，等待上游触发。

### 2.3 B1：Dropbear 2011.54 → 2026.94

上游发布页当前列出 Dropbear 2026.94；设备上的 2011.54 实际监听 TCP 22。2026-11-09 的防火墙修订只覆盖 SMB 139/445，原厂规则仍对所有接口放行 TCP 22/80，因此 SSH 的访客网可达性尚未改变。[Dropbear 发布记录](https://github.com/mkj/dropbear/releases)

**收益**：直接更新对外提供 SSH 的旧组件；不必替换系统 OpenSSL（Dropbear 不链接它）；可放在私有目录，与 BusyBox/uClibc 隔离。

**代价与风险**

- SSH 接管失误会把维护者锁在设备外；仓库没有串口或带外控制台证据。
- 编译成功不代表可用：需验证 GCC 4.8.2 / uClibc 0.9.33.2 / Linux 2.6.36 下的 ELF、熵源、线程、主机密钥与认证行为。
- 算法默认值变化会让现有客户端或自动化脚本失联；不能靠重新开启弱算法掩盖。
- 私有树在 `/userdisk/data`；盘未挂载时新服务起不来，启动入口必须回退原厂程序。
- 单纯升级不改变访客网可达性；限制 22 端口是另一个防火墙变更，需单独回归。

**接管点（已实施）**

- `/` 是只读 ubifs（`/dev/ubi1_0 on / type ubifs (ro,…)`），不能替换 `/usr/sbin/dropbear`。
- `/etc` 是独立可写 ubifs（`/dev/ubi2_0`），实际接管点是 `/etc/init.d/dropbear`：保留原厂全部函数，只在文件头按“候选二进制可执行 + `run/takeover.ok` 存在”选择 `PROG`，并为候选追加 `-D /etc/dropbear`；否则仍用 `/usr/sbin/dropbear`。
- `stop()` 由原厂的 `service_stop -x ${PROG}` 改为“按 pidfile 终止，并校验目标 exe 为原厂或候选路径”，否则切换后若标记消失，原厂进程无法被新 init 停止。
- 回退资产：
  1. `/userdisk/data/dropbear-state/backup-dropbear-v2011.54/`：原厂 init/config/host key/authorized_keys 的字节副本 + `restore.sh`，[清单](../evidence/2026-11-10-b1-takeover/backup-manifest.md)；
  2. 原厂二进制 `/usr/sbin/dropbear` 原位保留、从未覆盖；
  3. 接管窗口内保持已建立的 SSH 会话（dropbear 子进程不随监听进程退出）。
- 自愈脚本（`recipes/stage2/dropbear-22/`）：`takeover-22.sh`（停原厂 → 起新实例 → banner 校验 → 回环公钥实测 → 写标记）、`watchdog-22.sh`（独立 BusyBox 看护，deadline 无标记即调回退）、`rollback-22.sh`（按 pidfile/端口清理非原厂实例 → 还原原厂 init/config → 启动原厂 → 校验 22 归属）。
- 判定：接管后只有 banner `dropbear_2026.94` 与回环公钥 `AUTH_OK` 同时成立才写标记；任一步失败立即回退，看护独立兜底。没有这套机制就不接管 22。

**验证顺序**：构建机产出 → 隔离端口 2223 成功/强制失败双演练 → 备份 → 窗口内接管 + 看护 → LAN 重登/管理面/端口归属 → 原厂 stop/start 链与完整回退实测 → 冷启动复查端口归属（2026-11-10 01:45 已完成真实 `reboot`，见 §11）。

### 2.4 B2：curl

设备 curl 7.33.0 链接 PolarSSL 1.3.16 与 zlib 1.2.7。上游当前为 8.23.0，其变更记录注明 8.23.0 删除 SMB 协议支持，8.18.0 起提高了 TLS 后端最低版本，因此**不能照抄“curl 8.x + 现有系统 TLS”**。[版本表](https://curl.se/docs/versions.html) · [变更记录](https://curl.se/changes.html)

**第一条动作是盘点调用方**：`/etc/init.d`、hotplug 脚本、cron、rpc/服务脚本、以及 `/userdisk/data` 下的脚本中所有 `curl` 引用，形成清单后再决定升级范围。仓库内未见调用点不等于设备上没有调用方。

**盘点结论（2026-11-09 16:33，只读）**：脚本调用方为 `/etc/init.d/miDebug.sh`、`/etc/init.d/mitvapp`、`/usr/sbin/wifishare.sh`、`/usr/bin/netspeed`、`/etc/mixbox/scripts/helper.sh`，全部只用 HTTP；`/etc/mixbox/scripts/helper.sh` 已优先 `/opt/bin/curl`（该文件当前不存在）。另有一批厂商 ELF（`app_status`、`indexservice`、`mediaservice`、`datacenter`、`quarkd`、`plugin*` 等）经 `libcurl.so.4` 使用 curl，不属 CLI 替换范围。证据见[调用方清单](../evidence/2026-11-09-stage0-rollback/curl-callers.txt)。

**范围判定**：

- 有调用方且其协议/选项/TLS 需求受旧版限制 → 构建 8.23.0 私有树，调用方逐个改为显式路径；
- 有调用方但不受限 → 记录理由，条目保留为待命；
- 无调用方 → 结论写“为外部脚本/用户手动预留”，条目继续保留。

**约束**：独立名字（如 `/userdisk/data/.../curl-new`）+ 私有 TLS 后端与 CA，不覆盖 `/usr/bin/curl`；保留旧路径回退；未确认调用方前不进入部署窗口。

### 2.5 B3：`nmbd` 4.0.21 → 私有 4.25.1 `nmbd`

**身份已结案**（2026-11-09 14:29 快照）：PID 2071，`/proc/2071/exe` → `/usr/sbin/samba_multicall`，`nmbd -V` 为 4.0.21，持有 UDP 137/138。私有树里的 4.25.1 `nmbd`（253 126 B，MD5 `2283bda9f01dfa719ad276af28b655a0`）已就绪，**零构建**。

**待评估**：是否切换。收益是移除最后一个旧 Samba 家族网络监听；代价是 NetBIOS 名称服务与浏览发现可能影响电视、旧 Windows 客户端、网络邻居与小米 App 的发现路径，而当前证据只证明端口在监听，不能证明谁依赖它。

**交互点**：兼容包装器仍通过原厂 `/usr/sbin/nmbd` 启动它；nmbd 未登记在 TaskMonitor 表内，不能套用 smbd 的接管模型。包装器重启有可能把 nmbd 拉回原厂路径，切换后必须复跑 `samba restart` 与冷启动。

**切换判定**：先在隔离 LAN 核对名称注册、浏览列表、休眠/重启后重注册与 137/138 广播；确认 UDP 端口释放后再启动新实例，不允许两个 nmbd 抢端口。回滚 = 改回包装器原厂路径 + restart。

### 2.6 B4：MiniDLNA / ReadyMedia 1.1.0 → 1.3.3

按**在用**处理：配置已启用，管理链可拉起服务，`shareUpdate` 会生成配置。因此构建候选是正式排期项。

**依赖**：私有 libexif 0.6.24、libjpeg-turbo 3.0.4、libid3tag 0.16.3、flac 1.4.3、libogg 1.3.5、libvorbis 1.3.7 与 SQLite 3.54.1，全部落 `/userdisk/data` 私有树；上游 1.3.3 发布记录 SHA-256 `39026c6d…f96afa4`。源码与校验值已锁定（见[阶段 0/1 执行记录](stage-0-1-execution-2026-11-09.md)）。**构建环境缺口**：容器缺 `cmake`（libjpeg-turbo 3.x）与 `libtool`（libid3tag 归档），补齐前不进入阶段 2。

**验收要点**（与 App / 电视相关）：

- `/etc/config/minidlna` → `shareUpdate` 生成的配置与旧版一致，媒体目录正确；
- `supervisord` 拉起路径不变，服务自启与 App 开关联动；
- 电视/播放器可在局域网发现并播放；索引刷新、删除、增删媒体文件后重建；
- 重启与掉盘后索引与服务恢复；App 显示与后端状态一致；
- 资源占用（CPU/RSS）不高于旧版基线。

**回滚**：保留 1.1.0 原厂二进制与 App 入口，私有树独立前缀，回滚即切回原厂服务。

### 2.7 B5：dnsmasq 2.71（低优先级候选）

设备当前未运行 dnsmasq、无 53 监听；DNS/DHCP 由上游提供。条目保留为正式候选，优先级最低：**只有在本机承担 DNS/DHCP，或出现必须由本机解析的明确需求时才构建**。

**触发后的范围**：选经 2026 安全修复的 2.92rel2，不选未经修复的 2.92；源码已锁定（SHA-256 `43d72b8c…a32ce06a`，`.asc` 用键 `15CDDA6AE19135A2` 验签通过）。配置与租约目录放持久可写分区；验收覆盖 DNS 转发/缓存、DHCP 地址池与租约、IPv6（RA/DHCPv6）、与小米管理面联动、断网与重启恢复。

**未触发时**：不构建、不部署，但在候选表中保留，不视为“明确不做”。

### 2.8 B6：WebDAV（计划内候选）

新增独立 WebDAV 服务，候选实现为 lighttpd 1.4.85 的 `mod_webdav`（PROPFIND/PUT/MOVE/LOCK；完整属性与锁需 libxml2/SQLite），监听独立 LAN 端口（暂定 8088，须先盘点冲突），根目录只映射到批准的硬盘路径。详细设计、macfilter 联动与授权验收草案见 [WebDAV 立项材料](webdav-proposal-unfiled-2026-11-09.md)。

**前置未决项（列出但不因此移出计划）**：

1. **撤权语义冲突**：B6 草案要求 `macfilter.lan=no` 后 ≤5 秒拒绝新连接并终止已有会话；SMB 实测为约 10 秒（重启）/约 22 秒（cron，上限 60 秒）。必须先决定统一时延，或明确记载两套语义并让 App 文案可解释。
2. **看护进程存活**：要求同步器每秒更新租约、独立看护在租约超时后最多 1 秒停服。设备现有 cron 的最小粒度是分钟级，需单独常驻看护进程，尚未设计其自我恢复与 TaskMonitor 关系。
3. **端口与绑定面**：8088 及候选端口占用未盘点；只绑定 LAN，guest/WAN 默认拒绝，不得把端口转发到公网。
4. **认证与传输**：必须认证；未加密 HTTP 的 Basic 凭据不适合不可信链路。
5. **产品语义**：WebDAV 根是否等同“全盘访问”，以及 `lan=yes` 是否仍需认证。

上述任一项未决时不进入部署窗口；条目保持候选状态。

**2026-11-10 决策（S16）**：放弃 `macfilter` 联动的 5 秒撤权与 fail-closed 链，改为“真实认证 + 最小暴露目录 + 降权运行”。正式端口 `192.168.3.2:5005`，Digest 认证，只映射四个共享目录；看护改为 `run.sh` 内的 30 秒常驻子进程。五项前置中 1/2/5 被此方案取代，3/4 按“只绑 LAN、必须认证、不用 Basic”落实，TLS 因构建无 OpenSSL 暂缺并记录为限制。详见 `docs/decisions.md` S16。

## 3. 不纳入本轮的系统组件

| 组件 | 排除原因 | 未来重新立项条件 |
|---|---|---|
| Linux 2.6.36 内核 | 缺少已验证的 BCM4709 BSP 源码/配置；闭源 `wl`、Tuxera 文件系统、`et/ctf/dpsta` 等模块依赖现有 ABI；当前官方固件没有更高版本 | 找到同板完整 BSP、可复现固件构建、模块源码/授权和串口救砖条件 |
| uClibc 0.9.33.2 | 全系统 ELF 运行时 ABI，不是独立可替换库 | 有整套固件源代码并能完整重编所有消费者 |
| BusyBox 1.19.4 | init、shell、系统命令多入口依赖，错误可能影响启动/恢复 | 在固件克隆上逐 applet 比对配置与启动，具备双槽恢复手段 |
| iptables 1.4.12.2 / ipset 6.20.1 | 扩展与内核匹配，防火墙是联网控制面 | 明确需要的扩展、厂商模块对应源码、独立网络回滚测试 |
| `sysapihttpd` / nginx 1.2.2 / uhttpd | 小米管理 API、Lua/FastCGI、证书和固件脚本耦合；uhttpd 当前未监听 | 建立管理 API/App 全链路兼容测试和可靠恢复入口 |
| wpa_supplicant / hostapd | 当前 AP 由 Broadcom `nas`/`wl` 闭源栈处理；wpa_supplicant 未运行，hostapd 不存在 | 替换无线栈的完整 BSP 与无线法规/射频回归条件 |
| OpenSSL 1.0.1j（8443 实际加载） | 被 `sysapihttpd` 加载；另有 16 个厂商闭源二进制/私有库引用同一 soname；设备无 `openssl` CLI。私有 OpenSSL 只保护新工具，不修复 8443。[审计与证据](../audits/openssl-not-upgraded-2026-11-10.md) | 厂商支持的 TLS 配置审计结论；未证明不影响 App 前不改 `sysapihttpd` |
| 固件分支 / U 盘刷机 | 2.25.209 以上无已确认的 R2D 开发版；2.24.11 缺 SSH 服务端会自我锁死；U 盘刷机会格式化硬盘 | 不立项 |

## 4. 阶段、顺序与门槛

### 4.1 阶段 0 硬前置：恢复回滚资产并实测 `rollback`

**现状（2026-11-09 16:24 已通过）**

- 恢复前：`versions/` 只剩 `1.0.7-r2d`，`previous` 不存在 → `rollback` 返回 6。
- 已用方式 A 恢复并实测：`install` 1.0.6 树 → 两次 `activate` → 真实 `rollback` 到 1.0.6 并启动复核 → 切回 1.0.7。
- 终态：`current -> 1.0.7-r2d`，`previous = 1.0.6-r2d`，两棵树均存在，回滚目标前缀可解析。
- 证据与逐项判定：[阶段 0/1 执行记录](stage-0-1-execution-2026-11-09.md)、[证据目录](../evidence/2026-11-09-stage0-rollback/)。
- 本地 `s8-release/` 保留 1.0.6 包：14 307 338 B，MD5 `b19d355c8f5c1fa0f3f67e542b15876d`，SHA-256 `f2285da6cb6c236cf6ea9c8754c62e3788e88f8acbeb2af005bb3d4401b372c1`。

**恢复方式 A（首选，字节可核对）**：把本地 1.0.6 包上传到设备，安装树载荷但**不启动**，再用两次 `activate` 交换，使 `previous` 指向 1.0.6。

```sh
# 1) 上传前后核对：应为 b19d355c8f5c1fa0f3f67e542b15876d
md5sum /userdisk/data/release/miwifi-smb-1.0.6-r2d.tar.gz
# 2) 解包并只建树（安装器接受树载荷，不是整包），不激活、不启动
mkdir -p /tmp/p106 && tar -xzf /userdisk/data/release/miwifi-smb-1.0.6-r2d.tar.gz -C /tmp/p106
md5sum /tmp/p106/miwifi-smb-1.0.6-r2d/payload/samba-tree.tar.gz   # 应与 state/1.0.6-r2d.md5 一致
sh /userdisk/data/s7root/xiaomi-smb-install.sh install \
   /tmp/p106/miwifi-smb-1.0.6-r2d/payload/samba-tree.tar.gz 1.0.6-r2d
# 3) 两次切换把 previous 指向 1.0.6（切换要求先停实例，属窗口动作）
sh /userdisk/data/s7root/xiaomi-smb-install.sh activate 1.0.6-r2d
sh /userdisk/data/s7root/xiaomi-smb-install.sh activate 1.0.7-r2d
```

注意：`activate` 在检测到旧实例仍在运行时拒绝切换（PID 文件在旧树里，切换会让进程无法停止），因此第 3 步必须在维护窗口内、先停后切。

**恢复方式 B（不切服务，需记录）**：方式 A 的第 2 步完成后，直接写 `state/previous`：

```sh
echo 1.0.6-r2d > /userdisk/data/s7root/state/previous
```

只在 1.0.6 树的 `sbin/smbd`、`bin/testparm` 存在且包 MD5 核对通过时使用，并把操作写入 `state/install.log`。不要让手工指针替代实测。

**实测 `rollback`（窗口内）**

```sh
# 0) 前置：两棵树同时存在，指针指向 1.0.6
cat /userdisk/data/s7root/state/previous
ls -d /userdisk/data/s7root/versions/*/
test -x /userdisk/data/s7root/versions/1.0.6-r2d/root/sbin/smbd && echo tree-ok
# 1) 停现役后回滚（install-release.sh rollback 会先停服务；用树安装器做最小切换）
sh /userdisk/data/s7root/xiaomi-smb-install.sh rollback
# 2) 核对 1.0.6 运行，再切回 1.0.7
sh /userdisk/data/s7root/xiaomi-smb-install.sh activate 1.0.7-r2d
```

**判定标准（全部满足才算通过）**

1. `rollback` 返回 0，打印 `rolled-back-to 1.0.6-r2d`；
2. 切换后 `current -> versions/1.0.6-r2d/root`，`state/previous` = `1.0.7-r2d`；
3. 1.0.6 树内 `sbin/smbd`、`bin/testparm` 可执行，`smbd -b` 能解析出前缀；
4. 1.0.6 启动后 139/445 归 `samba-s5d`，`diskacl-status` 为 `chain=present jumps=2 legacy_chain=absent guest=enforced`，`smbutil view -N //guest@192.168.3.2` 见三共享；
5. 切回 1.0.7 后同样五项复查通过；
6. 全程只需一条 SSH 会话与本地包，不需要新入口。

结果写入 `docs/evidence/`；未通过前，§4.3 除只读核对外一律不开始。

**保留策略（写进安装器）**：任何时候至少保留 **N-1 一棵完整树 + `previous` 指针**，回滚不得依赖重新下载。删树必须先清指针；指针悬空时安装器拒绝升级（exit 6），只允许把缺失的那棵树重新装回来。

**安装器门禁（已落地，保持现状）**：`recipes/samba/xiaomi-smb-install.sh` 在安装前检查 `previous` 指向的树；缺失且目标版本不是该树本身时拒绝安装；安装/激活后校验回滚目标树可解析前缀（不启动），把结果写入 `state/install.log`。

### 4.2 构建序（八项，按可执行性与依赖）

| 序 | 组件 | 锁定输入 / 现状 | 前置 | 产出 | 可执行性 |
|---|---|---|---|---|---|
| 1 | A0 Samba 兼容层 | 1.0.7 已交付 | 回滚资产 | 无新构建（仅兼容层包） | 可执行（仅收尾验证） |
| 2 | B3 `nmbd` | 复用现役树 4.25.1 产物 | 无 | 零构建 | 可执行（待决策） |
| 3 | B1 Dropbear 2026.94 | SHA-256 `e098034a…b1ae81`，`.asc` 已验签 | 回退通道设计 | 私有树 + 并行端口测试包 | 可执行 |
| 4 | B4 MiniDLNA 1.3.3 | SHA-256 `39026c6d…f96afa4`；依赖全部锁定 | 补齐 cmake/libtool | 私有树 + 索引测试 | BLOCKED：构建环境缺 cmake/libtool |
| 5 | B2 curl 8.23.0 | SHA-256 `8dadd7d2…e6c5`，`.asc` 已验签；调用方已盘点 | 选定逐调用方范围 | 私有树 + 显式路径 | 可执行（HTTP-only） |
| 6 | A1 Samba 新 stable | 上游当前仍 4.25.1（4.25.2 = 404） | A0 验收 | 新 payload | BLOCKED：无新上游版本 |
| 7 | B5 dnsmasq 2.92rel2 | SHA-256 `43d72b8c…a32ce06a`，`.asc` 已验签 | 网络拓扑变更决定 | 私有树 | BLOCKED：未触发（低优先级） |
| 8 | B6 WebDAV（lighttpd 1.4.85 + libxml2/SQLite） | 记录在案 | 无 | 独立实例 | 已上线：`192.168.3.2:5005`，冷启动通过 |

构建环境固定为容器 `miwifi-s1`（Ubuntu 24.04，镜像 ID `sha256:fe8156…6ef852`），工具链 GCC 4.8.2 / uClibc 0.9.33.2，QEMU `qemu-arm-static`。容器当前没有 Dockerfile，可复现性缺口见 [阶段 0–1 记录](stage-0-1-preparation-2026-11-09.md)。

### 4.3 部署序（八项，按可执行性；阻塞项标 BLOCKED）

| 序 | 动作 | 不可逆性 | 失败会阻塞什么 | 影响面 | 窗口量级 | 回滚时限 | 状态 |
|---|---|---|---|---|---|---|---|
| 0 | §4.1 恢复回滚资产 + 实测 rollback | —（前置门） | 全部后续部署 | SMB | 30–45 min | 失败即停，不改包 | PASS（2026-11-09 16:24） |
| 1 | A0 升级后整机冷启动核对 | 低（可重复重启） | 整机：所有入口同时不可用 | 整机 / SMB / SSH / 管理面 / 无线 | 10–15 min | 无代码回滚；失败走本地 1.0.7 重装，≤30 min | 可执行 |
| 2 | B3 `nmbd` 切换 | 中（发现功能退化不易察觉） | NetBIOS 发现、电视/旧客户端、App 发现 | SMB / 管理面（发现） | 15–30 min | 改回包装器原厂路径 + restart，≤5 min | BLOCKED：发现功能无设备证据 |
| 3 | B1 Dropbear 接管 22 | 高（唯一维护入口） | SSH，进而所有远程维护 | SSH / 管理面 | 30–60 min | 备份还原 + `rollback-22.sh`，≤5 min | 已执行：备份校验 + 2223 双演练 + 独立看护；见 §11 |
| 4 | B4 MiniDLNA 切换 | 中（索引与发现） | 电视播放/媒体索引 | 应用 / 管理面（App 开关） | 30–45 min | 切回原厂服务，≤10 min | BLOCKED：私有依赖链未构建 |
| 5 | B2 curl 显式路径（逐调用方） | 低（旧二进制保留） | 无服务阻塞 | 仅调用方 | 每调用方 5–15 min | 改回原命令，即时 | 可进入：调用方已盘点（HTTP 脚本） |
| 6 | B6 WebDAV 上线 | 中（新增对外端口） | 无（新服务），但策略错误会扩大访问面 | 管理面 / 访问控制 | 30–60 min | 停服务 + 撤端口，≤10 min | 已上线（2026-11-10）：5005 + Digest + 4 目录，冷启动通过；见 D-S16-01…07 |
| 7 | B5 dnsmasq | 高（DNS/DHCP 是联网控制面） | 全网解析/DHCP | 无线 / 整机联网 | 30–60 min | 恢复上游 DNS/DHCP，≤10 min | BLOCKED：未触发 |
| 8 | A1 新 Samba payload | 中 | SMB 全量 | SMB | 30–45 min | 切回上一树，≤5 min | BLOCKED：无新上游版本 |

**逐项验证命令**

- **A0 冷启动**：`uptime -s`；`readlink /userdisk/data/s7root/current`；`netstat -ltnp | grep -E ':(139|445) '`；`sh /userdisk/data/s7root/xiaomi-smb-adapter.sh -r /userdisk/data/s7root/current diskacl-status`；`iptables -S INPUT | grep -c 's8-diskacl'`；`crontab -l | grep diskacl-sync`；`smbutil view -N //guest@192.168.3.2`。
- **B3 nmbd**：切换前 `netstat -lunp | grep -E ':(137|138) '` 确认端口释放；切换后 `readlink /proc/<pid>/exe` 应为私有树 `nmbd`；`/etc/init.d/samba restart` 与冷启动后再查。回滚判据：137/138 重新归 `/usr/sbin/samba_multicall`。
- **B1 Dropbear**：`ssh -p 22 … 'readlink /proc/$(cat /var/run/dropbear.1.pid)/exe'` 应为私有树；`netstat -ltnp | grep ':22 '` 单实例；`/etc/init.d/dropbear restart` 后重连并确认 banner `dropbear_2026.94`；确认 `/etc/init.d/dropbear` 为 wrapper、`run/takeover.ok` 存在、原厂副本与 `rollback-22.sh` 可用。回滚：`sh /userdisk/data/dropbear-2026.94/bin/rollback-22.sh`。
- **B4 MiniDLNA**：`ps | grep minidlna`；`netstat -ltnp | grep 8200`；媒体目录索引数量与旧版比对；电视端发现与播放一次；重启后复查。
- **B2 curl**：`curl-new --version` 与 `readelf -d` 确认依赖闭合；调用方逐个比对退出码/输出/网络副作用；`/usr/bin/curl --version` 保持 7.33.0。
- **B5 dnsmasq**：`netstat -lunp | grep ':53 '`；解析与租约测试；断开上游 DNS 后行为。
- **B6 WebDAV**：端口监听面仅 LAN；`lan=no` 设备撤权计时；断点/大文件上传；与 SMB 并发读写一致性。
- **A1**：`smbd -b` 前缀、`smbd --version`、§5 矩阵、两次构建 `sha256sum` 一致。

### 4.4 阶段 1–5 细则

**阶段 1：构建准备，不写设备**

- 确认 SDK GCC 4.8.2 / uClibc 工具链、宿主容器与 QEMU；SDK 与厂商二进制不进入公共发布物。
- 为每个候选固定源码输入（A1 由上游触发；B1/B2/B4/B6 已有锁定记录；B5 触发后再锁）。
- 定义独立 `/userdisk/data` prefix、私有库、证书/配置、MANIFEST、安装/卸载/回滚入口；确认挂载时序与空间（§6）。
- 逐包准入表：

| 输入 | 必须记录的内容 |
|---|---|
| 可重建环境 | 镜像标识、工具安装命令与版本、SDK/QEMU 哈希、干净工作目录与输出路径 |
| 完整依赖和命令 | 源码/签名/哈希、补丁顺序、TLS 后端与传递依赖、准确 configure/编译/链接参数 |
| 运行布局 | 版本 prefix、私有库、CA/证书、配置、PID、日志、状态路径、运行用户、挂载依赖 |
| 安装与恢复 | MANIFEST 覆盖范围、安装/卸载/停止/回滚入口、回滚目标、持久数据兼容 |
| 准入结论 | 逐项标记已完成/待补/不适用；任一必填项待补时只允许继续准备该包 |

**阶段 2：候选构建与静态核验**

- 一次只构建一个候选；检查 ELF 架构、解释器、SONAME、未解析符号与依赖闭合，不得链接宿主机库。
- Samba 候选沿用 `recipes/samba/repro-build.sh` 的固定工具链、补丁序列与复现约束；注意该脚本会 `rm -rf /work/repro-work` 与指定输出目录，并行/重复调用前先隔离 workdir。
- 检查 Linux 2.6.36 系统调用/熵源/线程需求与 GCC 4.8.2 头文件兼容；QEMU 冒烟后保存完整日志、散列与版本输出。
- 复现判定：两次构建产物 `sha256sum` 一致，且 `smbd -b` 前缀与部署 prefix 对应。

**阶段 3：隔离功能回归**

- 按 §5 矩阵执行；Samba 相关项用 1445 隔离实例，不碰生产 139/445。
- 不改生产服务；失败回退可执行后才允许进入阶段 4。

**阶段 4：设备候选部署**

- 每次只变更一个服务，按 §4.3 顺序；使用版本目录、原子 `current` 指针、MANIFEST、日志与明确回滚入口。
- 启动验证分两步：手工临时实例 + 停止/回滚 → 维护窗口内一次性受保护启动入口（含超时回退与成功标记）→ 冷启动复核。失败或未写成功标记时恢复原厂入口。
- 先完成 A0 收尾，不重复安装未变化的 Samba payload。

**阶段 5：收尾与准入**

- 记录实际安装 tar SHA-256/MD5、MANIFEST、当前树与回滚目标；Samba 上游版本与兼容层包版本分开标识。
- 非目标组件的端口归属、共享配置、App 生命周期、无线联网与管理 API 保持基线行为；每项记录预期差异、证据与恢复命令。
- 没有真实 App/客户端条件的功能标 BLOCKED；“构建成功”不能标为“升级完成”。

## 5. 回归矩阵（内联，替代已删除的 S1–S8 文档）

### 5.1 SMB 协议与客户端

| 用例 | 环境 | 判定方式 | 通过标准 |
|---|---|---|---|
| 枚举与挂载 | macOS `smbutil view -N //guest@192.168.3.2`、`mount_smbfs` | 手工 + 命令输出 | 三共享可见、可挂载、可列目录、可卸载 |
| 目录遍历与读写 | Linux `smbclient //192.168.3.2/<share> -N -c 'ls;mkdir t;put f;get f'` | 命令输出 + 双侧文件比对 | 读写内容一致，无权限误报 |
| 协议版本 | `smbclient -m NT1`、`-m SMB2`、`-m SMB3`（按构建启用的最小协议） | 连接结果 | 构建允许的版本可连；被禁版本明确拒绝而非挂起 |
| 认证 | guest 与（隔离实例内的）测试用户 | `smbclient -U <user>%<pw>` | guest 只读路径符合配置；测试用户按预期 |
| 并发 | 2–4 客户端并行读写 | `dd`/`cp` 循环 + 校验和 | 无数据损坏、无进程崩溃 |

### 5.2 MAC 策略（磁盘访问链）

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 链完整性 | `iptables -S s8-diskacl \| grep -c DROP`；`iptables -S INPUT \| grep s8-diskacl` | 8 条 DROP + 1 条 RETURN；INPUT 两条跳转（TCP 139/445、UDP 137/138） |
| 名单内拒绝 | App 把设备 `lan` 置 no | 约 10 秒内拒绝，`smbutil view` 失败 |
| 名单外放行 | 非名单 MAC 访问 SMB | 正常枚举/挂载，不受全局 DROP 影响 |
| 恢复 | 再置 yes | cron 约 22 秒内恢复（上限 60 秒） |
| 状态自检 | `adapter -r $ROOT diskacl-status` | `chain=present jumps=2 legacy_chain=absent guest=enforced` |
| 访客规则位次 | `iptables -S INPUT` | `br-guest` DROP 在原厂无接口限定 ACCEPT 之前 |
| 缺失自愈 | 手工删除访客 DROP | 约 50 秒内重建，状态回到 `enforced` |
| IPv6 | `ip6tables -S INPUT` | 规则为 IPv4 `iptables`，**不得**宣称覆盖 IPv6 |

### 5.3 摄像机只读

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 时段内写 | 隔离实例设窗口，客户端创建文件 | 被拒并记录只读拒绝日志 |
| 时段外写 | 同上，窗口外 | 允许，创建成功 |
| 边界 | 窗口起止两端各测一次（闭区间） | 行为与配置语义一致 |
| 跨午夜窗口 | 23:5x → 00:0x | 跨日仍正确 |
| 真实摄像机 | 需硬件 | 无设备时保持 BLOCKED |

### 5.4 U 盘挂载与共享

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 热插拔识别 | 插入/拔出后 `smbutil view`、`/etc/hotplug.d/block/90-s8-mounts` 日志 | 新共享出现/消失，无需重启 Samba |
| 挂载派生共享 | 拔盘再插回 | 共享重建，路径正确 |
| 掉盘容错 | 运行中拔盘 | SMB 不崩溃，恢复后可用 |
| 真实设备 | 单口 U 盘 + 双分区 | 无设备时标“未重跑”，1.0.7 载荷未变 |

### 5.5 并发、签名与加密

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 签名 | `smbclient --option='client signing = required'` | 连接成功，吞吐下降在预期范围 |
| 加密 | `smbclient -e` | 连接成功，吞吐在可接受范围 |
| 并发 | 多客户端 + 大文件 | 无死锁、无损坏、RSS 稳定 |
| 资源 | `smbd` RSS、空闲 CPU | 与基线相当（空闲 RSS ≈ 11 MB） |

### 5.6 `homes`

见 §2.1：保留“运行时配置与枚举一致性”的判定；内容访问不在生产设备上做。

### 5.7 `nmbd`（B3）

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 端口归属 | `netstat -lunp`、`readlink /proc/<pid>/exe` | 137/138 归私有树 `nmbd`，单实例 |
| 名称注册 | 同 LAN 隔离设备 + `nmblookup` | 名称可解析 |
| 浏览/发现 | 电视、旧 Windows、App | 列表可见；无设备时标 BLOCKED |
| 包装器重启 | `/etc/init.d/samba restart` | 不被拉回原厂路径 |
| 冷启动 | 重启后复查 | 端口与身份保持 |

### 5.8 Dropbear（B1）

并行端口、密钥认证、连接保持、断线重连、重启后接管与回退，判定见 §2.3。

### 5.9 curl（B2）

TLS/CA/主机名/时钟/重定向/超时/代理/退出码；逐调用方比对输出与副作用。

### 5.10 MiniDLNA（B4）

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 配置生成 | `shareUpdate` 后比对 `/tmp/minidlna.conf` 之类的生成物与旧版 | 媒体目录一致，无多余项 |
| 服务拉起 | `supervisord` 与 `/etc/init.d/minidlna` | 服务运行，8200 监听 |
| 索引 | 客户端浏览媒体库 | 数量与类型符合预期，刷新后更新 |
| 电视发现 | 真实电视/播放器 | 可见并可播放；无设备时标 BLOCKED |
| 重启持久 | 重启后复查 | 索引与服务自动恢复 |

### 5.11 dnsmasq（B5）与 WebDAV（B6）

dnsmasq：DNS 转发/缓存、DHCP 租约、IPv6、断网恢复。WebDAV：端口绑定面、撤权计时、断点上传、与 SMB 并发一致性。两者都在触发或前置未决项关闭后才执行。

## 6. 容量预算

**现场容量（2026-11-09 14:29 快照）**

| 挂载点 | 设备 | 容量 | 可用 | 可写 | 用途 |
|---|---|---|---|---|---|
| `/` | `/dev/ubi1_0` ubifs | 110 440 KB | 20 588 KB | **否（ro）** | 系统，不可写入 |
| `/data`、`/userdisk`、`/etc` | `/dev/ubi2_0` ubifs | 208 956 KB | 139 872 KB | 是 | 配置与启动脚本（`/etc/init.d/dropbear` 在此） |
| `/userdisk/data` | `/dev/sda1` ext4 | 976 458 860 KB | 467 706 624 KB | 是 | 私有运行树、包、状态 |
| `/tmp` | tmpfs | 101 780 KB | 100 160 KB | 是 | 临时解包 |
| `/extdisks/sdb1` | `/dev/sdb1` | 976 727 036 KB | 557 206 088 KB | 是 | 外接盘 |

**预算（实测锚点 + 预留）**

| 项 | 值 | 依据 |
|---|---|---|
| 1.0.7 包 | 14 308 996 B | 本地与设备一致 |
| payload tar | 14 397 433 B | 包内文件 |
| 解包树 | ≈ 41 MiB（339 个文件） | 本地解包 `du -sm` |
| 保留 N-1 | 2 棵树 ≈ 82 MiB | 2 × 41 MiB |
| Dropbear 候选树 | 预留 ≤ 10 MiB | 待构建实测 |
| curl + 私有 TLS | 预留 ≤ 20 MiB | 待构建实测 |
| MiniDLNA + 媒体依赖 | 预留 ≤ 30 MiB | 待构建实测 |
| dnsmasq | 预留 ≤ 5 MiB | 待构建实测 |
| WebDAV（lighttpd + libxml2 + SQLite） | 预留 ≤ 40 MiB | 待构建实测 |
| 状态/日志/证据 | 预留 64 MiB | `state/install.log`、cron 日志、临时副本 |
| 判定命令 | `df -k /userdisk/data`；`du -sm /userdisk/data/s7root/versions/*` | 部署前执行 |
| 门槛 | 可用 ≥ 预算总和 × 2 | 余量用于重装与掉盘恢复 |

按当前 446 GB 可用，容量不构成阻塞；真正的风险是**盘未挂载时私有树不可用**，由启动入口回退原厂程序覆盖。

## 7. 跨组件交互矩阵

| 组合 | 交互点 | 风险 | 处理 |
|---|---|---|---|
| WebDAV × Samba | 同一磁盘路径并发读写；`macfilter` 语义 | SMB 侧 `lan=no` 生效约 10–22 秒，若 WebDAV 另设 5 秒语义，用户会看到两套时延不一致 | §2.8 前置未决项 1：统一时延或明确记载差异 |
| Dropbear × 管理面 | 22 端口、`/etc/init.d/dropbear`；App/云端可能重启服务 | 接管失败锁死维护入口；固件侧脚本可能覆盖 init | 备份 init + 保留原厂二进制 + wrapper 回退 + 超时脚本 |
| Dropbear × 磁盘挂载 | 候选树在 `/userdisk/data` | 盘未挂载 → SSH 不可用 | wrapper 检测私有树缺失即 `exec /usr/sbin/dropbear` |
| nmbd × Samba 包装器 | 包装器走原厂路径起 nmbd；nmbd 不在 TaskMonitor 表 | 包装器重启把 nmbd 拉回原厂，覆盖切换 | 切换后复跑 `samba restart` 与冷启动复查 |
| nmbd × smbd | 同族 Samba，共享 NetBIOS 名称与配置 | 两个 nmbd 抢 137/138 | 切换前确认端口释放，单实例 |
| MiniDLNA × 磁盘/USB | 媒体目录与索引库在 `/userdisk/data` | 掉盘后索引损坏或服务卡死 | 索引放持久目录，掉盘后重建；纳入 §5.10 |
| MiniDLNA × 管理面 | `shareUpdate`、`supervisord`、App 开关 | 私有树拉起被厂商脚本覆盖 | 保留原厂入口，切换前验证 App 联动 |
| curl × 厂商脚本 | 调用方写死 `/usr/bin/curl` | 替换系统路径会波及所有调用方 | 只用独立前缀，调用方显式选用 |
| dnsmasq × 网络核心 | DNS/DHCP 是联网控制面 | 配置错误导致全网断网 | 未触发不部署；部署须有上游回退 |
| Samba × cron `diskacl-sync` | 每分钟改 iptables | 规则改动与新端口规则冲突 | 新服务若需 ACL，纳入同一同步器或独立同步器 |
| 任何新服务 × 根分区 | `/` 只读且仅 20 MB | 误写根分区会失败或破坏系统 | 所有产物只落 `/userdisk/data`；`/etc` 只改启动脚本 |

## 8. 验收项判定命令

| 验收项 | 原问题 | 判定命令 | 通过标准 |
|---|---|---|---|
| nmbd 当前身份 | 曾写“未知”，与快照矛盾 | `netstat -lunp \| grep -E ':(137\|138) '`；`readlink /proc/<pid>/exe`；`nmbd -V` | 已结案：PID 2071 / `samba_multicall` / 4.0.21；后续为切换决策 |
| `homes` 是否可枚举 | “可见”不等于“可访问” | `uci get samba.@samba[0].homes`；`testparm -s $ROOT/etc/smb.conf`；`smbutil view -N` | 配置源、渲染结果、枚举三者一致 |
| `homes` 内容访问 | 生产无“有效用户”，不可执行 | 隔离实例建测试用户后 `smbclient -U test%…` | 只在隔离实例判定；生产不建用户 |
| 1.0.7 冷启动 | 无记录 | `uptime -s`、`current` 链接、139/445 归属、ACL 状态、cron 行 | §4.3 第 1 项全部通过 |
| 回滚可用 | 原为“需可回滚” | §4.1 的六条判定 | 全部通过 |
| 访客端到端 | 规则面通过，端到端未验 | 真实访客客户端连 139/445 + `iptables -L INPUT -v -n` DROP 计数 | 无客户端时保持 BLOCKED，不以规则面代替 |
| 构建可复现 | 原为“干净重建” | 两次构建 `sha256sum` 比对 + `smbd -b` | 字节一致且前缀正确 |
| 原厂回退路径 | 原为“始终保留” | `ls /userdisk/data/s8compat/versions/v0-vendor`；`grep -n 'rollback' /userdisk/data/s8compat/install.sh` | 原厂 init 与二进制备份存在；rollback 分支指向 `v0-vendor` |

## 9. 窗口纪律与立即停手条件

- 单窗口单组件；窗口开始前必须已完成 §4.1。
- 窗口内保持第二个已建立的 SSH 会话；Dropbear 窗口额外准备超时脚本。
- 立即停手并回滚的条件：SSH 无法新建会话 / 139/445 归属变化 / 80 或 8443 管理面失效 / DNS、DHCP、无线异常 / 磁盘挂载变化 / `rollback` 或 `activate` 返回非 0。
- 停止只回滚当前组件，不连带调整其它服务；恢复后再重新评估是否继续。

## 10. 尚待确认的证据

| 问题 | 当前状态 | 影响的条目 |
|---|---|---|
| 1.0.7 冷启动后整机状态 | 无记录（装包早于当前 uptime） | A0 |
| `homes` 产品去留 | 用户未决定；生产 passdb 无用户 | A0 |
| 是否有客户端依赖 NetBIOS 发现 | 无电视/旧 Windows 实测证据 | B3 |
| curl 的真实调用方与协议 | 已盘完：`miDebug.sh`（HTTP，已切）、`mitvapp`（scheme-less HTTP）、`helper.sh`（HTTPS/`-k`）、`wifishare.sh`（HTTP，只读 `/usr`）、`netspeed`（只读 `/usr`）；全量替换判定不可行 | B2 |
| Dropbear 是否有带外恢复渠道 | 仓库无串口/实体维护入口证据；本轮按用户授权，以“完整备份 + 隔离双演练 + 独立看护 + 完整回退实测”替代带外通道，接管 22 | B1 |
| MiniDLNA 当前实际使用情况 | 按“在用”处理；本轮用户决定推迟，未触碰 | B4 |
| dnsmasq 是否由本机承担 DNS/DHCP | 当前未运行、无 53 监听 | B5 |
| WebDAV 撤权语义与看护进程 | 已定稿：5 秒（按 MAC 全包 DROP）+ fail-closed + 租约/看护；与 SMB 10–22 秒的差异写入 D-S11-06 | B6 |
| 8443 能否在不动系统库的前提下收紧 TLS | 管理链未回归 | 系统 OpenSSL（§3） |

## 11. 阶段 4/5 最终状态（2026-11-10 更新）

维护窗口内完成一次整机冷启动；证据目录 [docs/evidence/2026-11-09-stage4](../evidence/2026-11-09-stage4/README.md)。B1 于 2026-11-10 单独窗口接管 22，证据 [docs/evidence/2026-11-10-b1-takeover](../evidence/2026-11-10-b1-takeover/README.md)。

| 编号 | 组件 | 最终状态 | 说明 |
|---|---|---|---|
| A0 | Samba 1.0.7 | **PASS（冷启动）** | 重启后 139/445 归 `samba-s5d`；`chain=present jumps=2 legacy=absent guest=enforced`；cron 行持久；`smbutil` 可枚举。`homes` 产品去留已定**隐藏**（2026-11-10）：`homes=0`，冷启动被厂商 `datacenter` 异步改回 1 后由 S97 init + 有界复检压回，枚举中无 `nobody`/`Home Directories`；三次冷启动验证通过（见 `decisions.md` S15） |
| A1 | Samba 上游维护 | **未触发** | 上游 stable 仍 4.25.1，无部署对象 |
| B1 | Dropbear 2026.94 | **PASS（22 已接管，含冷启动）** | 原厂二进制/配置/host key/authorized_keys/init 先做字节备份并 `md5sum -c` 校验（`/userdisk/data/dropbear-state/backup-dropbear-v2011.54/`）。隔离 2223 双演练：成功路径写标记；强制失败路径由独立看护 15 s 到点杀掉新实例、22 保持原厂。22 接管后 banner `dropbear_2026.94`、既有公钥登录成功、`/proc/<pid>/exe` 指向私有树、认证方法 `publickey,password`、LuCI 200、SMB 未变；`/etc/init.d/dropbear` wrapper 的标记开/关 stop/start 与 `rollback-22.sh` 完整回退均实测。**2026-11-10 01:45 真实 `reboot`**：约 50 s 恢复，`/userdisk/data` 于 16.66 s 挂载、dropbear 37.29 s 启动，冷启动后 22 仍为 2026.94（未回退），host key 指纹与公钥登录正常；Samba/nmbd/ACL/cron/LuCI 无退化。见 [证据](../evidence/2026-11-10-b1-takeover/coldboot.md) |
| B2 | curl 8.23.0 | **部分覆盖（全量替换不可行）** | `miDebug.sh` 已切；`mitvapp` 的 `localhost:` URL 无法用 `--proto-default`/`--proto =http` 覆盖（实测 http=000），只有改写调用方为 `http://` 才等价；`helper.sh` 的 `-skL` 依赖 HTTPS，私有 curl 仅 `Protocols: http`；`wifishare.sh`、`netspeed` 位于只读 `/usr`，PATH 全为只读目录，无法 shim。见 [证据](../evidence/2026-11-09-followup/b2-curl-analysis.txt) |
| B3 | nmbd 4.25.1 | **PASS** | 137/138 归私有 `versions/1.0.7-r2d/root/sbin/nmbd`；单实例；`samba restart` 与整机冷启动后均未被拉回原厂；NetBIOS 名称注册与浏览正常 |
| B4 | MiniDLNA 1.3.3 | **推迟（本轮未触碰）** | 用户决定推迟，二进制与配置一行未动，8200 未监听。保留既有 BLOCKED 原因（App 清单 `status=6`；`supervisord`/`taskmonitorTool` 按 `PROCLINE=/usr/bin/minidlna` 启停，改名切换会让启停/重载不可验证）作为恢复该项时的起点 |
| B5 | dnsmasq 2.92rel2 | **未触发** | 本机不承担 DNS/DHCP，无 53 监听；阶段 2 已产出候选二进制，但无部署对象 |
| B6 | WebDAV（lighttpd） | **PASS（生产）** | **已上线**：`192.168.3.2:5005`，Digest 认证（`realm=r2d-webdav`），降权 `nobody` 运行，只暴露 `下载/共享/图片/文档` 四个 bind mount；`.dev` 等未映射目录返回 404。设备与用户 Mac 的 curl 均完成 PROPFIND/PUT/GET/MOVE/MKCOL/DELETE 与 401 校验；`/etc/init.d/webdav`（START=99）等数据盘最多 180 s 后拉起，30 s 看护进程可自愈；整机冷启动后自动恢复并复测通过。§2.8 五项前置以 S16 的真实认证+最小暴露方案替代，不再引入 macfilter 5 秒撤权。见 D-S16-01…07 |

**边界核对**：B1 已接管 22（原厂二进制仍在 `/usr/sbin/dropbear`，回退脚本实测可用）；未改 `macfilter`/`sysapi`/`shareUpdate` 语义；1.0.6 回滚树与 `state/previous` 保留；B4 一行未动；B6 以独立实例新增 5005，不改任何现役服务配置，回退为停服务 + 删 rc.d 链接。

**不在八项候选内的系统组件**：内核、uClibc、BusyBox、iptables/ipset、系统 OpenSSL、`sysapihttpd`/nginx/uhttpd、无线栈、固件分支按 §3 结论保持不动。其中 OpenSSL 1.0.1j 的单独说明（现状、17 个消费者、为什么卡死、风险面）见 [系统 OpenSSL 为什么不在升级范围](../audits/openssl-not-upgraded-2026-11-10.md)。

原始证据按日期归档在 [docs/evidence](../evidence/README.md)，索引列明每个目录的内容与对应条目。
