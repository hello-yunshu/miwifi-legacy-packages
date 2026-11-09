# R2D 软件升级总计划与可行性审计

- 基线设备：MiWiFi R2D / 固件 2.25.209 / ARMv7 EABI / uClibc 0.9.33.2 / Linux 2.6.36
- 计划日期：2026-11-09（第二版，按 1.0.7 审计清单修订）
- 本轮范围：**只修订本计划与安装器门禁，不执行任何设备动作**（不装包、不重启、不恢复回滚资产）
- 状态：Samba 4.25.1 / 1.0.7-r2d 已在设备运行；其余候选仍为计划，**本计划不表示已构建或安装这些候选**
- 事实来源：[2026-11-08 设备清点](../device-inventory-2026-11-08.md)、[固件 2.24.11 可行性比对](../firmware-2.24.11-feasibility-2026-11-08.md)、[Samba 发布就绪复核](../release-readiness-2026-11-08.md)
- 最新只读现场证据：[2026-11-09 14:29 快照](../evidence/2026-11-09-stage0/readonly-capture.txt)；历史审计结论须结合该快照阅读
- SMB 当前状态审计：[1.0.7-r2d 审计](../audits/smb-1.0.7-audit-2026-11-09.md)
- 说明：设备清点、固件可行性、阶段 0 快照与 SMB 审计属于另一条清点线，尚未纳入版本控制；在其提交前，远端打开上述链接会 404。

## 0. 本版相对上一版的改动

| 项 | 修改内容 |
|---|---|
| 回滚资产 | 阶段 0 新增硬前置“恢复回滚资产并实测 rollback”，含恢复方式、验证命令、判定标准（§4.1） |
| 候选表 | 收敛为 A0、B1、B3、B2（条件触发）；A1 改为维护政策（§1.1）；B5 移入“明确不做”；B6 WebDAV 单独立项，本计划只留“未立项”；B4 保留为决策门 |
| nmbd | 身份结案（PID 2071 / `/usr/sbin/samba_multicall` / 4.0.21），开放问题只剩“是否切换”（§2.3） |
| homes | 拆成“运行时加载哪份配置、是否真的可枚举”与“产品决策”两件；删除不可执行的“有效用户”验收（§2.1） |
| 顺序 | 构建序与部署序拆成两张表；部署序按不可逆性 × 阻塞面排序；A0 冷启动进窗口表；curl 降为条件触发（§4.2、§4.3） |
| 部署项 | 每项补影响面、窗口时长量级、回滚时限、验证命令（§4.3） |
| 回归 | SMB1/2/3、MAC 策略、摄像机只读、U 盘挂载、并发/签名/加密矩阵内联（§5）；原 S1–S8 文档已删除，不再引用 |
| 其它 | 容量预算（§6）、跨组件交互矩阵（§7）、验收项判定命令化（§8）、Dropbear 接管点与超时恢复脚本（§2.2） |

## 1. 决策摘要

现有证据支持的路线是：**维持官方固件、内核、uClibc 和系统共享库；只在 `/userdisk/data` 上构建和安装可回滚的私有用户态程序。** `/userdisk/data` 是独立 ext4 分区（约 446 GB 可用）；根分区只剩 20 588 KB 且为只读 ubifs，不能把新依赖装入根分区。

### 1.1 候选（收敛后）

