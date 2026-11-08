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

## 对既有文档的修正

- S6 的恢复基线 md5 `8556a19b…` 就是 05:05 之后的值，S6 未造成该差异，结论不变；D-S6-16 的“外部改动”由本文替换为可证据化描述。
- 设备端 `/tmp/log/samba.log` 会被 SSH 会话的 stderr 重定向污染（内容多为 `Broken pipe`），不能当作 smbd 日志读取；本次取证只使用持久 syslog 与 `log.smbd`。
