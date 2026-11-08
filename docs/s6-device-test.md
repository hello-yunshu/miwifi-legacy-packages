# S6 实机受控实验

日期：2026-11-08。设备：小米路由器（192.168.3.2，Linux 2.6.36 armv7l，2 核，254448 kB 内存）。本轮只在独立目录部署 4.25.1 并用非标准端口验证，**没有替换或停止原厂 4.0.21 服务**；切换与回滚留给 S7。

## 结论摘要

- 4.25.1 在 2.6.36/uClibc 上可持续运行：私有库、PAM 缺失、随机源、fcntl 锁、进程模型和 ext4 持久化均通过；`getrandom`、`renameat2`、`memfd_create`、`copy_file_range` 不存在，Samba 走回退路径，未观察到因此失败。
- 实机客户端矩阵通过：SMB1(NT1)/SMB2/SMB3、中文文件名、读写删改名、只读共享拒绝、相机时间窗拒绝；macOS 自带 SMB 栈之外的 smbprotocol 3.1.1 客户端完成签名读、写、读回。
- 吞吐受设备侧 CPU 与 100Mbps 线速约束：远端 macOS 读取 10.7–11.4 MB/s（约 91–97% 线速）；本机客户端签名 SMB2 约 20–22 MB/s、未签名 40–46 MB/s、SMB3 加密 3.7–3.8 MB/s。签名成本约 50%，加密成本约一个数量级。
- 资源有余量：新实例空闲 RSS 11.0 MB、CPU 1.3%（原厂 4.5 MB、1.3%）；4 并发峰值 RSS 73 MB，16 并发 16/16 成功，管理界面 HTTP 仍为 200 且 ping 无丢包。
- 原厂服务与配置全程未变；清理后 md5、139/445、137/138、根分区可用空间与动手前一致。

## 约束与试验边界

- 原厂二进制、`/etc/config/samba`、`/var/etc/smb.conf`、模板不写不改；不调用 `shareUpdate`、`/etc/init.d/samba`、`supervisord`。
- 新实例只监听 `192.168.3.2:1445`，PID/锁/状态/缓存/日志全部在 `/userdisk/data/samba-s6/root/var` 下。
- 停止只按 PID 文件加 `/proc/<pid>/exe` 校验；全程未用 `pidof smbd` 或进程名通配杀进程。
- 测试共享为合成目录 `/userdisk/data/s6/share/{rw,ro,cam}`，不把生产共享暴露到 1445；UCI 由 `/etc/config` 只读复制到独立目录后改为测试共享。
- MAC 策略仅在测试进程上以 `XIAOMI_MAC_FILTER=0` 关闭，用于得到确定客户端结果；默认开启时 macOS 会话被拒绝，说明 S3 策略仍在。

## 部署与程序身份

- 部署树：S3 完整安装树（含私有依赖）+ S4 `readonly.so`（md5 `83e70d25…`，30702 字节）。S4 前缀树本身缺 `libgnutls.so.30` 等依赖，不能单独打包，这一点已记录。
- 编译前缀 `/userdisk/data/samba-s2/root` 通过临时符号链接 `samba-s2 -> samba-s6` 解析；适配器用 `smbd -b` 的 `SBINDIR` 做 `readlink -f` 校验，不一致拒绝启动。
- 进程为 `sbin/samba-s6d`（真实副本而非符号链接），`readlink /proc/<pid>/exe` 指向树内；`pidof smbd` 始终只返回原厂 26994/1448。

## 内核与库兼容核查

探针为静态 ARM 小程序，直接在设备运行；结果：

| 能力 | 结果 | 说明 |
| --- | --- | --- |
| `pthread_create/join` | OK | 进程内线程可用 |
| robust mutex | 不可用 | uClibc 头文件未提供；Samba 回落 fcntl 锁，日志出现 `mutexes requested but not available` |
| `/dev/urandom` | OK | 随机源正常；`getrandom(2)` 返回 ENOSYS |
| `epoll_create/create1`、`eventfd`、`timerfd`、`signalfd`、`inotify` | OK | 事件与通知路径可用 |
| `accept4` | OK | 非阻塞空队列返回 EAGAIN |
| `posix_fallocate`、`sync_file_range2`、`posix_fadvise` | OK | 文件预分配与回写提示可用 |
| `sendfile`、`splice` | OK | 零拷贝路径可用 |
| `copy_file_range`、`memfd_create`、`renameat2` | ENOSYS | 旧内核缺失；Samba 有兼容回退 |
| `fcntl(F_SETLK)`、`flock` | OK | TDB/共享锁路径可用 |
| `futimens`、`utimensat`、`fstatvfs`、`mmap`、`msync`、`O_DIRECT`、`O_CLOEXEC` | OK | 元数据与映射路径可用 |
| `getaddrinfo`、`getifaddrs`、`clock_gettime` | OK | 网络与时钟路径可用 |

限制：`ulimit -u` 1978、`nofile` 20480、`threads-max` 3956、`pid_max` 32768；空闲熵约 173，但 `/dev/urandom` 不阻塞。