| 次序 | 组件 | 当前证据 | 决策 | 触发条件 / 开放问题 |
|---|---|---|---|---|
| A0 | Samba 服务与 1.0.7 兼容层 | Samba 4.25.1 运行，139/445 归 `samba-s5d`；ACL 规则面与 cron 自愈有设备证据 | **先完成现有版本收尾**：升级后冷启动核对、`homes` 运行时确认与产品决策 | 访客端到端保持 BLOCKED，直到有可用访客 BSS 与客户端 |
| B1 | Dropbear SSH 服务端 | 2011.54，TCP 22 对 LAN/访客网可达；候选 2026.94 源已锁定并验签 | **构建候选并并行测试**；接管 22 需先具备不依赖候选的回退通道 | 无带外恢复通道前不接管唯一 SSH 入口 |
| B3 | `nmbd` | 身份已确认：PID 2071，`/usr/sbin/samba_multicall`，`nmbd -V` = 4.0.21，持有 UDP 137/138 | **可切换**（复用 1.0.7 私有树里的 4.25.1 `nmbd`，零构建） | 唯一开放问题：是否有客户端依赖 NetBIOS 浏览/发现；未证明前不切换 |
| B2 | curl | 7.33.0 + PolarSSL 1.3.16，是客户端；仓库内未见调用点，设备侧只发现 `/etc/init.d/miDebug.sh` 引用 | **条件触发**：只有盘点出真实调用方、且其协议/参数需要新版时才构建 | 无调用方则不构建、不部署 |
| B4 | MiniDLNA / ReadyMedia | 1.1.0；一次清点未运行，但配置启用且管理链可拉起 | **决策门**：先由用户确认是否使用 DLNA | 确认使用才进入候选；否则维持原状 |

### 1.2 明确不做

| 组件 | 处置 | 理由 |
|---|---|---|
| dnsmasq 2.71 | **不做** | 设备未运行、无 53 端口监听，DNS/DHCP 由上游提供；升级未运行的服务没有收益 |
| WebDAV（B6） | **未立项** | 本计划不含该项排期；设计材料另存于 [WebDAV 立项材料（未立项）](webdav-proposal-unfiled-2026-11-09.md)，需单独批准后才转为正式计划 |
| OpenSSL 系统库、BusyBox、iptables/ipset、uClibc、管理面 Web 栈、内核/模块、固件分支 | **不纳入单包升级** | 多消费者、厂商集成或闭源 ABI 约束；详见 §3 |

### 1.3 维护政策（取代原“A1 Samba 上游上升级”候选）

| 对象 | 触发条件 | 复核动作 | 负责人 | 频率 |
|---|---|---|---|---|
| Samba 4.25.1 | 上游发布新 stable 或安全公告涉及本构建启用的功能 | 重核发布记录与源码签名 → 重锁源码/依赖 → 迁移 SDK 适配补丁 → 走 §5 回归 → 独立窗口部署 | 项目维护者（单一负责人，待指认） | 每季度例行 + 安全公告即时 |
| Dropbear | 上游新版本或算法弃用公告 | 复核变更日志与签名 → 只在已具备回退通道时重测 | 同上 | 每季度例行 |
| curl | 设备实际调用方新增或上游高危公告 | 复核调用方参数是否受影响 | 同上 | 随调用方变更 |
| 1.0.7 兼容层 | 适配器/ACL/安装器改动 | 递增包版本、重跑 §5 的 MAC 与访客规则项 | 同上 | 每次改动 |
| 设备侧基线 | 每季度或固件变更后 | 跑只读快照 + §4.1 回滚实测 | 同上 | 每季度 |

维护政策只定义触发与动作，不承诺上游响应时限；未指定负责人前，本表不构成 SLA。

### 1.4 回滚资产是硬前置

2026-11-09 清理后，设备只保留 1.0.7 现役树，`state/previous` 已删除，`rollback` 返回 6。**在该状态恢复并实测通过前，§4.3 中所有写入或重启类动作都不得开始。** 恢复方式与判定标准见 §4.1；安装器已加入门禁，防止在回滚指针悬空时静默升级。

## 2. 候选详述

### 2.1 A0：Samba 1.0.7-r2d 收尾

