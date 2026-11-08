# `/etc/config/samba` 2026-11-08 05:05 变更取证

S6 报告中遗留的“外部改动”结论在此补齐。所有结论均来自设备上可读的证据；无法证明的部分明确标注。

## 结论

1. **触发者属于原厂管理栈，不是 SSH/手工编辑，也不是 Samba 设置页保存。** 变更发生在 `2026-11-08 05:05:48`，同一秒 `TaskMonitorServer`（PID 1090）执行了两条服务停止命令，调用方是两个 `TaskMonitor[Tool]` 进程（PID 6626、6638）。
2. **同秒被重写的还有 `/etc/config/misc` 与 `/etc/crontabs/root`（含目录 mtime），是同一批配置保存的一部分**，不是 SMB 单点操作。
3. **共享语义没有变化。** 当前 UCI 仍对应 7 个有效共享，与正在使用的 `/var/etc/smb.conf` 同名、同路径、同选项；多出的只有一个空的 `config sambashare` 段，属于机器重写产物。
4. **是哪一条管理动作（App 保存、云同步、自动修复）无法证明**：HTTP 访问日志不落盘，TaskMonitor 只记录 kill 结果、不记录发起者。可证明的边界见下文“不可判定部分”。

## 证据

### 时间与持久性

| 项 | 值 |
| --- | --- |
| `/etc/config/samba` | 1795 B，inode 11139087，mtime `2026-11-08 05:05:48` |
| `/etc/config/misc` | 3895 B，inode 11139086，mtime 同秒 |
| `/etc/crontabs/root` | 1211 B，mtime 同秒；`/etc/crontabs` 目录 mtime 同秒 |
| 设备 uptime | 4 天 6:59（启动约 11-04 06:20），**跨过 05:05，未重启** |
| `/etc` 挂载 | `ubi2_0` 可写 ubifs，非 tmpfs；写入是运行时落盘 |

### 日志（持久 syslog `/userdisk/data/usr/log/messages`）

```
2026-11-08T05:05:48 (none) TaskMonitor[Server]: [1090]: kill task[/usr/bin/wrsst]: not find the task
2026-11-08T05:05:48 (none) TaskMonitor[Tool]: [6626]: TaskMonitorServer return failed !
2026-11-08T05:05:48 (none) TaskMonitor[Tool]: [6626]: TaskmonitorTool cmd(wrsst  stop) return failed!!
2026-11-08T05:05:48 (none) TaskMonitor[Server]: [1090]: kill task[/usr/sbin/ustackd br-lan]: not find the task
2026-11-08T05:05:48 (none) TaskMonitor[Tool]: [6638]: TaskMonitorServer return failed !
2026-11-08T05:05:48 (none) TaskMonitor[Tool]: [6638]: TaskmonitorTool cmd(ustackd  stop) return failed!!
```

- `wrsst`、`ustackd` 是无线漫游/ustack 相关服务；`/etc/config/ustack` 为 `enabled '0'`，两条命令都返回 `not find the task`，说明这是**对“已关闭状态”的幂等重放**，不是运行中切换。
- 05:05–05:06 的其余日志只有相机共享的时间窗判定和磁盘 `active/idle`，没有任何配置写入、共享变更或重载记录。
- 05:00–06:00 内**没有** `shareUpdate`、`updateconfig`、`smbcontrol`、hotplug、USB、`sdb`、`mount` 记录。
- `/tmp/log/log.smbd` 最后写入停在 03:29，05:05 无新增，说明原厂 smbd **没有重载**。
- `/var/etc/smb.conf` md5 `bcad8b90…`，与 S3/S5/S6 三次记录一致；若走 SMB 设置页保存链路，该文件会被重新生成。

### 内容判定

- 当前 UCI 末尾是一个空的 `config sambashare`（hexdump 末尾为 `...browseable 'yes'\n\nconfig sambashare\n\n`），这是 `uci add` 后未填选项再提交的典型残留。
- 7 个有效共享与 `/var/etc/smb.conf` 一一对应，名称、路径、`guest_ok`、`read_only`、`create_mask`、`preexec` 全部一致；因此本次保存**没有增删或改写共享语义**。
- 设备上唯一的旧副本 `/data/etc_bak/config/samba` 是 2017 年出厂备份（9 个共享，含 `TDDOWNLOAD`/`视频`/`音乐`，md5 `e325a8dc…`），差异是历年演进，不能当作 05:05 的 diff。
- **无法复原 05:05 前的文件**：三处副本（`/etc/config`、`/data/etc/config`、`/data/etc_bak/config`）中前两者是同一份当前文件，后者是 2017 年备份；S5 记录的 md5 `244eb53e…` 无法重建。把当前文件尾部空段裁掉得到 `a5721c18…`，仍与 `244eb53e…` 不同，说明除空段外还存在选项序列化顺序变化——这与 `uci commit` 整文件重写的特征一致，但没有原文就无法逐字段列出。

## 排除项