文件系统：`/userdisk` 为 ubifs（rw,noatime），`/userdisk/data` 为 ext4（rw,noatime,barrier=1,data=ordered）。

## 客户端与功能矩阵

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| SMB1 / NT1 读写删 | 通过 | 1 MiB put/list/del，rc=0 |
| SMB2 读写改名删 | 通过 | put/get/rename/del，md5 一致 |
| SMB3 读写 | 通过 | put/list/del，rc=0 |
| 中文共享/文件名 | 通过 | `测试文件.txt` put/get，md5 一致 |
| 只读共享写入 | 拒绝 | `NT_STATUS_ACCESS_DENIED` |
| 相机共享（06:00–24:00 拒绝窗） | 拒绝 | 日志 `create file failed caused by readonly timerange limit` |
| macOS smbprotocol 1.17.0 / SMB 3.1.1 / 签名 | 通过 | 64 MiB 读取、1 KiB 写读回；只读与相机共享均拒绝 |
| 进程重启后文件持久 | 通过 | 写入后 stop/start，读回 md5 一致 |
| 16 并发小文件读取 | 16/16 通过 | 峰值 RSS 51.9 MB，采样峰值连接 12 |

实机客户端进程启动本身约 4 s（`smbclient ls` 4.01 s），这是设备侧客户端初始化开销；macOS 真实客户端建连约 0.08 s，1 MiB 读取 0.41–0.61 s。

## 性能与资源对照

统一使用 64 MiB 文件；本机客户端数字取 smbclient 自身报告的纯传输速率，避免把每个进程约 4 s 的初始化算进吞吐。

| 场景 | 速率 |
| --- | --- |
| macOS 远端读取，SMB2 签名 | 10.76 / 10.67 MB/s |
| macOS 远端读取，SMB3 签名 | 11.37 MB/s |
| 本机 SMB1（未签名） | 34.1 MB/s 冷 / 53.5 MB/s 热 |
| 本机 SMB2 未签名（服务端 signing=disabled） | 40.2 / 43.3 / 45.8 MB/s |
| 本机 SMB2 签名 | 19.6 / 19.7 / 22.0 MB/s |
| 本机 SMB3 签名 | 40.1 / 46.1 MB/s |
| 本机 SMB3 加密（server+share `smb encrypt=required`） | 3.7 / 3.8 MB/s |
| 本机 SMB2 写入 64 MiB | 32.0 MB/s |
| 4 并发读取（每路 64 MiB） | 31.1 / 47.8 MB/s 聚合 |

签名 A/B 使用同一用户、同一热缓存：未签名 40.2–45.8 MB/s，签名 19.6–22.0 MB/s，签名成本约 50%。加密让单流从几十 MB/s 降到 3.7 MB/s，期间 `user` CPU 约 29.2 s / 22.5 s 墙钟，约 1.3 个核，属于 CPU 受限；不应作为默认。

资源：

| 指标 | 原厂 4.0.21 | 新实例 4.25.1 |
| --- | --- | --- |
| 空闲 CPU（20 s） | 1.3% | 1.3% |
| 空闲 RSS | 4.5 MB（smbd 1.9+1.5，nmbd 1.1） | 11.0 MB（父 4.6 + notifyd 3.2 + cleanupd 3.2） |
| 4 并发峰值 RSS | 未测 | 73.2 MB |
| 16 并发峰值 RSS | 未测 | 51.9 MB |
| 空闲 60 s 日志增长 | — | 0 字节 |
| 16 次连接日志增长 | — | 4800 字节（约 300 B/连接） |
| 管理界面 HTTP | 8–27 ms | 8–44 ms，均 200 |
| 负载时 ping | 3.2 ms 平均 | 6.2 ms 平均，最大 15.3 ms，0% 丢包 |

阈值（因原厂 SMB 吞吐基线不可得，按 100Mbps 线速与 2 核/248MB 余量制定）：远端单流读取 ≥ 8 MB/s；签名单流路由 CPU ≤ 50%；加密 ≤ 70%；空闲 RSS ≤ 32 MB；管理界面 p95 < 200 ms；根分区可用空间不得减少。本轮均满足。

### 审计复测（2026-11-08）

为确认上述数字不是只存在于文档里，审计按另一套隔离方法重取了一次：复制树 `/userdisk/data/audit-s6/root`，端口 1445，guest 认证 + `server signing = no`，设备本地 `smbclient`，128 MiB 读，跑 2 次；同时采 RSS 与 10 秒空闲 CPU jiffies。

| 指标 | 审计实测 | 与历史差异 |
| --- | --- | --- |
| 单流读取 | **29.3–31.7 MB/s**（2 次，128 MiB） | 低于历史 40–46 MB/s，方法是 guest/unsigned/回环/128 MiB，未使用热缓存对照；仍是 100 Mbps 线速的 2.6–2.8 倍，远高于 8 MB/s 阈值 |
| 空闲 RSS | **10,980 KB（约 10.7 MB）** | 与 11.0 MB 一致，低于 32 MB 阈值 |
| 空闲 CPU | **10 秒 0 jiffies** | 与 1.3% 一致 |

