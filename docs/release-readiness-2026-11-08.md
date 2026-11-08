# 发布就绪复核（2026-11-08，第二轮）

本文档承接 [审计报告](audit-2026-11-08.md)，记录"能关的全关"第二轮的四类工作：干净环境复建、
可发布产物、剩余可验项实测、以及必须由人提供条件才能推进的清单。所有结论均来自本轮在
Docker 构建容器 `miwifi-s1` 与实体设备（R2D / 2.25.209 / 192.168.3.2）上的实际执行。

设备最终状态：版本 `1.0.2-r2d`（`current -> versions/1.0.2-r2d/root`，`previous=1.0.1-r2d`），新版 `samba-s5d`
持有 139/445，`/etc/init.d/samba status` 正常，兼容层与发布包 MANIFEST 校验通过。

## 1. 干净环境复建（可重复构建）

### 1.1 方法

* 容器 `miwifi-s1`（`ubuntu:24.04.5`），每次构建前 `rm -rf /work/repro-work`：源码重新解压、输出目录全新。
* 脚本：[recipes/samba/repro-build.sh](../recipes/samba/repro-build.sh)，A/B 两次都用它，且都用**同一个绝对路径**
  `/work/repro-work`；`CFLAGS` 带 `-fdebug-prefix-map=/work/repro-work=/build`，消除"构建目录不同"这一非确定性来源。
* 执行方式：

  ```sh
  docker exec -d miwifi-s1 bash -lc \
    'bash /work/repro-build.sh A > /work/repro-run-A.out 2>&1; \
     bash /work/repro-build.sh B > /work/repro-run-B.out 2>&1'
  ```

* 每一步的返回码写入 `logs/REPORT.txt`；脚本末尾检查 `_RC=[1-9]`，任一阶段失败即以非 0 退出（本轮收口，
  此前版本会"失败也返回 0"）。

### 1.2 工具链与依赖

| 项 | 版本 / 参数 |
| --- | --- |
| 构建宿主 | Ubuntu 24.04.5 LTS，kernel `7.2.12-orbstack` |
| 交叉工具链 | `arm-xiaomi-linux-uclibcgnueabi-gcc` 4.8.2（crosstool-NG 1.19.0），uClibc，soft-float |
| 代码生成执行器 | `qemu-arm version 8.2.2`（`/work/repro-work/run-arm.sh`，`-L /toolchain/sysroot`） |
| 依赖 | zlib 1.4、gmp 6.3.0、nettle 3.10.2、GnuTLS 3.8.13（+`gnutls-sdk-thread-local.patch`） |
| 主程序 | Samba 4.25.1 + 7 个补丁：cross-asn1-rule、cross-codegen-executor、sdk-generic-selection、sdk-reflink-guard、sdk-spawn、s3-mac-policy、s4-readonly-timewindow |
| 关键配置 | `--prefix=/userdisk/data/samba-s2/root --libdir=.../lib --cross-compile --cross-execute=<run-arm.sh> --bundled-libraries=ALL --disable-python --without-ad-dc/ads/ldap/pam/winbind ...`（完整参数见脚本） |
| 环境 | `SAMBA_CODEGEN_EXECUTOR=<run-arm.sh>`、`PYTHONHASHSEED=1`、`WAF_MAKE=1` |
| 已知前置 | GnuTLS 在 GCC 4.8 + uClibc 下必须先 `make -C gl` 生成 gnulib `assert.h`（提供 `static_assert`），否则 `make -C lib` 失败 |
| 依赖检测 | nettle/GnuTLS 必须显式 `CPPFLAGS/LDFLAGS/PKG_CONFIG_*` 指向 `$PREFIX/opt/samba-next`，否则 gmp 不被链接（`NETTLE_MINI_GMP=yes`、hogweed 缺失） |

### 1.3 耗时（B 构建，`ELAPSED_SEC=1077`；A 为 1049 s）

| 阶段 | 完成时刻 (UTC) | 约耗时 |
| --- | --- | --- |
| zlib configure/build/install | 10:01:15 | 9 s |
| gmp configure/build/install | 10:03:30 | 2 min 24 s |
| nettle configure/build/install | 10:04:12 | 42 s |
| GnuTLS configure + patch | 10:08:14 | 4 min 02 s |
| GnuTLS gl + build + install | 10:09:12 | 58 s |
| Samba 7 补丁 | 10:09:13 | 1 s |
| Samba configure | 10:12:49 | 3 min 36 s |
| Samba build（3457 个目标） | 10:17:23 | 4 min 34 s |
| Samba install (DESTDIR) | 10:19:03 | 1 min 40 s |

### 1.4 哈希比对（A / B 两次独立构建 + 设备）

| 产物 | A | B | 设备现行值 |
| --- | --- | --- | --- |
| `sbin/smbd` | `52e105576e190ab6b977be419b3144fe` | 同 A | `52e105576e190ab6b977be419b3144fe` |
| `bin/smbclient` | `f2f13af1e70c2cbae70db221a4fdb3a3` | 同 A | 随包一致（树内） |
| `lib/private/libsmbd-base-private-samba.so` | `8cb07989b7dc02660a27f3ecd3f7ad90` | 同 A | 随包一致（树内） |
| `libgnutls.so.30.42.0` | `9b80b5c4cd1d1ccdec93078230dae415` | 同 A | 随包一致（树内） |
| `libnettle.so.8.11` | `675b9f09c49568c306e278aaa62d85bc` | 同 A | 随包一致（树内） |
| `libgmp.so.10.5.0` | `d3f566d9a2471d39dd319fa6a50baad2` | 同 A | 随包一致（树内） |
| `sbin/nmbd`（脚本未列，手工核对） | — | `2283bda9f01dfa719ad276af28b655a0` | `2283bda9f01dfa719ad276af28b655a0` |

结论：同一份源码两次构建（A/B）主程序与关键库哈希**完全一致**，且 `smbd`/`nmbd` 与设备现行版本一致，
可重复构建成立。发布包的 payload 直接取自 B 构建的 `DESTDIR` 输出（另补 4 个外部依赖库，见 §5.1）。

### 1.5 本轮修正的构建脚本问题

* 第一次 A/B：nettle 未链接 gmp（`hogweed` 缺失）→ 显式传入 `CPPFLAGS/LDFLAGS/PKG_CONFIG_*`。
* 第二次 A/B：GnuTLS `static_assert` 编译失败 → 构建 `lib` 前先 `make -C gl`。
* 两次构建路径不同导致 nettle 哈希不一致 → 固定 `/work/repro-work` + `-fdebug-prefix-map`。
* `SAMBA_PATCH_RC` 取到的是循环末尾 `echo` 的返回码，永远为 0 → 改为累计真实 `patch` 返回码，并在任一步失败时退出。