设备当前运行 Samba **4.25.1**；`1.0.7-r2d` 是兼容层/安装包版本，Samba payload 与 1.0.6 相同（SHA-256 `0101e0a7…eb2d58`），改动是访客网 SMB 规则与自愈。上游当前 stable 同为 4.25.1，因此**当前没有需要立即部署的 Samba 上游升级**。[Samba 发布记录](https://www.samba.org/samba/history/)

收尾有三件：

| 工作项 | 现状 | 判定方式 | 完成标准 |
|---|---|---|---|
| 升级后整机冷启动 | 现有证据只覆盖安装、`samba restart`、cron 同步；装包早于当前 uptime，无冷启动记录 | `uptime -s`、`readlink /userdisk/data/s7root/current`、`netstat -ltnp \| grep -E ':(139\|445) '`、`iptables -S INPUT`、`crontab -l \| grep diskacl-sync` | 冷启动后 139/445 仍归 `samba-s5d`；`diskacl-status` 为 `chain=present jumps=2 legacy_chain=absent guest=enforced`；cron 行存在；SSH 22 与 Web 80/8443 正常 |
| `homes` 运行时确认 | UCI `samba.@samba[0].homes=1`；适配器据此输出 `[homes]`（comment/browseable=no/read only=no/create mode=0750，无 `path`）；macOS `smbutil view -N` 列出 `homes` | `uci get samba.@samba[0].homes`；`LD_LIBRARY_PATH=… testparm -s /userdisk/data/s7root/current/etc/smb.conf \| sed -n '/^\[homes\]/,/^\[/p'`；`smbutil view -N //guest@192.168.3.2` | 生产 smbd 实际加载的 `$ROOT/etc/smb.conf` 与 UCI 一致，枚举结果与该配置一致；确认“哪份配置在生效、是否真的对外可枚举”这一事实 |
| `homes` 产品决策 | 设备私有 `smbpasswd` 为 0 字节、`pdbedit -L` 无用户，**不存在“有效用户”可测**；内容访问只能在隔离实例里建测试用户 | 决策记录（保留 / 隐藏 / 删除）；若隐藏则 `homes=0` 单独递增包版本，回归普通共享与 App 逻辑 | 决策有书面记录；若改动，独立窗口验证普通共享、原厂 App 与回滚 |

**不再保留的验收**：“对 guest 与有效用户分别验证 `homes` 枚举、tree connect、读写”。生产 passdb 没有用户，这条在当前设备上不可执行；真实内容访问测试只能在隔离实例（1445、独立 passdb、临时测试用户）里做，且不属于 1.0.7 收尾的发布门槛。

访客网 SMB 端到端仍 BLOCKED：Broadcom 驱动 `WLC_SET_VAR(bss)` 失败，`wl1.2` 无法创建，`br-guest` 无成员。不得为补测继续改这台设备的无线配置。

### 2.2 B1：Dropbear 2011.54 → 2026.94

上游发布页当前列出 Dropbear 2026.94；设备上的 2011.54 实际监听 TCP 22。2026-11-09 的防火墙修订只覆盖 SMB 139/445，原厂规则仍对所有接口放行 TCP 22/80，因此 SSH 的访客网可达性尚未改变。[Dropbear 发布记录](https://github.com/mkj/dropbear/releases)

**收益**：直接更新对外提供 SSH 的旧组件；不必替换系统 OpenSSL（Dropbear 不链接它）；可放在私有目录，与 BusyBox/uClibc 隔离。

**代价与风险**

- SSH 接管失误会把维护者锁在设备外；仓库没有串口或带外控制台证据。
- 编译成功不代表可用：需验证 GCC 4.8.2 / uClibc 0.9.33.2 / Linux 2.6.36 下的 ELF、熵源、线程、主机密钥与认证行为。
- 算法默认值变化会让现有客户端或自动化脚本失联；不能靠重新开启弱算法掩盖。
- 私有树在 `/userdisk/data`；盘未挂载时新服务起不来，启动入口必须回退原厂程序。
- 单纯升级不改变访客网可达性；限制 22 端口是另一个防火墙变更，需单独回归。

**接管点（唯一可写入口）**

- `/` 是只读 ubifs（`/dev/ubi1_0 on / type ubifs (ro,…)`），不能替换 `/usr/sbin/dropbear` 或 `/etc/init.d/dropbear` 里的二进制文件。
- `/etc` 是独立可写 ubifs（`/dev/ubi2_0`），因此唯一可行接管点是**启动脚本 `/etc/init.d/dropbear`**：内容改为 wrapper，成功标记存在时 `exec` 私有树候选二进制，否则 `exec /usr/sbin/dropbear` 回退原厂。
- 回退点三件套：
  1. `/userdisk/data/s7root/state/dropbear.init.orig`：部署前 `cp -p` 的原文件字节副本；
  2. 原厂二进制 `/usr/sbin/dropbear` 原位保留、不被覆盖；
  3. 窗口内保持第二个已建立的 SSH 会话。
- 超时恢复脚本（接管时后台启动；120 秒内未出现成功标记即恢复原厂 init）：

```sh
#!/bin/sh
# 与接管同时启动。未写入成功标记就恢复原厂 init，避免锁死唯一的 SSH 入口。
sleep 120
[ -f /userdisk/data/s7root/state/dropbear-takeover.ok ] && exit 0
cp -p /userdisk/data/s7root/state/dropbear.init.orig /etc/init.d/dropbear
/etc/init.d/dropbear restart
```

- 判定：接管后独立新建 SSH 会话成功才写入 `dropbear-takeover.ok`；标记未写入则脚本自动回退。没有这套机制就不接管 22。

**验证顺序**：构建机产出 → 备用端口并行运行 + LAN 登录/密钥/会话稳定/断线重连 → 备份 init 与主机密钥 → 窗口内接管 + 超时回退 → 冷启动复查端口归属与旧入口不会重复拉起原厂进程。

### 2.3 B3：`nmbd` 4.0.21 → 私有 4.25.1 `nmbd`

**身份已结案**（2026-11-09 14:29 快照）：PID 2071，`/proc/2071/exe` → `/usr/sbin/samba_multicall`，`nmbd -V` 为 4.0.21，持有 UDP 137/138。私有树里的 4.25.1 `nmbd`（253 126 B，MD5 `2283bda9f01dfa719ad276af28b655a0`）已就绪，**零构建**。

开放问题只有一个：**是否切换**。切换的收益是移除最后一个旧 Samba 家族网络监听；代价是 NetBIOS 名称服务与浏览发现可能影响电视、旧 Windows 客户端、网络邻居与小米 App 的发现路径，而当前证据只证明端口在监听，不能证明谁依赖它。

**交互点**：兼容包装器仍通过原厂 `/usr/sbin/nmbd` 启动它；nmbd 未登记在 TaskMonitor 表内，不能套用 smbd 的接管模型。包装器重启有可能把 nmbd 拉回原厂路径，切换后必须复跑 `samba restart` 与冷启动。

**切换判定**：先在隔离 LAN 核对名称注册、浏览列表、休眠/重启后重注册与 137/138 广播；确认 UDP 端口释放后再启动新实例，不允许两个 nmbd 抢端口。回滚 = 改回包装器原厂路径 + restart。

### 2.4 B2：curl（条件触发）

设备 curl 7.33.0 链接 PolarSSL 1.3.16 与 zlib 1.2.7。上游当前为 8.23.0，其变更记录注明 8.23.0 删除 SMB 协议支持，8.18.0 起提高了 TLS 后端最低版本，因此**不能照抄“curl 8.x + 现有系统 TLS”**。[版本表](https://curl.se/docs/versions.html) · [变更记录](https://curl.se/changes.html)

**触发条件（同时满足才构建）**：设备上盘点出真实调用方；该调用方使用的协议、选项或 TLS 需求确实受旧版限制；确认没有 `smb://` 依赖。

**未触发时**：不构建、不部署，保持现状；仓库内未见调用点不等于设备上没有调用方，结论仅限已扫描范围。

**触发后的约束**：独立名字（如 `/userdisk/data/.../curl-new`）+ 私有 TLS 后端与 CA，不覆盖 `/usr/bin/curl`；调用方逐个改显式路径并保留旧路径回退；未发现真实调用方时停在候选构建。

### 2.5 B4：MiniDLNA 决策门

设备清点记录 MiniDLNA 1.1.0 未运行，但 `/etc/config/minidlna` 启用，后续复核实测原厂 `shareUpdate` 可生成配置并由 `supervisord` 拉起服务。**“不在运行”不等于“功能不用”**，因此本项不排期，只设决策门：

- 门 1：用户确认是否仍使用 DLNA；
- 门 2：若使用，另开候选评估（上游 1.3.3，2023 年发布，维护活跃度有限）；
- 门 3：迁移前必须验证 `shareUpdate`/App 门控/`supervisord`/媒体索引/电视发现/重启持久性。

任一门外未通过，维持原状，不构建。

### 2.6 B6：WebDAV（未立项）

**本计划不含 WebDAV 排期。** 既有可行性材料与授权验收草案移至 [WebDAV 立项材料（未立项）](webdav-proposal-unfiled-2026-11-09.md)，仅在用户明确批准立项后重开评估；在此之前不加端口、不加服务、不纳入任何窗口。

## 3. 不纳入本轮的系统组件

| 组件 | 排除原因 | 未来重新立项条件 |
|---|---|---|
| Linux 2.6.36 内核 | 缺少已验证的 BCM4709 BSP 源码/配置；闭源 `wl`、Tuxera 文件系统、`et/ctf/dpsta` 等模块依赖现有 ABI；当前官方固件没有更高版本 | 找到同板完整 BSP、可复现固件构建、模块源码/授权和串口救砖条件 |
| uClibc 0.9.33.2 | 全系统 ELF 运行时 ABI，不是独立可替换库 | 有整套固件源代码并能完整重编所有消费者 |
| BusyBox 1.19.4 | init、shell、系统命令多入口依赖，错误可能影响启动/恢复 | 在固件克隆上逐 applet 比对配置与启动，具备双槽恢复手段 |
| iptables 1.4.12.2 / ipset 6.20.1 | 扩展与内核匹配，防火墙是联网控制面 | 明确需要的扩展、厂商模块对应源码、独立网络回滚测试 |
| `sysapihttpd` / nginx 1.2.2 / uhttpd | 小米管理 API、Lua/FastCGI、证书和固件脚本耦合；uhttpd 当前未监听 | 建立管理 API/App 全链路兼容测试和可靠恢复入口 |
| wpa_supplicant / hostapd | 当前 AP 由 Broadcom `nas`/`wl` 闭源栈处理；wpa_supplicant 未运行，hostapd 不存在 | 替换无线栈的完整 BSP 与无线法规/射频回归条件 |
| OpenSSL 1.0.1j（8443 实际加载） | 被 `sysapihttpd` 加载；设备无 `openssl` CLI。私有 OpenSSL 只保护新工具，不修复 8443 | 厂商支持的 TLS 配置审计结论；未证明不影响 App 前不改 `sysapihttpd` |
| 固件分支 / U 盘刷机 | 2.25.209 以上无已确认的 R2D 开发版；2.24.11 缺 SSH 服务端会自我锁死；U 盘刷机会格式化硬盘 | 不立项 |

## 4. 阶段、顺序与门槛

### 4.1 阶段 0 硬前置：恢复回滚资产并实测 `rollback`

**现状（2026-11-09 清理后）**

- `s7root/versions/` 只剩 `1.0.7-r2d`；`release/` 只剩 1.0.7 tar；`state/previous` 已删除 → `rollback` 立即返回 6（`no previous version recorded`）。
- 本地 `s8-release/` 保留 1.0.6 包：14 307 338 B，MD5 `b19d355c8f5c1fa0f3f67e542b15876d`，SHA-256 `f2285da6cb6c236cf6ea9c8754c62e3788e88f8acbeb2af005bb3d4401b372c1`。
- 结论：**当前部署不可回滚到上一版**，这是所有写入/重启类动作的硬阻塞。

**恢复方式 A（首选，字节可核对）**：把本地 1.0.6 包上传到设备，安装但不启动，再用两次 `activate` 交换，使 `previous` 指向 1.0.6。

```sh
# 1) 上传前后核对：应为 b19d355c8f5c1fa0f3f67e542b15876d
md5sum /userdisk/data/release/miwifi-smb-1.0.6-r2d.tar.gz
# 2) 只建树，不激活、不启动
sh /userdisk/data/s7root/xiaomi-smb-install.sh install \
   /userdisk/data/release/miwifi-smb-1.0.6-r2d.tar.gz 1.0.6-r2d
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

**安装器门禁（本轮已改代码）**：`recipes/samba/xiaomi-smb-install.sh` 在安装前检查 `previous` 指向的树；缺失且目标版本不是该树本身时拒绝安装；安装/激活后校验回滚目标树可解析前缀（不启动），把结果写入 `state/install.log`。详见 §4.1 末尾的“安装器行为”与脚本头注释。

### 4.2 构建序（与部署无关，按依赖与成本）

| 序 | 组件 | 锁定输入 | 前置 | 产出 | 当前状态 |
|---|---|---|---|---|---|
| 1 | Dropbear 2026.94 | SHA-256 `e098034a…b1ae81`，`.asc` 已验签 | 回退通道设计（§2.2） | 私有树 + 并行端口测试包 | 源已锁定，未构建 |
| 2 | curl 8.23.0 | SHA-256 `8dadd7d2…e6c5`，`.asc` 已验签 | §2.4 触发条件成立；私有 TLS 后端选型 | 私有树，显式路径 | 源已锁定，条件触发，未构建 |
| — | `nmbd` 4.25.1 | 复用 1.0.7 私有树产物 | 无 | 零构建 | 产物已就绪 |
| — | WebDAV（lighttpd） | 未立项 | 立项批准 | — | 不排期 |

构建环境固定为容器 `miwifi-s1`（Ubuntu 24.04，镜像 ID `sha256:fe8156…6ef852`），工具链 GCC 4.8.2 / uClibc 0.9.33.2，QEMU `qemu-arm-static`。容器当前没有 Dockerfile，可复现性缺口见 [阶段 0–1 记录](stage-0-1-preparation-2026-11-09.md)。

### 4.3 部署序（按不可逆性 × 阻塞面排序）

| 序 | 动作 | 不可逆性 | 失败会阻塞什么 | 影响面 | 窗口量级 | 回滚时限 |
|---|---|---|---|---|---|---|
| 0 | §4.1 恢复回滚资产 + 实测 rollback | —（前置门） | 全部后续部署 | SMB | 30–45 min | 失败即停，不改包 |
| 1 | A0 升级后整机冷启动核对 | 低（可重复重启） | 整机：所有入口同时不可用 | 整机 / SMB / SSH / 管理面 / 无线 | 10–15 min | 无代码回滚；失败走本地 1.0.7 重装，≤30 min |
| 2 | B3 `nmbd` 切换（若决定做） | 中（发现功能退化不易察觉） | NetBIOS 发现、电视/旧客户端、App 发现 | SMB / 管理面（发现） | 15–30 min | 改回包装器原厂路径 + restart，≤5 min |
| 3 | B1 Dropbear 接管 22 | 高（唯一维护入口） | SSH，进而所有远程维护 | SSH / 管理面 | 30–60 min | 超时脚本自动回退 ≤5 min；无带外通道不执行 |
| 4 | B2 curl 显式路径（逐调用方） | 低（旧二进制保留） | 无服务阻塞 | 仅调用方 | 每调用方 5–15 min | 改回原命令，即时 |
| — | B6 WebDAV | — | — | — | 未立项 | — |

**逐项验证命令**

- **A0 冷启动**：`uptime -s`；`readlink /userdisk/data/s7root/current`；`netstat -ltnp | grep -E ':(139|445) '`；`sh /userdisk/data/s7root/xiaomi-smb-adapter.sh -r /userdisk/data/s7root/current diskacl-status`；`iptables -S INPUT | grep -c 's8-diskacl'`；`crontab -l | grep diskacl-sync`；`smbutil view -N //guest@192.168.3.2`。判据：139/445 归 `samba-s5d`，`chain=present jumps=2 legacy_chain=absent guest=enforced`，三共享可见，SSH 22 与 80/8443 可连。
- **B3 nmbd 切换**：切换前 `netstat -lunp | grep -E ':(137|138) '` 确认端口释放；切换后 `readlink /proc/<pid>/exe` 应为私有树 `nmbd`；`/etc/init.d/samba restart` 后再查一次；冷启动后再查一次。回滚判据：137/138 重新归 `/usr/sbin/samba_multicall`。
- **B1 Dropbear**：新会话 `ssh -p 22 … 'dropbear -V'`；`netstat -ltnp | grep ':22 '`；`/etc/init.d/dropbear restart` 后重连；断开后再连一次；确认 `/etc/init.d/dropbear` 为 wrapper 且原厂副本存在。回滚判据：`cp -p state/dropbear.init.orig /etc/init.d/dropbear && /etc/init.d/dropbear restart` 后原厂版本恢复。
- **B2 curl**：`/userdisk/data/.../curl-new --version` 与 `ldd`/`readelf -d` 确认依赖闭合在包内；调用方逐个比对退出码、标准输出与网络副作用；`/usr/bin/curl --version` 保持 7.33.0 不变。

### 4.4 阶段 1–5 细则

**阶段 1：构建准备，不写设备**

- 确认 SDK GCC 4.8.2 / uClibc 工具链、宿主容器与 QEMU；SDK 与厂商二进制不进入公共发布物。
- 只有上游出现新版本或安全修复时才为 Samba 重锁源码；为 Dropbear、curl 分别固定候选输入。
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

见 §2.1：只保留“运行时配置与枚举一致性”的判定；内容访问不在生产设备上做。

### 5.7 `nmbd`（仅在决定切换时）

| 用例 | 判定方式 | 通过标准 |
|---|---|---|
| 端口归属 | `netstat -lunp`、`readlink /proc/<pid>/exe` | 137/138 归私有树 `nmbd`，单实例 |
| 名称注册 | 同 LAN 隔离设备 + `nmblookup` | 名称可解析 |
| 浏览/发现 | 电视、旧 Windows、App | 列表可见；无设备时标 BLOCKED |
| 包装器重启 | `/etc/init.d/samba restart` | 不被拉回原厂路径 |
| 冷启动 | 重启后复查 | 端口与身份保持 |

### 5.8 Dropbear（仅在候选构建后）

见 §2.2：并行端口、密钥认证、连接保持、断线重连、重启后接管与回退。

### 5.9 curl（仅在触发后）

TLS/CA/主机名/时钟/重定向/超时/代理/退出码；逐调用方比对输出与副作用。

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
| curl + 私有 TLS | 预留 ≤ 20 MiB | 待构建实测，条件触发 |
| 状态/日志/证据 | 预留 64 MiB | `state/install.log`、cron 日志、临时副本 |
| 判定命令 | `df -k /userdisk/data`；`du -sm /userdisk/data/s7root/versions/*` | 部署前执行 |
| 门槛 | 可用 ≥ 预算总和 × 2 | 余量用于重装与掉盘恢复 |

按当前 446 GB 可用，容量不构成阻塞；真正的风险是**盘未挂载时私有树不可用**，由启动入口回退原厂程序覆盖。

## 7. 跨组件交互矩阵

| 组合 | 交互点 | 风险 | 处理 |
|---|---|---|---|
| WebDAV × Samba | 同一磁盘路径并发读写；`macfilter` 语义 | SMB 侧 `lan=no` 生效约 10–22 秒，若 WebDAV 另设 5 秒语义，用户会看到两套时延不一致 | 未立项；立项时必须统一定义撤销语义 |
| Dropbear × 管理面 | 22 端口、`/etc/init.d/dropbear`；App/云端可能重启服务 | 接管失败锁死维护入口；固件侧脚本可能覆盖 init | 备份 init + 保留原厂二进制 + wrapper 回退 + 超时脚本 |
| Dropbear × 磁盘挂载 | 候选树在 `/userdisk/data` | 盘未挂载 → SSH 不可用 | wrapper 检测私有树缺失即 `exec /usr/sbin/dropbear` |
| nmbd × Samba 包装器 | 包装器走原厂路径起 nmbd；nmbd 不在 TaskMonitor 表 | 包装器重启把 nmbd 拉回原厂，覆盖切换 | 切换后复跑 `samba restart` 与冷启动复查 |
| nmbd × smbd | 同族 Samba，共享 NetBIOS 名称与配置 | 两个 nmbd 抢 137/138 | 切换前确认端口释放，单实例 |
| Samba × cron `diskacl-sync` | 每分钟改 iptables | 规则改动与新端口规则冲突 | 新服务若需 ACL，必须纳入同一同步器或独立同步器，二选一并写清 |
| Samba × 访客 BSS | `br-guest` 成员决定规则是否命中 | 驱动无法创建 BSS → 端到端 BLOCKED | 不改无线配置凑结果 |
| 任何新服务 × 根分区 | `/` 只读且仅 20 MB | 误写根分区会失败或破坏系统 | 所有产物只落 `/userdisk/data`；`/etc` 只改启动脚本 |

## 8. 验收项判定命令

| 验收项 | 原问题 | 判定命令 | 通过标准 |
|---|---|---|---|
| nmbd 当前身份 | 曾写“未知”，与快照矛盾 | `netstat -lunp \| grep -E ':(137\|138) '`；`readlink /proc/<pid>/exe`；`nmbd -V` | 已结案：PID 2071 / `samba_multicall` / 4.0.21；后续变更为切换决策 |
| `homes` 是否可枚举 | “可见”不等于“可访问” | `uci get samba.@samba[0].homes`；`testparm -s $ROOT/etc/smb.conf`；`smbutil view -N` | 配置源、渲染结果、枚举三者一致 |
| `homes` 内容访问 | 生产无“有效用户”，不可执行 | 隔离实例建测试用户后 `smbclient -U test%…` | 只在隔离实例判定；生产不建用户 |
| 1.0.7 冷启动 | 无记录 | `uptime -s`、`current` 链接、139/445 归属、ACL 状态、cron 行 | §4.3 第 1 项全部通过 |
| 回滚可用 | 原为“需可回滚” | §4.1 的六条判定 | 全部通过 |
| 访客端到端 | 规则面通过，端到端未验 | 真实访客客户端连 139/445 + `iptables -L INPUT -v -n` DROP 计数 | 无客户端时保持 BLOCKED，不以规则面代替 |
| 构建可复现 | 原为“干净重建” | 两次构建 `sha256sum` 比对 + `smbd -b` | 字节一致且前缀正确 |
| 原厂回退路径 | 原为“始终保留” | `ls /userdisk/data/s8compat/versions/v0-vendor`；`grep -n 'rollback' /userdisk/data/s8compat/install.sh` | 原厂 init 与二进制备份存在；rollback 分支指向 `v0-vendor` 且未被改动 |

## 9. 窗口纪律与立即停手条件

- 单窗口单组件；窗口开始前必须已完成 §4.1。
- 窗口内保持第二个已建立的 SSH 会话；Dropbear 窗口额外准备超时脚本。
- 立即停手并回滚的条件：SSH 无法新建会话 / 139/445 归属变化 / 80 或 8443 管理面失效 / DNS、DHCP、无线异常 / 磁盘挂载变化 / `rollback` 或 `activate` 返回非 0。
- 停止只回滚当前组件，不连带调整其它服务；恢复后再重新评估是否继续。

## 10. 尚待确认的证据

| 问题 | 当前状态 | 对计划的影响 |
|---|---|---|
| 1.0.7 冷启动后整机状态 | 无记录（装包早于当前 uptime） | 阻塞 A0 收尾判定 |
| `homes` 产品去留 | 用户未决定；生产 passdb 无用户 | 决定是否单独发版 |
| 是否有客户端依赖 NetBIOS 发现 | 无电视/旧 Windows 实测证据 | 决定 nmbd 是否切换 |
| curl 的真实调用方与协议 | 仅发现 `/etc/init.d/miDebug.sh` 引用，更深用户目录未盘完 | 决定是否构建 curl |
| Dropbear 是否有带外恢复渠道 | 仓库无串口/实体维护入口证据 | 未解决前不接管 22 |
| MiniDLNA 是否仍在使用 | 用户未确认 | 决策门，不排期 |
| 8443 能否在不动系统库的前提下收紧 TLS | 管理链未回归 | 系统 OpenSSL 不替换；单独立项审计 |