| 假设 | 判定 | 依据 |
| --- | --- | --- |
| SMB 设置页/共享增删 | 排除 | 无 `updateconfig`/重载；`/var/etc/smb.conf` 未变；共享语义不变 |
| OTA 预下载 | 排除 | OTA 预下载 05:49 才启动（`/tmp/ota_predownload_pid`=23309，`otapred` 05:49 提交），与 05:05 无关 |
| 设备重启恢复 | 排除 | uptime 跨过该时刻，未重启 |
| 本轮 S6 操作 | 排除 | S6 12:45 才开始；全程只读 `/etc/config`，清理核对 md5 未变 |
| 手工 shell 编辑 | 无证据支持 | 同秒存在管理栈任务；无 shell 历史/登录记录可关联；文件由 UCI 整文件重写而非行编辑 |

## 不可判定部分与边界

- **具体发起方不可判定**：`TaskMonitorServer` 不记录发起任务名；管理面 HTTP 访问日志未持久化（`/tmp/log` 中无 nginx 访问日志）；没有云指令或 App 操作日志。
- **05:05 的历史日志只有持久 syslog 一份**：`/tmp/messages` 环形缓冲已被 13:09 之后的内容覆盖，无法交叉验证。
- **无旧文件副本**，因此不能给出“改了哪些字段”的逐项 diff；只能给出“语义未变 + 机器重写”的结论。
- 同机还发现两处与本问题无直接关系的痕迹，记录备查，不作归因：`/tmp/log/log.smbd` 显示 01:16–03:29 原厂 smbd 被多次重启；`/userdisk/data/.Emby/log` 下有 02:23 的 `casemiss.txt` 测试残留。两者都早于 05:05，且没有证据表明与本次配置写入同源。

## TaskMonitorServer 的重写机制与对新版 SMB 的影响（2026-11-08 补证）

### 机制