## 2. 剩余可验项实测

### 2.1 IPv6

| 项 | 实测 |
| --- | --- |
| 设备 IPv6 地址 | 仅 `br-lan` link-local `fe80::f2b4:29ff:fe2b:8041/64`；无全局地址 |
| 生产监听 | `/proc/net/tcp6` 无 139/445；`netstat` 只有 `192.168.3.2:139/445` |
| 生产配置 | `interfaces = 192.168.3.2`、`bind interfaces only = yes` |
| 新版二进制 IPv6 能力 | 测试实例 `interfaces = ::1`、`smb ports = 1445`：`/proc/net/tcp6` 出现 1445 监听；`smbclient -p 1445 -L ::1 -N` 成功列出共享（rc=0） |

结论：新版 Samba 的 IPv6 栈可用，生产未启用是**配置与网络条件**（只绑定 IPv4 地址、设备无全局 IPv6），
不是二进制缺陷。测试实例已清理，1445 已释放。

### 2.2 SMB1 / RAP

| 场景 | 结果 |
| --- | --- |
| `smbclient -m NT1`（仅指定最大协议） | 失败：`Max protocol NT1 is less than min protocol SMB2_02`（4.25 客户端默认最小 SMB2_02） |
| `smbclient -m NT1 --option='client min protocol=NT1' -L 192.168.3.2 -N` | 成功：列出 `下载/共享/图片/摄像机监控视频$/文档/IPC$/nobody`，并输出 `Reconnecting with SMB1 for workgroup listing.`（RAP 工作组列举） |
| SMB1 共享级访问 `//192.168.3.2/下载 -c dir` | 成功返回目录列表（文件时间 2026-05/06） |

结论：服务端 `server min protocol = NT1` 生效，SMB1 与 RAP 工作组列举**在本机实测可用**；
需要客户端显式放宽 `client min protocol`，这是 Samba 4.25 客户端默认值所致，不是服务端问题。

### 2.3 MiniDLNA 联动

| 步骤 | 结果 |
| --- | --- |
| `/etc/config/minidlna` | `enabled=1`；`enabled=2`（App 授权状态） |
| `/etc/init.d/minidlna start_impl` | rc=0；`shareUpdate -m` 输出 `2`；随后 `supervisord start` 拉起 `/usr/bin/minidlna -f /tmp/minidlna.conf` |
| 进程/端口 | pid 1581，`0.0.0.0:8200` LISTEN |
| 生成配置 | `/tmp/minidlna.conf` 含 5 个 `media_dir`：下载、共享、图片、摄像机监控视频、文档 |
| 对 Samba 的影响 | `shareUpdate -m` 前后 `smb.conf` md5 不变、`samba-s5d` pid 不变（7071），139/445 不受影响 |
| `stop` | rc=0；minidlna 退出、8200 关闭、Samba 保持 7071 |

结论：MiniDLNA 的启动链（shareUpdate → 配置生成 → supervisord 拉起）与新版 Samba **共存，不触发配置漂移或重启**。
观察到的 `shareUpdate -m` 输出 `2` 记录在此，未作为错误处理。

### 2.4 时钟跨窗口

用独立测试实例（1445 端口、`vfs objects = readonly`、绝对时间窗）在**同一条 SMB 连接**内做三次
`put`，窗口由真实时间自然跨越：

| 阶段 | 服务端判定 | 结果 |
| --- | --- | --- |
| 窗口开始前 | `check_if_time_in_range ... [false]`（不在窗口） | 允许 |
| 窗口内（+22s） | `[true]` | 拒绝 |
| 窗口结束后（+52s） | `[false]` | 允许 |

结论：`readonly` 判定在**每次 create_file 时重新读取时间**，不在连接建立时缓存；时钟前进跨窗口行为正确。
**没有**修改设备系统时钟来制造跳变：跳变与时间自然前进走同一条 `time(NULL)` 读取路径，而改系统时钟会
影响 cron/日志/名称解析等共享状态，风险不成比例。生产相机共享（`today 06:00` → `tomorrow 02:00`）
在测试时刻（17:16，窗口内）实测返回 `NT_STATUS_ACCESS_DENIED`，与逻辑一致。

### 2.5 开机 6→7 共享瞬态

方法：临时 `S05bootsample` 在开机时每秒采样（uptime、139/445 监听 PID、新版/原厂进程、数据盘挂载），
同时从 Mac 每秒探测 445/139/22 端口。采样脚本与日志已删除。

| 时刻 | 观察 |
| --- | --- |
| 客户端 | 17:22:29 重启；445/139 关闭；17:23:31 恢复（总不可用约 62 秒，含引导与内核） |
| uptime 18.29s | `/userdisk/data` 已挂载；139/445 无监听 |
| uptime 41.29s | 首次出现监听：`192.168.3.2:139/445`，持有者 pid 7910（`samba-s5d`，新版） |
| uptime 44.06s | 原厂 `nmbd`（pid 8910，exe `samba_multicall`）启动，监听 UDP 137/138 |
| 18s–240s 全部采样 | **没有任何原厂 smbd 持有 139/445**；新版从 41.29s 起持续持有 |

结论：开机瞬态是"引导期间正常无共享（0–41s）→ 新版接管"，不是"原厂先占、再切新版"的抖动。
原厂 `nmbd` 仍负责 NetBIOS 名称服务（137/138 UDP），与既有决策一致，不影响 139/445 归属。

第二次开机另做**共享数维度**采样（每 2s 记录可见 Disk 共享与 `smb.conf` md5）。当时把 `XiaoMi-usb0`
判为“无 USB 时不存在、需真实盘才能复现”，**该前提是错的**：设备一直插着一块 WD Elements 1 TB
（`/dev/sdb1`），本轮只读排查确认它始终挂载在 `/extdisks/sdb1`（详见 §2.7）。

| 时刻 | 观察 |
| --- | --- |
| uptime 42.70s → 156.61s | 设备自连可见共享稳定 6 个：`下载, 共享, 图片, 摄像机监控视频$, 文档, nobody`；`XiaoMi`/`XiaoMi-usb0` 为 `browseable=no`，按 MAC 策略对未列名客户端不参与枚举 |
| uptime 33.59s | `smb.conf` 从 `f94e2f5c…` 变为 `8038cbb7…`（缺 `[XiaoMi-usb0]` 段），58.89s 又回到 `f94e2f5c…` |

结论：33.59s 的“缺段”不是盘不存在，而是**服务启动早于磁盘挂载与 UCI 段生成**——dmesg 显示 sdb 在
10.5s 被识别，但 tntfs 到 **49.3s** 才挂载；samba（S96）在挂载前启动，UCI 里还没有 `XiaoMi-usb0`
段，适配器按段渲染出 6 个；49.3s 挂载后原厂 hotplug 调 `shareUpdate -a` 写入该段并 reload，58.89s 的
`smb.conf` 恢复 7 段。**这是启动时序，不是“需要真实 USB 盘才能复现”。**