本次未重测签名、加密、并发与客户端矩阵；那些结论仍以本文历史记录为准。审计结论：**S6 的“吞吐达标、资源有余量”成立，但 40–46 MB/s 是特定方法下的数字，不应作为通用指标引用。**

## 失败诊断

- 4 路并发中 `kill -9` 一个连接子进程：该客户端 `NT_STATUS_CONNECTION_DISCONNECTED`，其余 3 路正常完成，父进程存活，新连接可继续 `ls`。
- 非法共享路径（相对路径）：适配器 `generate` 返回 3，`smb.conf` md5 前后一致，未覆盖 last-good。
- 相机时间窗与只读共享：访问被拒绝且日志有明确原因，不是“配置通过”冒充实测。
- 端口/陈旧 PID 路径沿用 S5：只按 PID 文件与 `/proc/<pid>/exe` 判定，未见误杀。
- 日志未出现崩溃或持续错误；仅有无害的 `null passwords` 弃用提示和 robust mutex 不可用提示。

## 恢复核对

停止与清理均按路径执行，未使用进程名通配。核对结果：

| 项 | 动手前 | 清理后 |
| --- | --- | --- |
| `/usr/sbin/samba_multicall` | `5e422d3463f40b4405ef8325ce3603e8` | 同左 |
| `/etc/config/samba` | `8556a19b6d81d49bfd5ab738e0132b51` | 同左 |
| `/var/etc/smb.conf` | `bcad8b90869688b7982a50aaa891cf99` | 同左 |
| `/etc/samba/smb.conf.template` | `95ad7d4146de73a50fb33e823d495b94` | 同左 |
| 139/445 | 192.168.3.2，PID 1448 | 同左 |
| 137/138 | 192.168.3.2/广播，PID 8469 | 同左 |
| `pidof smbd` / PID 文件 | `26994 1448` / `1448` | 同左 |
| 根分区可用 | 20588 KB | 20588 KB |
| 1445 监听/测试进程 | 无 | 无 |
| 测试目录/符号链接 | 无 | 无 |

说明：S6 开始时 `/etc/config/samba` 的 md5 已是 `8556a19b…`，与 S5 记录的 `244eb53e…` 不同；该文件 mtime 为 11-08 05:05（早于 S6 开始），期间未再变化，属于外部改动，不是本轮写入。

## BLOCKED 与遗留项

| 项 | 状态 | 原因/证据 |
| --- | --- | --- |
| 原厂 445 吞吐基线 | BLOCKED | 访客 SMB1 tree connect 返回 `NT_STATUS_ACCESS_DENIED`，MAC/凭据门控；SMB2 访客无法签名；无既有账号口令。未用近似值代替。 |
| Finder / `mount_smbfs` 非 445 | BLOCKED | `smbutil` 报 `share name doesn't exist: Socket is not connected`；`mount_smbfs` 指定端口挂起且未挂载。macOS 原生栈不支持端口后缀。 |
| 原厂撤销实机对照 | BLOCKED | 需要改原厂 MAC/共享配置，违反本轮“原厂归属不变”约束。 |
| IPv6 SMB | BLOCKED | `br-lan` 仅有 `fe80::/64` 链路本地地址，无全局 IPv6；适配器按 IPv4 绑定。 |
| SMB1 RAP 浏览 | BLOCKED | 无真实 RAP 客户端；仅验证 SMB1 文件操作与 `smbclient -L` 枚举。 |
| 真实摄像机接入 | BLOCKED | 无硬件；只验证了合成相机共享的只读模块与时间窗。 |
| 设备重启后的持久性 | BLOCKED（S6 时点） | 未重启生产设备；只验证 stop/start 进程级持久。**后续已由 S8 两次重启关闭（D-S8-16），本条保留历史状态** |
| Emby 非标准端口 | BLOCKED | 设备上未发现 Emby 进程/应用，无法验证其对非 445 端口的支持。 |
| MiniDLNA/电视通知、USB 热插拔、supervisord 停止匹配、App/管理界面集成 | 仍 BLOCKED | 与 S5 相同；S6 适配器不调用这些链路，未用近似场景替代。 |
| 跨版本 `smbcontrol` | 规避 | 沿用 S5 结论：只用新版工具配新版实例，不做跨版本调用。 |

## 复现要点

1. 设备侧备份并记录原厂 md5、PID、监听和 `df`。
2. `tar` 部署完整树到 `/userdisk/data/samba-s6/root`，建立只用于前缀解析的 `samba-s2` 符号链接。
3. `cp -a /etc/config` 到独立目录，删除复制出的共享并添加合成共享；不要写回 `/etc/config`。
4. `xiaomi-smb-adapter.sh -r … -c … -p 1445 -b 192.168.3.2 -n samba-s6d generate|start|status`。
5. 客户端验证后 `-N stop`，按精确路径删除测试目录与临时文件，重新核对 md5、监听和 `df`。