- 监督栈是 `taskmonitorDaemon`（PID 1092）拉起 `taskmonitorServer`（PID 1090）；任务表 `/tmp/taskmonitor/taskmonitor.conf`（92 796 B，mtime 03:00）里有三条与 SMB 相关的任务：`/usr/sbin/smbd -D`（两处）、`smbd`。`taskmonitorTool` 通过 ubus 对象 `taskmonitor` 操作，`pluginTaskmonitor`（PID 8616）常驻。
- 05:05:48 的重写与 TaskMonitor 的两条停止命令同秒发生；两条命令都是 `not find the task`，属于对“已关闭服务”的幂等重放，不是运行中切换。
- 重写形态是 UCI 整文件写：`/etc/config/samba`、`/etc/config/misc`、`/etc/crontabs/root` 同秒变化，`samba` 尾部留下空的 `config sambashare`，符合 `uci commit` 整体序列化。
- **不是 Samba 设置页/共享链路**：`/var/etc/smb.conf` 的 mtime 仍是 2018-10-16，md5 `bcad8b90…` 未变；05:05 前后没有 `updateconfig`、`shareUpdate`、`smbcontrol`、hotplug、USB、mount 记录；`/tmp/log/log.smbd` 在 05:05 无新增。
- **TaskMonitor 会重启原厂 smbd**：14:47:42 原厂 smbd 被 TERM 后约 14 秒内被监督栈拉起并写入 `log.smbd`。这解释了为什么单独杀原厂 smbd 后 139/445 会被重新占用。
- **停止接口存在，但调用方式未文档化**（2026-11-08 S8 修正）：`taskmonitorTool -t stop -b smbd` 段错误（rc 139）是**缺 `-p`** 导致的参数崩溃；按 `supervisord` 的完整参数集调用可正常注销任务（rc 0），详见 [S8 共存研究](s8-taskmonitor-coexistence.md#4-合法接口)。`status` 经 ubus 确实不可用，`list`/`debug` 可用。
- **`shareUpdate -s` 会在任何一次原厂 `start` 时重写 `/etc/config/samba`**（2026-11-08 S8 补证）：`/etc/init.d/samba` 的 `start_impl` 第 181 行调用 `/usr/sbin/shareUpdate -s`，该程序链接 `libuci.so`，并通过 `uci_lookup_ptr`/`uci commit` 重写配置。15:27 执行 `vendor-start`（`/etc/init.d/samba start`）后，`/etc/config/samba` 的 **mtime 立即更新而 md5 不变**（`8556a19b…`），`/var/etc/smb.conf` 同样被重写但 md5 仍为 `bcad8b90…`；`misc` 与 `crontabs` 未变。也就是说，“samba 单文件整文件重写”有一部分是**原厂启动路径的幂等回写**，不代表共享内容变化。

### 频率与触发条件

- 持久 syslog 中同类停止对出现在 11-06 04:26、11-07 03:58、11-08 03:10、11-08 05:05，间隔分别为约 23 h 32 m、23 h 12 m、1 h 55 m，**不是定时任务**。
- `/etc/crontabs/root` 的完整内容已核对：只有 ntpsetclock、相机/场景、OTA 预下载（03/04/05 点的第 49 分）、sysapihttpd、mixbox 等条目，**没有 TaskMonitor、wrsst、ustackd 或 samba 相关行**，因此 05:05 不是 cron 触发。
- 设备 uptime 跨过 05:05 未重启，**不是开机流程**；OTA 预下载 05:49 才启动，**不是 OTA**。
- 受控对照（15:27，S8 期间）：只执行 `/etc/init.d/samba start` 会导致 `samba` **单独** mtime 刷新、md5 不变，`misc`/`crontabs` 不动。因此“单文件、内容不变”的 samba 回写可以由原厂启动路径解释；05:05 是**三文件同时**变化，仍应视为更上层的配置应用事件，而不是一次普通 start。
- 结论边界：可证明“管理栈在同一秒有动作 + 三个 UCI 文件被整文件重写 + 配置文件并非由 Samba 链路生成”，但**不能证明具体发起方是 App 保存、云端下发还是管理面自愈**：HTTP 访问日志不落盘，TaskMonitor 只记录 kill 结果，`/tmp/log` 已滚动。频率上只能确认它是“按管理事件发生、时间不规则”，不能给出固定周期。

### 对新版 SMB 的实际影响

| 面 | 结论 |
| --- | --- |
| 是否读 `/etc/config/samba` | **读**。适配器每次 `generate/start/reload` 都用 `uci -c /etc/config` 读取 `samba` 与 `misc`，渲染自己的 `smb.conf`；源被改写会在下一次生成时被带进来 |
| 共享 / include / 只读 / 相机时间窗 | 全部由该渲染链决定，**存在被带偏的风险**：新增/删除共享、改路径、改 `read_only`、改 `readonly:period` 都会在新配置中生效 |
| PID 文件 / 运行目录 / `smb.conf` 生成链 | **不受牵连**。全部在 `/userdisk/data/samba-s2/root`（版本树）内，原厂只写 `/etc/config`、`/var/etc`、`/etc/crontabs`，两边不共享路径 |
| 原厂 `smbd` 自动重启 | 对新版是**端口竞争**风险：停原厂后监督栈会尝试拉起，接管窗口必须短，且以“新版先绑定成功”为准 |
| 原厂启动造成的 mtime-only 回写 | 守卫按 `md5+size+mtime+inode` 严格比较，`shareUpdate -s` 的幂等回写也会让 `generate/check/start` 返回 7。这是**预期的 fail-closed**：内容未变时可 `S5_ACCEPT_CONFIG=1` 显式接受；切换前若刚执行过 `vendor-start`，需要先接受再切 |

### 防御（已落地并有受控复现）

适配器新增配置源守卫：

- `generate` 在渲染前计算 `/etc/config/samba` 与 `/etc/config/misc` 的 `md5 + size + mtime + inode`，与基线文件（默认 `<root>/var/state/config-baseline`，可用 `-B` 指定）比较。
- 首次运行自动采纳基线，并保留可读副本 `samba.accepted`、`misc.accepted`；基线不一致时**拒绝生成**，退出码 7，打印基线与当前值；只有显式 `S5_ACCEPT_CONFIG=1` 才更新基线并继续。
- `check` 增加 `config_baseline=`、`config_drift=yes/no`，漂移时返回 7；`reload` 传播真实退出码；安装器的厂商基线拆成“二进制 `state/vendor.md5`”与“配置 `state/vendor-config.md5`”，`verify` 对配置漂移只报告 `CONFIG-DRIFT`，由适配器守卫决定是否采纳。

受控复现（不触碰真实 `/etc/config`）：

1. 把 `/etc/config` 复制到 `/tmp/uci-test`，基线记录 `samba md5=8556… size=1795 mtime=1794085548 inode=3704417`、`misc md5=731e…`。
2. 用 `uci -c /tmp/uci-test add samba sambashare`、`set name=S7DriftTest`、`set path=/tmp`、`commit` 模拟一次整文件重写。
3. `generate` 返回 **7**，`smb.conf` md5 保持 `9122bec661189dcfe650ccc1bc92e73e` 不变；`check` 返回 7；`start` 返回 7，1445 无监听、无进程。
4. `S5_ACCEPT_CONFIG=1 generate` 返回 0，基线更新，新配置包含 `S7DriftTest`（md5 `9b4d11ae…`）。
5. 删除 `/tmp/uci-test`，对真实 `/etc/config` 重新采纳基线，`smb.conf` 回到 `9122bec…`。

结论：管理栈再次改写 `/etc/config/samba` 时，新版不会静默用被改写的源重启；必须先人工对账并显式接受。运行中的实例不会被后台改写直接换配置（生成被拒绝），只会在下次显式操作时暴露。

## 对既有文档的修正

- S6 的恢复基线 md5 `8556a19b…` 就是 05:05 之后的值，S6 未造成该差异，结论不变；D-S6-16 的“外部改动”由本文替换为可证据化描述。
- 设备端 `/tmp/log/samba.log` 会被 SSH 会话的 stderr 重定向污染（内容多为 `Broken pipe`），不能当作 smbd 日志读取；本次取证只使用持久 syslog 与 `log.smbd`。