补充（发布包安装/升级后观察到）：有两次在 `start` 刚完成、紧接着执行的第一次 `smbclient -L` 返回空列表
（只有表头与 `SMB1 disabled`），随后重试立即恢复 6 个共享。受控测量（stop→start 后每秒列举一次）为
`t=0s…14s` 均稳定 6 个共享，未能复现。结论：两次空列表是客户端 `-L` 的瞬态，不是共享配置缺失；
服务端 `smb.conf` 在两次空列表时都包含全部 6 个共享段，139/445 也由 `samba-s5d` 正常持有。

### 2.6 pidfile 偶发丢失根因

代码与实测（Samba 4.25.1 `lib/util/pidfile.c`、`source3/smbd/server_exit.c`）：

- `pidfile_unlink()` 是**无条件 unlink**；只有父进程、且 `SERVER_EXIT_NORMAL`（正常退出）才调用。
- `SIGKILL`、panic 等路径不会删除 pidfile，留下"陈旧 pid 文件"（内容指向已死 PID）。
- 实测（生产实例，SIGTERM 23809 → TaskMonitor 自愈）：
  - 17:14:08 收到 SIGTERM，pidfile 立即 MISSING，445 关闭；
  - 17:14:12.4（约 4.2s）TaskMonitor 拉起新实例 pid 4008 并写入 pidfile；
  - 17:14:14（再约 2s）445 恢复监听。
- 症状确认：把运行中实例的 pidfile 临时移走（进程与端口都正常）后执行 `samba status`，返回
  **rc=5 "port in use by another process"**——pidfile 缺失时状态会被误读为端口被他人占用。

本轮修复（`recipes/samba/xiaomi-smb-adapter.sh`）：新增 `remove_pidfile_if <pid>`，只在该 pidfile
仍然记录"刚处理的这个 pid"时才删除，避免 stop/start 与 TaskMonitor 自愈并发时删掉新实例刚写入的 pidfile。
部署后 `stop`→`start` 实机回归 rc=0，服务 pid 323 持有 139/445，MANIFEST 校验通过。

结论：正常退出删 pidfile、异常退出留陈旧 pidfile，都是 Samba 既有语义；"丢失"的真实风险点在适配器
无条件 `rm -f`，本轮已收敛为条件删除。

### 2.7 `XiaoMi-usb0` 只读排查与结论（2026-11-08 21:40）

口径更正：设备**一直插着一块 WD Elements 1 TB 移动硬盘**，`/dev/sdb1` 持续挂载在 `/extdisks/sdb1`。
本文档与 `decisions.md` 之前把它记为“无 USB / 第 7 个共享需真实盘（BLOCKED）”，前提错误，以本节为准。
本轮**未拔插盘、未改配置、未重启服务**，全部为只读命令。

#### 2.7.1 盘是否挂上（问题 1）

| 检查 | 结果 |
| --- | --- |
| `/proc/mounts` | `/dev/sdb1 /extdisks/sdb1 tntfs rw,uid=0,gid=0,umask=00,nls=utf8 ...` |
| `df` | 931.5 GB，约 43% 已用，与盘内文件一致 |
| `/proc/partitions`、`/sys/block` | `sdb`、`sdb1` 存在 |
| dmesg | 10.5s 识别 `WD Elements 25A2`，10.7s 出现 `sdb1`，**49.3s** tntfs 挂载成功，卷标 `备份盘` |
| 挂载点权限 | `drwxrwxrwx root:root /extdisks/sdb1` |

结论：盘已挂载，内核识别与文件系统挂载都正常。

#### 2.7.2 UCI 与两份 smb.conf（问题 2、4）

`/etc/config/samba` 中确实存在该段：

```
config 'sambashare'
        option 'name'        'XiaoMi-usb0'
        option 'path'        '/extdisks/sdb1'
        option 'guest_ok'    'yes'
        option 'force_user'  'root'
        option 'browseable'  'no'
        option 'read_only'   'no'
        option 'create_mask' '0777'
        option 'dir_mask'    '0777'
```

对照：

| 文件 | 是否含 `[XiaoMi-usb0]` | 行号 | 关键字段 |
| --- | --- | --- | --- |
| 原厂 `/var/etc/smb.conf`（2377 B） | 有 | 62 | `path = /extdisks/sdb1`、`browseable = no` |
| 新版 `/userdisk/data/s7root/current/etc/smb.conf`（2494 B） | 有 | 55 | 同上 |

结论：新旧两份配置都渲染了该共享，字段一致；**不存在“新版漏渲染”**。

#### 2.7.3 新版为什么曾经没有它（问题 3）

代码位置（[xiaomi-smb-adapter.sh](../recipes/samba/xiaomi-smb-adapter.sh)）：

- `share_sections()`（第 87–90 行）只从 UCI 枚举 `samba.*=sambashare`；
- `render()`（第 297–365 行）对每个 section 无条件输出，只校验名称字符、重复、绝对路径与 `..`，
  **没有按挂载状态或路径存在性过滤**；
- `cmd_generate()`（第 380 行起）调用 `render()`；`cmd_reload()`（第 620 行起）重新 `generate` 后
  `smbcontrol reload-config`。

判定：33.59s 缺段的唯一原因是**当时 UCI 里还没有这个 section**（盘尚未挂载，见 2.7.1 的 49.3s），
不是“有段被过滤/条件跳过”。该段由原厂挂载链路动态生成：

- `/etc/hotplug.d/block/40-mount` 在挂载时执行 `mkdir -p /extdisks/$device` 与 `mount /dev/$device /extdisks/$device`；
- `/etc/hotplug.d/block/80-sambaAndDlna` 在 `add` 时执行 `/usr/sbin/shareUpdate -a`，`remove` 时执行 `shareUpdate -r $mountpoint`；
- `/usr/sbin/shareUpdate` 的符号/字符串包含 `initUSBShareFolders`、`sGetSambaShareName`（前缀 `XiaoMi-usb`）、
  `generateSambashareConfig`、`sReloadSamba`（`/etc/init.d/samba reload`）、`config 'sambashare'`、`/extdisks/`；
- `/etc/init.d/samba`（S8 wrapper）与 `samba.vendor` 的 `start_impl` 都先调 `/usr/sbin/shareUpdate -s`。

因此归类为：**“UCI 里没段（启动早期）、依赖原厂 `shareUpdate`/hotplug 动态生成”**，
不是“有段但适配器漏渲染”。

#### 2.7.4 客户端可见性与访问（补充对照）

