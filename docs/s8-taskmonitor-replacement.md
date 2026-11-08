# TaskMonitor 替换与新版 SMB 长期接管（S8）

日期：2026-11-08。设备：R2D / ROM 2.25.209，Linux 2.6.36 / uClibc / ARMv7。状态：**新版 `samba-s5d` 已长期占用 139/445，两次重启后归属不变，回滚路径可用**。

本文回答四件事：TaskMonitor 管了哪些条目、`taskmonitorServer` 缺位会怎样、替换谁、139/445 现在归谁。所有数字来自本机实测；未测到的明确标 BLOCKED。

## 0. 结论摘要

| 问题 | 结论 | 依据 |
| --- | --- | --- |
| 替换对象 | **不是 `taskmonitorServer` 本体**，而是 SMB 服务入口 `/etc/init.d/samba` 及其管理的 smbd 条目，用版本化兼容外壳实现 | [§2](#2-taskmonitorserver-缺位实测)、[§3](#3-替换对象判定) |
| 为什么不动 server | server 缺位时 `supervisord start` 返回 0 但不启动任何进程；开机时将导致 32–33 个受管服务静默起不来 | [§2](#2-taskmonitorserver-缺位实测) |
| 其它服务影响 | 32–33 条非 SMB 条目 PID 全部不变；`fan_tmp` 与新版 smbd 抽样 kill 后 8 s 自愈；四个原厂哈希不变 | [§5](#5-服务影响实测) |
| 139/445 归属 | **归新版 `samba-s5d`**；两次重启后仍归新版，**没有原厂 smbd 进程**（`/usr/sbin/smbd` 文件本身是 `samba_multicall` 的符号链接） | [§6](#6-139445-归属与重启持久化) |
| App 改设置 | 经 `/etc/init.d/samba` 的 `reload/restart/stop/start` 四条路径均落到新版（入口级验证；真实 App BLOCKED） | [§6.3](#63-app-路径) |
| 回滚 | `install.sh rollback` 恢复原厂 smbd 与任务条目；验证后重新激活新版 | [§7](#7-回滚验证) |
| 真实 App / OTA | **BLOCKED**（无真实手机端、未做固件升级） | [§8](#8-未验证与-blocked) |

## 1. TaskMonitor 任务表全量条目（33–34 条，动态）

`/tmp/taskmonitor/taskmonitor.conf`：固定 **2812 B/记录**。切换前 33 条 = 92,796 B；审计收尾 34 条 = 95,608 B（`web_filter_record` 随机延迟注册）。二进制变长字段（cmdline[700] + matchcmdline[700] + monname[256] + 4×256 + PID[120]）。记录由 `taskmonitorServer` 在任务变更时写回，`/tmp` 为 tmpfs，重启丢失后由各 init 经 `supervisord` → `taskmonitorTool` 重新注册。

下表为最后一次重启后（uptime ≈ 165 s）的快照，表内 33 条；`web_filter_record` 注册后为 34 条。PID 会随重启变化，条目集合以 cmdline 为准。

| # | cmdline（截断） | 别名 | 注册来源（init / rc.d） | PID |
| --- | --- | --- | --- | --- |
| 00 | `/bin/eapd` | eapd | `/etc/init.d/eapd`（`START` 已注释，无 rc.d，由 Wi-Fi 运行时拉起） | 4340 |
| 01 | `/usr/sbin/nas` | nas | `/etc/init.d/nas`（同上） | 4342 |
| 02 | `/usr/sbin/acsd` | acsd | `/etc/init.d/acsd`（同上） | 4635 |
| 03 | `/usr/sbin/bcm_bsd` | bcm_bsd | `/etc/init.d/bcm_bsd`（同上） | 4401 |
| 04 | `/bin/wps_monitor` | wps_monitor | `/etc/init.d/wps_monitor`（同上） | 4426 |
| 05 | `nice -n-5 spawn-fcgi …:8920 … fcgi-cgi -c 8` | nice -n-5 spawn-fcgi | `/etc/init.d/sysapihttpd`（S21） | 4843 |
| 06 | `/usr/sbin/sysapihttpd -c /tmp/sysapihttpdconf/…` | sysapihttpd | 同上 | 5164 |
| 07 | `nice -n-5 spawn-fcgi …:8960 … fcgi-cgi -c 4` | nice -n-5 spawn-fcgi | `/etc/init.d/mihttpd`（S22） | 5222 |
| 08 | `/usr/sbin/sysapihttpd -c /etc/mihttpd/mihttpd.conf` | sysapihttpd | 同上 | 5247 |
| 09 | `/usr/bin/mald 6`（match `messagingagent --handler_threads 6`） | mald | `/etc/init.d/messagingagent.sh`（S49） | 5481 |
| 10 | `/opt/filetunnel/tunnelserver` | tunnelserver | `/etc/init.d/filetunnel`（S55） | 5779 |
| 11 | `/opt/filetunnel/stunserver --verbosity 1` | stunserver | `/etc/init.d/stunserver`（S55） | 5829 |
| 12 | `/usr/sbin/fan_tmp.sh`（match `/bin/sh …`） | fan_tmp | `/etc/init.d/fantmp`（S60） | 5898 |
| 13 | `/usr/sbin/trafficd` | trafficd | `/etc/init.d/trafficd`（S77） | 6074 |
| 14 | `/usr/sbin/indexservice` | indexservice | `/etc/init.d/indexservice.init`（S78） | 6210 |
| 15 | `/usr/sbin/netapi` | netapi | `/etc/init.d/netapi`（S78） | 6240 |
| 16 | `/usr/sbin/datacenter` | datacenter | `/etc/init.d/datacenter`（S80），cgroup `/dev/cgroup/mem/group1/tasks` | 6331 |
| 17 | `/usr/bin/himan --proxy …` | himan | `/etc/init.d/himan.sh`（S80），cgroup `cpu/plugin` | 6370 |
| 18 | `/usr/bin/hiapk2 5 20` | hiapk2 | `/etc/init.d/himan2.sh`（S81），cgroup `cpu/plugin` | 6403 |
| 19 | `/usr/sbin/uaq-agent` | uaq-agent | `/etc/init.d/uaq-agent`（S87），cgroup `cpu/plugin` | 6449 |
| 20 | `./sbin/samba-s5d -D -s /userdisk/data/s7root/current/etc/smb.conf …` | samba-s5d | **S8 兼容 hook**（原 S96samba 的 smbd 条目位置） | 6377 |
| 21 | `/usr/sbin/plugincenter` | plugincenter | `/etc/init.d/plugincenter`（S97），cgroup `net_cls/limited` | 9290 |
| 22 | `/usr/sbin/pluginTaskmonitor` | pluginTaskmonitor | `/etc/init.d/plugintaskmonitor.init`（S97） | 9370 |
| 23 | `/usr/sbin/http_dpi` | http_dpi | `/etc/init.d/http_client_detect`（S99） | 10133 |
| 24 | `/usr/sbin/noflushd -n 5 /dev/sda` | noflushd | `/etc/init.d/noflushd`（S99） | 10935 |
| 25 | `/usr/bin/lua /usr/sbin/oui` | lua | `/etc/init.d/oui`（S99） | 10986 |
| 26 | `/usr/sbin/rmonitor` | rmonitor | `/etc/init.d/rmonitor`（S99） | 11113 |
| 27 | `/usr/sbin/smartcontroller` | smartcontroller | `/etc/init.d/smartcontroller`（S99） | 11341 |
| 28 | `watchdog -t 5 -T 120 /dev/watchdog` | watchdog … | `/etc/init.d/softdog`（S99） | 11478 |
| 29 | `statisticsservice -c /etc/statisticsservice/…` | statisticsservice | `/etc/init.d/statisticsservice`（S99） | 11549 |
| 30 | `lua /usr/sbin/ccgame_service.lua` | lua ccgame_service | `/etc/init.d/turbo`（S99） | 11620 |
| 31 | `/usr/bin/wrsst` | wrsst | `/etc/init.d/wrsst`（S99），cgroup `cpu/plugin` | 11683 |
| 32 | `/usr/sbin/xqbc 988` | xqbc | `/etc/init.d/xqbc`（S99） | 11739 |

补充说明：

- **`nmbd` 不在任务表内**。原厂 `start_impl` 用 `service_start /usr/sbin/nmbd -D` 直接拉起，不经 TaskMonitor；新版沿用该行为（快照时 nmbd 7049；审计收尾 23868，UDP 137/138）。
- **条目集合随开机阶段浮动**：`web_filter_record` 的 init 会先 `sleep 0–299 s` 随机值再 `supervisord start`，本次快照时仍在等待（`/bin/sh /etc/rc.common /etc/init.d/web_filter_record restart`，PID 6166），所以快照时不在表内；注册后总数为 34 条。`wrsst` 本次已注册。这是原厂自身行为，与 S8 改动无关。
- `ustackd` 未运行（`ustack` 开关关闭），因此没有对应条目。
- 原厂基线表（切换前）为 33 条，含 `/usr/sbin/smbd -D` 与 `web_filter_record`；当前表 33–34 条（取决于 `web_filter_record` 是否已注册），含 `samba-s5d` 与 `wrsst`。**S8 改动只替换了 smbd 那一条**。

## 2. `taskmonitorServer` 缺位实测

方法：受控窗口内让 `taskmonitorServer` 缺位，用唯一标记 `/bin/sleep 137` 走 `/usr/sbin/supervisord start`，用 `ps w | grep "sleep 137"` 判定是否真正启动。（第一次用 `sleep 120` 被 `syslog-ng.helper` 自身的循环 sleep 误匹配，结论作废并重做。）

| 观察 | 结果 |
| --- | --- |
| `supervisord start` 返回码 | **rc=0** |
| 是否拉起新任务 | **否**：唯一标记进程未出现 |
| 已在运行的服务 | 继续运行，但失去 5 s 周期看护（kill 后不再被拉起） |
| `taskmonitorDaemon` | 只监督 server 自身，不接管任务表 |

结论：**server 是任务注册的唯一入口，且失败是静默的**。如果替换或删除它，开机时 32–33 个依赖它的服务会“rc=0 但没起来”，这比 SMB 单点故障严重得多。因此替换对象排除 server 本体。

## 3. 替换对象判定

| 候选 | 判定 | 理由 |
| --- | --- | --- |
| `taskmonitorServer` 本体 | **否** | §2：缺位即静默失效，影响全部 32–33 个受管服务 |
| TaskMonitor 里的 smbd 条目 | **是，但不够** | 单独注销只能赢一次端口；任何 `init.d/samba start` 都会重新注册原厂条目 |
| `/etc/init.d/samba` 入口 + 兼容外壳 | **采用** | App、云端、开机、管理面自愈最终都走这个入口；入口归新版，端口归属才稳定 |

实现：`/etc/init.d/samba` 变成稳定 wrapper，`source` 原厂逐字节副本 `/etc/init.d/samba.vendor`，只覆盖 `start_impl/stop/reload/status` 四个入口；真正的驱动逻辑放在版本化 hook 里。原厂 `start()` 的 App 开关门控（manifest `status == 5`）被完整继承，未改用户数据语义。

## 4. 版本化布局

```
/etc/init.d/samba                     wrapper（md5 f83e513bd2ceb0e0792cd28390358b81）
/etc/init.d/samba.vendor              原厂 init 逐字节副本（md5 a26f32ce175be65ba4613c1aac72b4e1）
/userdisk/data/s8compat/
  versions/v0-vendor/samba.init       原厂 init + vendor.md5
  versions/v1/hook.sh                 兼容驱动（md5 19fa4ad37729cf4d663d06f0a77d493f）
  versions/v1/xiaomi-smb-adapter.sh   适配器（md5 cf76d9948930682cbc8f4614d0cfbe7f）
  versions/v1/samba.init.wrapper      wrapper 副本（md5 f83e513b…）
  versions/v1/MANIFEST                md5 清单（覆盖 hook/adapter/wrapper 三项）+ hotplug.md5
  current -> versions/v1 | versions/v0-vendor
  stage/                              本轮推送的安装文件（install.sh md5 b5d4e0049500b8a2d68941339d893c6c，含 hotplug 安装）
/userdisk/data/s7root/current         新版 SMB 安装树（samba-s5d / nmbd / 私有库）
/userdisk/data/s8backup/              切换前基线（baseline-1540.txt、pre-activation.txt、samba.uci …）
```

- 安装：`install.sh install` → 备份原厂 init 到 v0、复制 hook/adapter/wrapper、`sh -n` 语法校验、生成 MANIFEST、`ln -sfn versions/v1 current`、创建编译前缀链接 `/userdisk/data/samba-s2/root`、自动 `verify`。
- 校验：`install.sh verify`（init 与 vendor.md5 一致、MANIFEST `md5sum -c`、监听检查）；`state` 输出当前版本、PID、任务条目。
- 回滚：`install.sh rollback`（停新版 → `current -> versions/v0-vendor` → `/etc/init.d/samba start` → 等 445）。
- 降级路径：wrapper 发现 `current/hook.sh` 不可执行（回滚、或 `/userdisk/data` 未挂载）时 `exec /etc/init.d/samba.vendor "${action}"`，即完整原厂行为。这里必须用 `"${action}"` 而不是 `"$@"`，因为 `rc.common` 在 source 前已 `shift 2`（本轮踩过，见 D-S8-15）。

## 5. 服务影响实测

激活窗口：**15:46:24–15:46:30（约 6 s）**，从原厂 smbd 注销到新版开始监听。

| 观察项 | 切换前 | 切换后 | 判定 |
| --- | --- | --- | --- |
| 快照 33 条中的非 SMB 条目 | 32 条 PID 快照（`web_filter_record` 注册后为 33 条） | 逐条比对，**PID 全部不变** | 无影响 |
| `fan_tmp` | 7316 | `kill -9` 后 **8 s** 自愈为 21511 | 看护正常 |
| 新版 smbd | 21119 | `kill -9` 后 **8 s** 自愈为 21388，139/445 恢复 | 看护正常 |
| `/etc/config/samba` | `8556a19b…` | `8556a19b…` | 不变 |
| `/etc/config/misc` | `731ebecdfb56528599cd4b09bf0f0f0` | 同左 | 不变 |
| `/var/etc/smb.conf` | `bcad8b90869688b7982a50aaa891cf99` | 同左 | 不变 |
| `/usr/sbin/samba_multicall` | `5e422d3463f40b4405ef8325ce3603e8` | 同左 | 不变 |
| 根分区可用 | 20 588 KB | 20 588 KB | 不变 |

退化判定标准：任一条目 PID 异常、任一关键哈希变化、任一抽样服务 kill 后不自愈 → 立即回滚。本轮未触发。

重启后 `/etc/config/samba` 变为 `244eb53e5019b95a408aebe49602561a`，是原厂开机规范化（`shareUpdate -s`）所致；`uci show samba` 与备份仅在选项顺序上有差异，7 个共享名称/路径完全一致（见 `/userdisk/data/s8backup/samba.uci` 对照）。

## 6. 139/445 归属与重启持久化

### 6.1 开机链路

```
S01fstab（/userdisk/data 约 16.6 s 挂载）
  → S12taskmonitor（server 就位，任务表为空）
  → S96samba（wrapper）
       start_impl → shareUpdate -s → updateconfig（/var/etc/smb.conf）
                  → hook start → adapter -P start（samba-s5d 监听 139/445）
                  → adapter tm-register（以独立别名登记）
                  → service_start nmbd -D
  → S97pluginTaskmonitor …
```

`/userdisk/data` 是内置 1 TB HDD 的 ext4，挂载早于 S96samba（实测约 16.6 s）；`/etc` 是独立可写 ubifs（`/dev/ubi2_0`），重启后保持（wrapper 与原厂副本两次重启后仍在）。早期用于验证的 `/etc/__persist_test` 已在 2026-11-08 审计中作为测试残留删除。

### 6.2 两次重启结果

| 重启 | `samba-s5d` PID | 原厂 smbd 进程 | 139/445 | 任务条目 | 共享 |
| --- | --- | --- | --- | --- | --- |
| 第 1 次 | 6336 | 无 | 新版 | 含 `samba-s5d` | 7 个不变 |
| 第 2 次 | 6377 | 无 | 新版 | 含 `samba-s5d` | 7 个不变 |
| 审计第 1 次 | 6861 | 无 | 新版 | 含 `samba-s5d` | 7 个不变 |
| 审计第 2 次 | 6216 | 无 | 新版 | 含 `samba-s5d` | 7 个不变 |
| 审计收尾 | 23809 | 无 | 新版 | 含 `samba-s5d` | 7 个不变 |

“原厂 smbd 无”的判据是 `/proc/<pid>/cmdline == /usr/sbin/smbd -D` 且 `/proc/<pid>/exe == /usr/sbin/samba_multicall`；`/usr/sbin/smbd` 文件本身存在，是 `samba_multicall` 的符号链接。`pidof smbd` 会漏/误命中新版子进程，`pidof samba_multicall` 会命中 nmbd，都不能单独用作判据。

第 2 次重启后快照：`/etc/init.d/samba` = wrapper、`current -> versions/v1`、nmbd 7049、`/var/etc/smb.conf` 回到 `bcad8b…`、根分区可用 20 588 KB。macOS `nc` 可连 139/445，`smbutil view -N` 到达认证层（guest 关闭，返回 authentication error，属预期）。审计收尾（2026-11-08 16:49）：nmbd 23868、任务表 95,608 B / 34 条、MANIFEST 三项 `OK`、共享 7 个、四个哈希不变。

### 6.3 App 路径

无真实手机 App/云端可用（BLOCKED），以其已知入口 `/etc/init.d/samba <action>` 模拟：

| 动作 | 结果 |
| --- | --- |
| `restart` | 新版 PID 21388 → 22058，约 7 s；全过程无原厂 smbd 出现 |
| `reload` | PID 22893 不变；`shareUpdate` 重渲染 + `smbcontrol all reload-config` 成功 |
| `stop` | 端口释放、任务条目移除，8 s 内未被拉回 |
| `start` | 22893 恢复，139/445 回到新版 |

全盘扫描确认没有其它二进制直接调用 `/usr/sbin/smbd`。因此**入口级**判断成立；真实 App 是否会绕过 `init.d` 直接驱动 `supervisord` 或原厂二进制未验证（BLOCKED），不能把结论扩大成“App 一定抢不回端口”。原厂“SMB 关闭”门控仍生效：manifest 未到 `status=5` 时 `start()` 不执行 `start_impl`。

### 6.4 归属结论与失败层次

- **能撑过重启**：`/etc` 持久（wrapper/vendor 副本）+ `/userdisk/data` 持久（版本树、hook、新版二进制）；两次重启验证通过。
- **App 改设置（入口级）**：`reload/restart/stop/start` 四条入口均落到新版并实测；真实 App 未操作，BLOCKED。
- **做不到的层次**：
  1. **固件 OTA / 恢复出厂**会覆盖 `/etc`，wrapper 与 `samba.vendor` 消失，端口回原厂 —— BLOCKED，未做 OTA。
  2. `/userdisk/data` 未挂载或 HDD 故障时，hook 不可用，wrapper 回退 `supervisord start`，**原厂 smbd 接管 139/445**。这是有意的 fail-safe，但只是代码路径，未做物理拔盘/坏盘演练（BLOCKED）。
  3. 真实手机 App / 云端下发未验证，仅验证其入口。

## 7. 回滚验证

`/userdisk/data/s8compat/install.sh rollback`：

1. `adapter stop`（先 `tm-unregister`，再按 PID 文件停止）；
2. `current -> versions/v0-vendor`；
3. `/etc/init.d/samba start`（此时 wrapper 因 hook 不可执行而 `exec vendor`）；
4. 等 445 出现并核对。

结果：原厂 smbd 以 PID 15176 恢复 139/445，任务表重新出现 `/usr/sbin/smbd -D` 条目；随后重新 `install` 激活新版（PID 16377），再次重启后为 6377（审计收尾 23809）。**两种确定状态都实际到达过，没有停在中间态。**

## 8. 未验证与 BLOCKED

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 真实手机 App / 云端改共享、开关 SMB | **BLOCKED** | 无真实 App 操作；只验证了其入口 `init.d/samba` 的四条路径 |
| 固件 OTA / 恢复出厂 | **BLOCKED** | 会覆盖 `/etc`，需重新安装；未做真实升级 |
| `/userdisk/data` 缺失/挂载失败 | **BLOCKED（代码路径存在）** | wrapper 会回退原厂 supervisord，未做物理拔盘/坏盘演练 |
| `web_filter_record` 开机注册 | 原厂行为 | init 随机 `sleep 0–299 s`；快照时未注册，不属退化 |
| 适配器 `status` 陈旧 PID 文件 | 已知小问题 | TaskMonitor 自愈重启后短时间内可能报 stopped；`stop/start` 正常 |
| 摄像机 / Emby / IPv6 / 签名 | 同 [S8 候选发布](s8-candidate-release.md#10-已知限制与阻断) | 未变化 |

## 9. 当前设备状态（2026-11-08 审计收尾快照）

| 项 | 值 |
| --- | --- |
| `/etc/init.d/samba` | `f83e513bd2ceb0e0792cd28390358b81`（wrapper） |
| `/etc/init.d/samba.vendor` | `a26f32ce175be65ba4613c1aac72b4e1`（原厂） |
| `s8compat/current` | `versions/v1` |
| 编译前缀链接 | `/userdisk/data/samba-s2/root -> /userdisk/data/s7root/versions/v1/root` |
| MANIFEST | hook/adapter/wrapper 三项 `md5sum -c` 全部 `OK` |
| 新版进程 | `samba-s5d` 23809（子进程 23817/23818/23873，随重启变化） |
| nmbd | 23868，UDP 137/138 |
| 139/445 | `192.168.3.2:139/445` → 23809 |
| TaskMonitor | `taskmonitorServer` 1090、`taskmonitorDaemon` 1092；任务表 95,608 B / 34 条 |
| `/etc/config/samba` | `244eb53e5019b95a408aebe49602561a`（7 共享，语义与备份一致） |
| `/etc/config/misc` | `731ebecdfb56528599cd4b09bf0f0f0` |
| `/var/etc/smb.conf` | `bcad8b90869688b7982a50aaa891cf99` |
| `/usr/sbin/samba_multicall` | `5e422d3463f40b4405ef8325ce3603e8` |
| 根分区可用 | 20 588 KB |

设备处于“新版在跑”状态；完整回原厂只需执行 `install.sh rollback`。