- 从 Mac（`192.168.3.176`，MAC `5c:9b:a6:95:d0:07` 在 `nonLoginMac.cfg` 列表中）执行
  `smbutil view -N //guest@192.168.3.2`，枚举到 `homes`、`XiaoMi`、`XiaoMi-usb0`；
- `mount_smbfs -N -o rdonly //guest@192.168.3.2/XiaoMi-usb0 /tmp/usb0mnt` 成功，`ls` 可读盘内文件，
  `df` 显示 931 GiB / 43%；
- 设备自连 `192.168.3.2` 访问 `XiaoMi-usb0` 返回 `NT_STATUS_ACCESS_DENIED`，日志为
  `share_sanity_checks: xiaomi mac policy denied connection from 192.168.3.2 to share XiaoMi-usb0`。
  源 IP 是路由器自己，不在任何 MAC 列表，按 XOR 策略只允许 `browseable=yes` 的共享，属预期。

结论：`XiaoMi-usb0` 并非不可用；对“列表命中”的设备可见且可读，对未命中设备按原厂同源 MAC 策略隐藏/拒绝。
`browseable = no` 与原厂 `/var/etc/smb.conf` 完全一致，不是新版回归。

#### 2.7.5 适配缺口与修复（已完成）

修复前风险：适配器只渲染 UCI 中已存在的 section，依赖原厂 `shareUpdate`（`-s` 启动同步、`-a/-r`
hotplug 增删）创建/删除 `XiaoMi-usb0`。`shareUpdate` 不可用、被 App 禁用或 hotplug handler 缺失时，
即使盘已挂载共享也不会出现；启动窗口内还会少共享（本轮 49.3s 挂载 vs 33.59s 启动）。

**实现（2026-11-08 21:50）**

- [xiaomi-smb-adapter.sh](../recipes/samba/xiaomi-smb-adapter.sh)：
  - 顶部新增 `MOUNTS_FILE=${S8_MOUNTS_FILE:-/proc/mounts}` 与
    `EXTDISK_ROOT=${S8_EXTDISK_ROOT:-/extdisks}`（测试注入点）。
  - [render()](../recipes/samba/xiaomi-smb-adapter.sh#L220-L427) 在 UCI section 之后增加挂载派生层
    （[第 374–426 行](../recipes/samba/xiaomi-smb-adapter.sh#L374-L426)）：从 mount 表取 `/dev/*` +
    `/extdisks/<dev>` 并按挂载点排序；跳过非 `/dev`、非 `/extdisks`、嵌套 `/extdisks/<dev>/*`、
    mountpoint 不存在（卸载残留）；UCI 已有同路径 section 时跳过（尾斜杠归一）；名称从 `XiaoMi-usb0`
    起取第一个未占用名；字段与 UCI 版一致；只写生成的 `smb.conf`，**不回写 UCI**。
- [90-s8-mounts](../recipes/samba/s8-compat/90-s8-mounts)（新增，519 B，md5 `051ba4ad320bf6b89d1d90d664061fbd`）：
  `ACTION=add|remove` 时调 `current/hook.sh reload`；安装到 `/etc/hotplug.d/block/90-s8-mounts`，
  不再单靠原厂 `shareUpdate` 触达适配器。
- [install.sh](../recipes/samba/s8-compat/install.sh)：安装/校验 hotplug 脚本并记录 `hotplug.md5`；
  [install-release.sh](../recipes/samba/install-release.sh) 的 `uninstall` 删除该入口。
- [test-mount-shares.sh](../recipes/samba/tests/test-mount-shares.sh)（新增）：提取真实 `render()`，
  用 `S8_MOUNTS_FILE` + `S8_EXTDISK_ROOT` 驱动。

**离线回归**：14 个用例 / 31 条断言，0 失败；本机（macOS sh）与设备 busybox 各跑一遍，均
`cases=14 assertions=31 failures=0`。覆盖：单盘合成、UCI 优先不重复、无挂载不出段、多盘稳定
usb0/usb1、UCI 占名后取下一个、非 `/extdisks` 忽略、卸载残留（目录不存在）忽略、嵌套挂载忽略、
tmpfs 忽略、mount 表缺失、UCI 路径尾斜杠、幂等、UCI 名冲突、注释/空行。

**设备验证（当前盘，未动 UCI）**

| 项 | 结果 |
| --- | --- |
| 部署前 | UCI md5 `244eb53e5019b95a408aebe49602561a`；adapter `28a812c50e7d15f3fbe865b375a51e39`；共享 9 段含 `[XiaoMi-usb0]` |
| 部署后 | adapter `f106c788052402fc4fb7dc2614543fd3`（26 800 B）；hotplug `051ba4ad…`；UCI md5 仍为 `244eb53e…` |
| hotplug 入口 | `ACTION=add DEVICE=sdb1 /etc/hotplug.d/block/90-s8-mounts` → rc 0 |
| 服务 | `adapter status` → `running pid=24224 port=139 445`；`/etc/init.d/samba status` rc 0；139/445 仍由 `samba-s5d` 持有 |
| 共享列表 | 与部署前一致（9 段，`[XiaoMi-usb0]` 仅 1 处）；字段 `path=/extdisks/sdb1`、`read only=no`、`guest ok=yes`、`create/directory mask=0777`、`browseable=no`、`force user=root` |
| 设备 live 模式 | 真实 `/proc/mounts` + 空 UCI fixture：`cases=1 assertions=5 failures=0`，合成 `[XiaoMi-usb0] path=/extdisks/sdb1`，证明不再依赖 UCI 段 |
| 安装校验 | `s8compat/stage/install.sh verify` rc 0（MANIFEST 三项 + hotplug 校验通过） |

**真实热插拔：已通过**（2026-11-08 22:43–22:49；测试条件：单 USB 口设备 + SanDisk Extreme Pro 128 G，Ventoy 双分区 `sdb1` exFAT / `sdb2` VTOYEFI；采集脚本 1 秒/条，`PPID=1`）。

| 阶段 | 判定 | 证据 |
| --- | --- | --- |
| 插入 | 通过 | `/extdisks/sdb1` 挂载 → `[XiaoMi-usb0]` **5 s**；`/extdisks/sdb2` 挂载 → `[XiaoMi-usb1]` **5 s**（阈值 ≤15 s）；最终 10 段 |
| 拔出 | 通过 | `usb 1-2: USB disconnect`（22:46:27.4）→ 两个共享全消失（22:46:37）**9.6 s**（≤15 s）；回到 8 段，无悬空路径/重复段 |
| 重插 | 通过 | 首次挂载（22:48:51）→ 两个共享齐全（22:49:05）**14 s**（≤20 s）；从物理插入起 **18 s** |
| 服务 | 通过 | `samba-s5d` **pid 8906** 跨插入/拔出/重插三次事件未换进程，139/445 全程由其监听 |
| 采样 | 通过 | 每阶段 ≥19 条连续无抖动；UCI 轨迹 `1b1c63cb…` ↔ `244eb53e…` ↔ `17ac14f5…`，与首次插入一致 |
| 生效者 | 已定位 | 六次 hotplug 事件（3 add / 3 remove）均由 `90-s8-mounts` 记录 `reload_rc=0`，但原厂 `shareUpdate` 先写 UCI；挂载派生层在真机是**兜底能力**，本轮未由它生效 |

注：拔出时共享消失晚于内核断开，主因是原厂 `samba reload` 耗时（22:46:33 开始、22:46:35 完成）；重插时物理插入→共享齐全的 18 s 中，额外部分是第二分区枚举与挂载串行，不是渲染慢。已有挂载识别缺陷已修，不再是 BLOCKED。

## 3. 发布前必须由人提供条件

| 项 | 缺什么条件 | 当前能做到的程度 |
| --- | --- | --- |
| OTA / 恢复出厂 | 小米 ROM 的 OTA 签名私钥、固件打包与分区写入流程 | 只能手工 SSH 安装；无法产出可被原厂 OTA 接受的固件 |
| 真实 App 与云端 | 米家 App 账号、云端接口权限、可回滚的测试设备 | 只做了入口级验证（脚本模拟 init 调用），未跑真实 App |
| 真实摄像机 | 实际 IPC 设备与 RTSP/存储写入场景 | 只验证了相机共享路径与只读时间窗逻辑 |
| Emby | Emby 服务端与媒体库（授权/账号） | 未安装、未联调 |
| 生产盘热插拔 | — | 已用独立 SanDisk 128 G 测试盘完成插入/拔出/重插三阶段实测（§2.7），已通过 |
| 原厂 445 性能基线 | 原厂固件下的对照环境（需回退整机） | 只有新版自身吞吐数据（29.3–31.7 MB/s 等） |
| 签名密钥 | 发布签名私钥/证书与分发渠道 | **发布前置条件**：当前产物无签名，只能作为内部/实验包 |
| 独立测试硬件 | 第二台 R2D 或可反复刷机的设备 | 所有测试都在唯一在网设备上做，需边测边恢复 |

## 4. 本轮改动的设备回归

| 项 | 结果 |
| --- | --- |
| 适配器部署 | `/userdisk/data/s7root/xiaomi-smb-adapter.sh` 与 `s8compat/versions/v1/` 同步，md5 `f106c788052402fc4fb7dc2614543fd3` |
| wrapper 部署 | `/etc/init.d/samba`、`versions/v1/`、`stage/` 三处同步，md5 `03e596af3763e1164b5426cfe56fa25d` |
| hotplug 部署 | `/etc/hotplug.d/block/90-s8-mounts`，md5 `051ba4ad320bf6b89d1d90d664061fbd` |
| MANIFEST | 重新生成（hook `19fa4ad3…`、adapter `f106c788…`、wrapper `03e596af…`），`install.sh verify` 三项 OK + hotplug 校验 OK |
| `install.sh install`（幂等） | rc=0，`samba-s2/root` 前缀链接重建并校验 |
| 服务 | `stop`/`start` rc=0；审计轮 pid 7071，发布包安装后的最终 pid 见 §5.3、§6 |

### 4.1 回滚到原厂并恢复新版（实机执行）

顺序（**顺序很重要**）：

1. `samba stop`（新版，rc=0，端口释放）；
2. 隐藏 `s8compat/current`（指向 `versions/v1` 的符号链接改名）；
3. `samba start` → wrapper 找不到 hook，`exec` 原厂脚本：原厂 `smbd`（pid 6141）接管 139/445，rc=0；
4. 恢复 `s8compat/current`；
5. `samba stop` → 新版适配器无法杀外来 PID，返回 **rc=5**（修复后不再假成功），原厂仍在监听；
6. 再次隐藏 hook 并 `samba stop` → 原厂 stop 返回 rc=1，但端口实际释放（原厂脚本语义）；
7. 恢复 hook，`samba start` → 新版 pid 7071 持有 139/445，`status` rc=0；
8. 复查进程：只有 `samba-s5d`，无原厂 `samba_multicall` 残留。

发现并修复的真实缺陷：wrapper 的 `stop()` 原为 `s8compat stop || true; return 0`，会把"端口仍被
外来进程占用"的失败吞掉并返回成功。现改为 `rc=0; s8compat stop || rc=$?; ...; return $rc`，
上面第 5 步实测返回 5。

结论：原厂兜底路径可用；回滚/卸载必须先停原厂、再恢复 hook，否则会把原厂实例留在 139/445 上。

## 5. 可发布产物（发布包）

### 5.1 包结构

产物：`miwifi-smb-1.0.3-r2d.tar.gz`（14 299 319 B，工作区根目录），解包后：

```
miwifi-smb-1.0.3-r2d/
  VERSION                         # 1.0.3-r2d（= 版本目录名）
  README-INSTALL.txt              # 安装/升级/回滚/卸载/兜底说明
  install-release.sh              # 总装入口 verify|install|upgrade|rollback|uninstall|status
  xiaomi-smb-install.sh           # 版本树安装器（install/activate/rollback/uninstall/verify）
  MANIFEST.md5                    # 设备端 md5sum 可校验
  SHA256SUMS                      # 分发端校验（设备无 sha256sum）
  payload/samba-tree.tar.gz       # 干净构建的 DESTDIR 运行树 + 4 个外部依赖库
  compat/hook.sh                  # 19fa4ad3…（2143 B）
  compat/xiaomi-smb-adapter.sh    # f106c788…（26800 B，含挂载派生层）
  compat/samba.init.wrapper       # 03e596af…（2145 B）
  compat/install.sh               # b5d4e004…（5544 B，装 hotplug + 校验）
  compat/90-s8-mounts             # 861b98d8…（含 hotplug.log 文件日志）
```

| 文件 | MD5 | SHA-256（顶层 tar） |
| --- | --- | --- |
| 包 tar（1.0.3-r2d，**当前有效，已实机安装**） | `f305a1b94637afc8b4a9cd9b359d6c32` | `bbb6ff924c799f0b419d46e4e24e593deb2fd5a746c194f7c31c2dfa75131848` |
| 包 tar（1.0.2-r2d，**已作废/被 1.0.3-r2d 取代**） | `bc10176f3d66aa9a412a4882f94f57e4` | `07d5eb5083bf3817e177b9135b0dfe32ddbeae6ed5014326cfeec593a5f037d3` |
| 包 tar（1.0.1-r2d，**已作废/被取代**） | — | `cf4491148c47964619509a01865f25c0c8a1f5549c20181caf732d46ee8085ff` |
| 包 tar（1.0.0-r2d，**已作废/被取代**） | — | `ce4684b20472191da1debe647fe18f39b69ce78f578b31556affa61b5151fe9b` |
| `payload/samba-tree.tar.gz` | `0f6001010c84a016cd46f129dbe47388` | 见包内 SHA256SUMS |

> 版本号说明：1.0.2-r2d 发布后 `compat/90-s8-mounts` 因 `logger` 不落 `/tmp/messages` 改为追加
> `/userdisk/data/s8compat/logs/hotplug.log`，包字节再次变化（`051ba4ad…`→`861b98d8…`）。同一版本号不同字节
> 会让回滚辨识、缓存命中与证据引用产生歧义，因此递增为 `1.0.3-r2d`；1.0.2-r2d 及更早版本的哈希自此仅作历史记录。
> 包内 `MANIFEST.md5` 10 项、`SHA256SUMS` 11 项（含 `MANIFEST.md5`）在主机侧 `md5sum -c` / `shasum -a 256 -c` 全部 OK。

payload 说明：`make install DESTDIR` 输出（含 `sbin/smbd` 与设备一致的 `52e10557…`），剔除
`var/` 运行时内容与生成的 `etc/smb.conf*`，并补入 GnuTLS/nettle/hogweed/gmp 4 个库（它们是外部依赖，
不随 Samba install 落盘）。`sbin/samba-s5d` 不随包，由适配器首次 `start` 时从 `smbd` 复制生成。

### 5.2 校验与签名

* 设备：`./install-release.sh verify` → `MANIFEST.md5` 全部 OK（实测）。
* 主机/分发：`SHA256SUMS`。
* **签名：无。** 仓库没有发布签名密钥，当前包只能算内部/实验包；"具备签名"是发布前置条件（见 §3）。

### 5.3 实机安装（已执行）

上表为 1.0.0-r2d / 1.0.1-r2d 的历史记录；1.0.2-r2d 的实机链路见 §5.3.1；1.0.3-r2d 已构建并**已安装到实体机**（见 §5.3.2）。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 校验 | `./install-release.sh verify` | 9 个文件 MD5 全 OK |
| 安装 | `./install-release.sh install` | 安装 `1.0.0-r2d`：树、`current`、`samba-s2/root` 前缀链接、兼容层；`samba-s5d` 持有 139/445 |
| 幂等重装 | 同上 | 树已存在且 payload md5 相同 → 跳过复制；服务重启成功 |
| 升级 | `./install-release.sh upgrade`（`1.0.1-r2d` 包） | `current -> versions/1.0.1-r2d/root`，`previous=1.0.0-r2d`，服务 pid 变更、共享 6 个 |
| 回滚 | `./install-release.sh rollback` | `current -> versions/1.0.0-r2d/root`，`previous=1.0.1-r2d`，前缀链接同步，服务正常 |
| 卸载 | `./install-release.sh uninstall` | `/etc/init.d/samba` 恢复原厂（`a26f32ce…`），`samba.vendor` 删除，版本树/链接删除，原厂 `smbd` 接管 139/445 |
| 安装恢复 | 再执行 `install`（`1.0.1-r2d`） | 当时设备状态：`current -> versions/1.0.1-r2d/root`、`previous=v1`、新版持有 139/445 |

### 5.3.1 1.0.1-r2d → 1.0.2-r2d 版本迭代（本次实测）

设备起始态：`current -> versions/1.0.1-r2d/root`，`previous=v1`，`samba-s5d` pid 24224，UCI md5 `244eb53e…`。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 校验 | `cd /userdisk/data/release/miwifi-smb-1.0.2-r2d && sh install-release.sh verify` | `version=1.0.2-r2d`，payload md5 `0f600101…`，10 项 MD5 全 OK，rc=0 |
| 升级 | `sh install-release.sh upgrade` | 新树 `versions/1.0.2-r2d/root`；`current -> versions/1.0.2-r2d/root`；`previous=1.0.1-r2d`；前缀链接同步；pid 14733 持 139/445 |
| 回滚 | `sh install-release.sh rollback` | `current -> versions/1.0.1-r2d/root`；`previous=1.0.2-r2d`；前缀链接同步；pid 15521 持 139/445 |
| 重装 | `sh install-release.sh install` | `already-installed 1.0.2-r2d`（同 payload md5 幂等）；重新激活 1.0.2-r2d；`previous=1.0.1-r2d`；pid 16260 持 139/445 |
| 最终校验 | `install-release.sh verify` / `compat/install.sh verify` | 均为 rc=0；`/etc/init.d/samba status` rc=0 |

兼容性结论（旧 `1.0.1-r2d` 就地升级）：

* **配置**：`/etc/config/samba` md5 全程 `244eb53e5019b95a408aebe49602561a`，未改动。
* **UCI 共享段**：未清空、未重写；`[XiaoMi-usb0]` 仍只由渲染层生成 1 处，字段与原厂 `/var/etc/smb.conf` 完全一致。
* **hotplug 入口**：`install.sh` 重装后 `/etc/hotplug.d/block/90-s8-mounts` md5 仍 `051ba4ad…`，旧版与新版本内容一致，覆盖安装无漂移。
* **兼容层**：`s8compat` 仍为 `versions/v1`，hook/adapter/wrapper 三项校验 OK，无需迁移。
* **MANIFEST 校验**：新包 `MANIFEST.md5` 含 `VERSION`（`dede85f0…`）等 10 项，设备 `md5sum -c` 全 OK；
  `SHA256SUMS` 11 项（含 `MANIFEST.md5`）供分发端核对。
* **回滚**：`previous` 在升级时写为 `1.0.1-r2d`，回滚与再次安装均按新版本目录名工作，无残留半装状态。

1.0.2-r2d 安装/升级/回滚/重装全程 `smb.conf` 均为 9 段
（`[global] [homes] [XiaoMi] [XiaoMi-usb0] [下载] [共享] [图片] [摄像机监控视频$] [文档]`）；
未列名客户端因 `[XiaoMi-usb0] browseable=no` 枚举到 6 个 Disk。

### 5.3.2 1.0.2-r2d → 1.0.3-r2d（已实机安装）

触发原因：`compat/90-s8-mounts` 的日志落点从 `logger -t s8compat`（user.notice，本机不落 `/tmp/messages`）
改为追加 `/userdisk/data/s8compat/logs/hotplug.log`，字节 `051ba4ad…` → `861b98d8…`，与 1.0.2-r2d 已安装内容不一致。

| 步骤 | 结果 |
| --- | --- |
| 构建 | `release/miwifi-smb-1.0.3-r2d/`，`VERSION=1.0.3-r2d`，仅 `compat/90-s8-mounts` 相对 1.0.2-r2d 变更 |
| 包内校验 | `md5sum -c MANIFEST.md5` 10/10 OK；`shasum -a 256 -c SHA256SUMS` 11/11 OK（主机侧执行） |
| 顶层 tar | `miwifi-smb-1.0.3-r2d.tar.gz`，14 299 319 B，MD5 `f305a1b94637afc8b4a9cd9b359d6c32`，SHA-256 `bbb6ff92…`（ustar，无 AppleDouble） |
| 实机安装 | **已执行（2026-11-08 22:55，`install-release.sh upgrade`，RC=0）**。`current -> versions/1.0.3-r2d/root`，`state/previous=1.0.2-r2d`；`samba-s5d` 新 pid **3093** 持有 139/445（旧 pid 8906 退出）；共享 **9 段**；`hotplug.md5` 与 `/etc/hotplug.d/block/90-s8-mounts` 均为 `861b98d8…`，版本树与 hotplug 入口自此一致；`/etc/config/samba` 未改动（仍 `244eb53e…`） |

### 5.4 兜底行为（实测）

| 场景 | 做法 | 结果 |
| --- | --- | --- |
| 运行树不可用（模拟"数据盘未挂载"） | 停新版后 `S8_SMB_ROOT=/userdisk/data/__missing_root /etc/init.d/samba start` | hook 判定 `usable=false`，回退 `/usr/sbin/supervisord start`；原厂 `smbd` pid 14956 接管 139/445。注意：该路径 `start` 返回 **rc=1**（supervisord 自身语义），但端口实际已监听 |
| 恢复新版 | 用同一环境变量 `stop` 停原厂，再正常 `start` | 新版 pid 19168 接管，无原厂残留 |
| 卸载后 | `/etc/init.d/samba start` | 原厂 init 直接启动原厂 `smbd`，139/445 正常 |
| OTA / 恢复出厂 | 不能在此设备执行（见 §3） | `/etc` 被覆盖后 wrapper 丢失，139/445 自动回原厂；`/userdisk/data` 上的包与版本树保留，重装即可恢复 |

旧的 v1 运行树在卸载前已打包备份到 `/userdisk/data/s7root-backup/v1-root.tar.gz`（MD5 `cda5fa54…`），
并恢复为 `versions/v1` 保留在设备上；当前 `previous` 已指向 `1.0.1-r2d`，`versions/v1` 仍可作为更早的回退目标。

### 5.5 已知缺口

* 包未签名（§3）。
* 首次 `smbclient -L` 偶发空列表的瞬态（§2.5 补充），未定位到服务端可复现条件。
* `supervisord` 兜底路径返回 rc=1 与"端口已监听"不一致，属原厂脚本语义；wrapper 不在该路径上改写返回码。

## 6. 设备最终状态（2026-11-08 收尾）

| 项 | 值 |
| --- | --- |
| 运行版本 | `1.0.3-r2d`；`/userdisk/data/s7root/current -> versions/1.0.3-r2d/root` |
| 回退目标 | `previous=1.0.2-r2d`（已安装且可回退）；`versions/v1` 仍在，`/userdisk/data/s7root-backup/v1-root.tar.gz` 保留 |
| 前缀链接 | `/userdisk/data/samba-s2/root -> /userdisk/data/s7root/versions/1.0.3-r2d/root` |
| 139/445 | 均由 `samba-s5d`（pid **3093**）持有；无原厂 `samba_multicall` 进程 |
| 共享 | `smb.conf` **9 段**（WD 931G 大盘在位：`[global] [homes] [XiaoMi] [XiaoMi-usb0] [下载] [共享] [图片] [摄像机监控视频$] [文档]`） |
| USB 共享 | `[XiaoMi-usb0]` → `/extdisks/sdb1`（`grep -c`=1，无重复段）；`/etc/config/samba` md5 `244eb53e…`（适配器不回写 UCI） |
| 适配器 | md5 `f106c788052402fc4fb7dc2614543fd3`（含挂载派生层）；`/etc/hotplug.d/block/90-s8-mounts` md5 `861b98d8…`（文件日志版），与发布包及 `s8compat/versions/v1/hotplug.md5` 内容一致 |
| 兼容层 | `/userdisk/data/s8compat/stage/install.sh verify` rc=0，hook/adapter/wrapper 三项 MD5 OK |
| 发布包 | `/userdisk/data/release/miwifi-smb-1.0.3-r2d` 已落到设备；`./install-release.sh verify` 10/10 OK（`version=1.0.3-r2d`、`tree_md5=0f6001010c84a016cd46f129dbe47388`） |
| 采集工装 | `s8-usb-test` 采集进程 **已停止**（pid 21094 已退出，`ps` 无残留）；`collect.log` 522 KiB 定稿于 22:56:42 后不再增长；证据归档见 `docs/evidence/2026-11-08-hotplug/` |
| 测试残留 | 无半装状态；`/userdisk/data/release` 保留 `1.0.1-r2d` / `1.0.2-r2d` 旧包（历史对照）；`/tmp` 仅留 `s8-backup-adapter.sh`、`s8-backup-install.sh` 两个回滚备份 |

## 7. 按设备磁盘访问拦截真机验证（2026-11-09，`1.0.6-r2d` 第二版）

设备继续运行 `1.0.6-r2d` 第二版（tar sha256 `f2285da6…`，已装 v1 载荷未变），本轮只读验证，
证据全部落盘在 [evidence/2026-11-09-diskacl](evidence/2026-11-09-diskacl)。实现说明见
[diskacl.md](diskacl.md)，决策见 [decisions.md](decisions.md) 的 D-S9-01…07。

### 7.1 装机与自检

| 步骤 | 时间 | 结果 | 证据 |
| --- | --- | --- | --- |
| 装机前基线比对 | 02:26 | 与旧快照一致（1.0.4-r2d、adapter `53a5ba4e…`、无 s8 链） | `preflight-before-install.txt` |
| `verify → install` | 02:26–02:27 | `current -> versions/1.0.6-r2d/root`、`previous=1.0.4-r2d` | `install-run.txt`、`install-postcheck.txt` |
| 装完核验 | 02:27 | 8 DROP + RETURN、INPUT 1/2 跳转、无 `s8-pridisk`、cron 行/权限/语法 OK、pid 13855、`smb.conf` 9 段 | `install-postcheck.txt` |
| 自检 `samba restart` | 02:29 | 重启后仍 8 DROP + RETURN，无无条件 DROP；本机挂载正常 | `restart-selfcheck.txt`、`smb-access-after-restart.txt` |
| 装机故障 | 02:31–02:36 | 误发 `SIGHUP` 使 crond 退出，已 `start`/`restart` 恢复；补丁 `compat/install.sh` 后重打包并重新 `verify` | `rollback-and-incident.txt`、`package-reverify-cronfix.txt` |

### 7.2 `yes→no`（App 关闭 `00:15:5d:03:00:23` 的全盘访问）

* 02:41:27 原厂 `tm-unregister` → 02:41:28 `diskacl: cleared` → 02:41:36 新实例 pid 23178 →
  02:41:37 `applied allow=31 deny=9`；`macfilter` md5 `1fa7f1d5…`→`45421091…`。
* 链变为 **9 DROP + 1 RETURN**，新增项为 `00:15:5D:03:00:23`；`diskacl.state` `denied=8→9`。
* 拦截有效性：该 MAC 规则 pkts `22→26→48→70`（约每 15 秒 +11 包），全部 DROP；
  同 `netstat` 无该 IP 的 445 连接。
* 对照：本机 `smbutil view` + `mount_smbfs` 成功，其余 31 台 `lan=yes` 未被误伤。
* 证据：[`lan-no-rules.txt`](evidence/2026-11-09-diskacl/lan-no-rules.txt)、
  [`lan-no-pkts-growth.txt`](evidence/2026-11-09-diskacl/lan-no-pkts-growth.txt)、
  [`lan-no-state.txt`](evidence/2026-11-09-diskacl/lan-no-state.txt)、
  [`lan-no-logs.txt`](evidence/2026-11-09-diskacl/lan-no-logs.txt)、
  [`control-access-during-lan-no.txt`](evidence/2026-11-09-diskacl/control-access-during-lan-no.txt)。

### 7.3 `no→yes`（App 打开同一设备，仅 cron 兜底）

* `macfilter` mtime 02:44:40 → 链重建 02:45:02，**实测延迟 22 秒**（上限 60 秒）；
  `adapter.log` 在 02:44:40–02:45:01 无 `cleared`/`started`，证明纯 cron 路径。
* 链回到 **8 DROP + 1 RETURN**，该 MAC 消失；`diskacl.state` `denied=9→8`、`allowed=31→32`。
* **samba 主进程未重启**：`samba-s5d -D` 仍为 pid 23178（`pidof` 首值 25929 是
  `{smbd[192.168.3.63]}` 连接子进程，非主进程）。
* 恢复证据：RETURN 命中 `14 pkts / 1858 B`；`netstat` 显示
  `192.168.3.2:445 ESTABLISHED 192.168.3.63:60894`，对应子进程存在。
* 对照：本机 `smbutil view` + `mount_smbfs` 再次成功。
* 证据：[`lan-yes-restored-snapshot.txt`](evidence/2026-11-09-diskacl/lan-yes-restored-snapshot.txt)、
  [`control-access-after-restore.txt`](evidence/2026-11-09-diskacl/control-access-after-restore.txt)。

### 7.4 结论

黑名单语义、拒绝策略、legacy 清理、cron 兜底与重启安全性均在真机闭环；
两方向延迟与"名单外不误伤"有实测数字。剩余仅发布收口（`1.0.7-r2d`）与文档/包作废标注。

## 8. `1.0.7-r2d` 装机与访客规则自检（2026-11-09 03:10–03:15）

### 8.1 装机

* `install-release.sh upgrade`，`current -> versions/1.0.7-r2d/root`；
  `compat` 下 adapter `00ca9624…`、sync `2a00da5e…`，与 `MANIFEST.md5` 一致。
* 装机后 `INPUT`（自顶向下）：`br-lan tcp -> s8-diskacl`、`br-lan udp -> s8-diskacl`、
  `-i br-guest -p tcp -m multiport --dports 139,445 -j DROP`、
  `mixbox-firewall ACCEPT`、`delegate_input`。访客规则在原厂 ACCEPT **之前**（4 vs 5）。
* `diskacl-status`：`guest=enforced`，`jumps=2`，`legacy=absent`，`denied=8`、`allowed=32`。
* 快照：[`install-1.0.7-pre-snapshot.txt`](evidence/2026-11-09-diskacl/install-1.0.7-pre-snapshot.txt)、
  [`install-1.0.7-post-snapshot.txt`](evidence/2026-11-09-diskacl/install-1.0.7-post-snapshot.txt)、
  [`install-1.0.7-run.txt`](evidence/2026-11-09-diskacl/install-1.0.7-run.txt)。

### 8.2 `samba restart` 自检

* 重启后主进程 pid `630 -> 1687`；链仍为 **8 DROP + 1 RETURN**，没有退化成全员 DROP。
* 访客规则仍在原厂 ACCEPT 之前；`adapter.log` 记录 `guest: DROP br-guest tcp 139,445`。
* LAN 与名单外对照：本机 `smbutil view` 成功列出 3 个共享；`RETURN` 命中从 28 增至 47，
  证明 LAN 流量确实穿过该链并被放行。访客规则计数为 0（访客网未起来，无流量）。
* 证据：[`restart-selfcheck-1.0.7.txt`](evidence/2026-11-09-diskacl/restart-selfcheck-1.0.7.txt)。

### 8.3 cron 访客健康检查

* 手动删除访客规则（`iptables -D`），规则计数立即为 0；**约 50 秒后**由 cron 调用
  `diskacl-sync.sh` 重建，03:12:05 恢复，位置仍在原厂 ACCEPT 之前。
* 证据：[`cron-guest-healthcheck-1.0.7.txt`](evidence/2026-11-09-diskacl/cron-guest-healthcheck-1.0.7.txt)。

### 8.4 访客网真实流量测试：BLOCKED

* 临时置 `wireless.guest_2G.disabled=0` 并 `wifi up`：`wl1.2` 未能创建
  （`wl1: WLC_SET_VAR(bss): Invalid argument`、`wifi: wl driver adapter not found`），
  `br-guest` 成员接口始终为空。已立即恢复 `disabled=1` 并再次 `wifi up`，
  确认 `br-guest` 无成员、`wl1.2` 不存在、其余无线字段（SSID/密钥/macfilter/maclist/ap_isolate）不变。
* 本机侧亦无可用访客客户端：`en0` 为虚拟化接口，`networksetup -getairportnetwork en0`
  报告未关联任何 AirPort 网络，无法关联访客 SSID。为保证不"凑结果"，未改动无线配置去强行造流量。
* 兜底证据：访客规则位次与 `diskacl-status guest=enforced` 的只读快照，以及会把违规流量挡在
  原厂 ACCEPT 之前的 dry-run 规则集；
  [`guest-2G-enable-attempt-BLOCKED.txt`](evidence/2026-11-09-diskacl/guest-2G-enable-attempt-BLOCKED.txt)、
  [`dry-run-guest-1.0.7.txt`](evidence/2026-11-09-diskacl/dry-run-guest-1.0.7.txt)。
* 结论：规则面与健康检查已在真机闭环；"访客客户端 139/445 不通、137/138 原状"的端到端实测
  因本机无线驱动无法拉起访客 BSS 而无法执行，需在有真实访客客户端的条件下补测。


