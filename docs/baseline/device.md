# 脱敏设备清单

只记录平台、程序与配置事实，不含设备地址、MAC、序列号、共享名称或账号。证据编号见 [evidence.md](evidence.md)。

## 平台与系统

| 项目 | 记录 | 等级 |
| --- | --- | --- |
| 型号 | R2D，首个且唯一的首版支持型号 | 现场 |
| 固件 | 2.25.209 | 现场 |
| 架构 | ARMv7 / ARM32 EABI5，小端 | 现场、反汇编 |
| C 运行库 | uClibc 0.9.33.2，ELF 解释器 `/lib/ld-uClibc.so.0` | 现场、反汇编 |
| 内核 | Linux 2.6.36 #3，构建字符串 `MiWiFi-R2D-2.25.209 SMP PREEMPT Tue Oct 16 11:45:02 UTC 2018`，构建机 GCC 4.8.2 | 现场，本轮复核 |
| CPU | 双核 ARMv7 rev 0（Cortex-A9，part 0xc09），BogoMIPS 2798.38，特性 `swp half thumb fastmult edsp`，`Northstar Prototype` | 现场，本轮复核 |
| 实际可用内存 | `MemTotal 254448 kB`（约 248.5 MiB），采集时 `MemFree 106092 kB`，`Cached 70232 kB`，`Buffers 8320 kB`；`SwapTotal 262140 kB`，采集时全部空闲 | 现场，本轮复核 |
| 磁盘与文件系统 | 见下方“磁盘、文件系统与挂载” | 现场，本轮复核 |
| 包数据库 | 现场未发现可用的 opkg 查询入口；本轮未执行安装类命令 | 现场，未确认 |

样本 ROM 2.24.11 的版本文件把内核字段写成占位值 `0.0.1`，不能用它推断内核版本；其 opkg 状态把 `samba4-server 4.0.21-1` 标为 not-installed，但同一镜像内存在对应程序，说明该样本的包数据库记录本身不可作为安装状态依据。见 [evidence.md](evidence.md) 的 E7。

## 原厂 Samba 与运行入口

| 项目 | 记录 | 等级 |
| --- | --- | --- |
| 版本 | 4.0.21，带小米定制 | 现场、样本、反汇编 |
| multicall | `/usr/sbin/smbd`、`nmbd`、`smbpasswd` 均指向 `/usr/sbin/samba_multicall` | 现场、反汇编 |
| 程序散列 | 现场 SHA-256 `6709018c70061bbb2ab63ff9dacec917ea4ff024ca493800ac0028c814f620f2`；MD5 `5e422d3463f40b4405ef8325ce3603e8`；大小 4,325,084 字节 | 反汇编，本轮复核 |
| ELF | 32 位小端 ARM、EABI5、动态链接、已 strip、入口 `0xc454` | 反汇编，本轮复核 |
| 动态依赖 | `libaio.so.1`、`libdl.so.0`、`libubus.so`、`libubox.so`、`libcrypt.so.0`、`libresolv.so.0`、`libpthread.so.0`、`libz.so.1`、`libc.so.0`、`libubacktrace.so.0` | 反汇编，本轮复核 |
| 模块目录 | 现场确认 `/usr/lib/samba` 与 `/usr/lib/samba/vfs` 均不存在；摄像机只读逻辑内建在 multicall 中 | 现场，本轮复核 |

出现动态依赖不等于每个库都在请求路径中被调用。覆盖 multicall 会同时改变 smbd、nmbd、smbpasswd 三个入口，不能把它当作只替换文件共享进程。

## 运行状态与路径

| 项目 | 记录 | 等级 |
| --- | --- | --- |
| 服务监听 | 139/TCP、445/TCP 绑定 `192.168.3.2`；137/UDP、138/UDP 绑定 `0.0.0.0`；无 IPv6 监听 | 现场，本轮复核 |
| 进程参数 | 现场 4 个 `smbd -D`、1 个 `nmbd -D`；无额外命令行参数（见下方“进程”） | 现场，本轮复核 |
| 进程检查 | init 用 `pidof smbd` / `pidof nmbd` 判断启动成功 | 样本 |
| 配置入口 | `/etc/samba/smb.conf` → `/var/etc/smb.conf` → 实际解析到 `/tmp/etc/smb.conf` | 现场，本轮复核 |
| 账号库 | `/etc/samba/smbpasswd`，现场为空文件（MD5 `d41d8cd9…`） | 现场 |
| 锁目录 | 进程实际使用 `/tmp/lock`、`/tmp/locks`；`/var/lock`、`/var/locks` 为兼容路径 | 现场、反汇编 |
| 日志 | 模板指向 `/tmp/log/samba.log`，`log level 1`、`max log size 500`；现场日志级别已确认恢复为 1 | 样本、现场 |
| 内存/CPU 调优 | UCI `misc.samba` 含缓冲区、写缓存、SMB2 缓冲和 CPU 绑核参数 | 样本 |

## 现场配置校验值

2026-11-07 只读检查开始与结束时一致；仅记录校验值，不复制配置内容：

| 路径 | MD5 |
| --- | --- |
| `/etc/config/samba` | `244eb53e5019b95a408aebe49602561a` |
| `/etc/samba/smb.conf.template` | `95ad7d4146de73a50fb33e823d495b94` |
| `/etc/samba/smb.conf` | `bcad8b90869688b7982a50aaa891cf99` |
| `/etc/samba/smbpasswd` | `d41d8cd98f00b204e9800998ecf8427e`（空文件） |

## 官方 ROM 样本程序散列

用于判断是否存在可替换的现成程序，不作为现场证据：

| 样本 | SHA-256 |
| --- | --- |
| 现场 R2D 提取程序 | `6709018c70061bbb2ab63ff9dacec917ea4ff024ca493800ac0028c814f620f2` |
| R2D 稳定版 2.24.11 | `546a0cb6f8a9c130a1cccbc031f39d0258e1512ed50c08cb3a317e076aaedefe` |
| R1D 稳定版 | `6709018c70061bbb2ab63ff9dacec917ea4ff024ca493800ac0028c814f620f2`（与现场相同） |
| R3D | `774f093a44c3dd73ef73108b1f979a1203e2de7f9196abafa56f5e7f6eff0ada` |
| AX9000（AArch64/musl） | `e16fa1e733a44e8ed0d0c1d8e30b1635228765304f99b16bb07c7d97879e883b` |

样本 `shareUpdate` 为 260,936 字节，SHA-256 `62d231bad65f5cc38037e699429897a44547bb97256c8908d79d2094bbdeeb9a`（E7）。

## 测试设备与工具（首轮）

| 设备/工具 | 状态 | 等级 |
| --- | --- | --- |
| macOS 客户端主机 | macOS 27.2（构建 26B123），原生 `smbutil`、`mount_smbfs` 可用 | 本机复核 |
| Emby | 4.10.2.0，已用于隔离认证与目录/读取测试；完整播放未测 | 隔离 |
| Samba 客户端 | 宿主未安装 `smbclient`；实验使用 4.23.13 自带客户端 | 本机复核、隔离 |
| Windows 11 | 无设备，未验证 | 待确认 |
| 小米 WiFi App | 未做端到端验证 | 待确认 |
| 摄像机 | 无设备，未验证 | 待确认 |

macOS 版本是本轮在本机读取的结果；不能据此推断其他客户端版本的行为。首轮不承诺 Windows 11 兼容。

## S0 现场采集（2026-11-07）

采集时间 `2026-11-07T15:06:27+0800`（`07:06:27Z`），设备已运行 3 天 8 小时 46 分。方式为 SSH 只读登录（RSA 身份，Dropbear 2011.54 需 `diffie-hellman-group1-sha1` 与 `ssh-rsa` 兼容参数），全程只执行读取命令，未改配置、未安装、未重启服务。原始输出按命令分组保存在研究档案 `research/s0-live/01-system.txt` … `13-maps.txt`，本仓库只收录脱敏后的结论（E9）。

### 磁盘、文件系统与挂载

| 挂载点 | 设备 | 类型 | 容量 | 已用 | 可用 | 选项要点 |
| --- | --- | --- | --- | --- | --- | --- |
| `/` | `/dev/ubi1_0` | ubifs | 107.9M | 87.7M（81%） | 20.1M | `ro,noatime,bulk_read,no_chk_data_crc,compr=none` |
| `/data`、`/userdisk`、`/etc` | `/dev/ubi2_0` | ubifs | 204.1M | 61.9M（31%） | 137.4M | `rw,noatime,bulk_read,compr=none`，同一 UBI 卷多处挂载 |
| `/userdisk/data` | `/dev/sda1` | ext4 | 931.2G | 484.8G（52%） | 446.5G | `rw,noatime,barrier=1,data=ordered` |
| `/extdisks/sdb1` | `/dev/sdb1` | tntfs | 931.5G | 400.1G（43%） | 531.4G | `uid=0,gid=0,umask=00,nls=utf8` |
| `/tmp` | tmpfs | tmpfs | 99.4M | 2.8M | 96.6M | `size=101780k,mode=755` |
| `/extdisks` | tmpfs | tmpfs | 99.4M | 2.8M | 96.6M | 与外接盘挂载点共用 tmpfs |

根文件系统只读，`/etc` 实际可写（ubifs 单独挂载），因此运行期改写 `/var/etc/smb.conf` 是可行的；配置文件的“持久”边界只在 `/data`、`/userdisk` 与外接盘。内核支持的文件系统中可见 `vfat`、`ext2/3/4`、`cifs`、`ubifs`、`tntfs`、`fuse`，没有 `xfs`、`btrfs`。

### 进程

| 项目 | 现场值 |
| --- | --- |
| smbd | 4 个，PID `2117`、`7577`、`8471`、`18624`，命令行均为 `/usr/sbin/smbd -D` |
| nmbd | 1 个，PID `8469`，命令行 `/usr/sbin/nmbd -D` |
| 可执行体 | 全部 `readlink /proc/<pid>/exe` 指向 `/usr/sbin/samba_multicall` |
| 工作目录 | `2117` → `/extdisks/sdb1`；`7577` → `/userdisk/data`；`8471`、`18624` → `/` |
| 线程数 | 每个进程 1 个线程（非线程池模型） |
| 打开文件数 | smbd 28—30，nmbd 19 |
| 绑定关系 | `8471` 同时持有 139 与 445 的监听套接字；`18624`、`7577` 对应已建立连接 |

多出来的 smbd 不是“多实例服务”，而是主进程之外按连接派生的工作进程；判断服务是否起来仍以 `pidof smbd` / `pidof nmbd` 为准。

### 监听端口

| 协议 | 地址 | 进程 |
| --- | --- | --- |
| TCP 139 | `192.168.3.2` | `8471/smbd` |
| TCP 445 | `192.168.3.2` | `8471/smbd` |
| UDP 137 | `0.0.0.0`、`192.168.3.2`、`192.168.3.255` | `8469/nmbd` |
| UDP 138 | `0.0.0.0`、`192.168.3.2`、`192.168.3.255` | `8469/nmbd` |

Samba 只监听 `br-lan`（配置 `interfaces = br-lan`、`bind interfaces only = Yes`），没有 IPv6 的 139/445 监听。采集时有 3 条已建立连接：`192.168.3.63`、`192.168.3.83`、`192.168.3.87` 各一条到 445，说明共享正在被真实客户端使用，观测期间没有主动断开或干扰。

### 运行库散列

设备上无 `sha256sum`、`openssl`，只有 `md5sum`，因此运行库只能给 MD5；`samba_multicall` 另有此前离线算得的 SHA-256，两者可交叉核对。

| 文件 | 大小 | MD5 |
| --- | --- | --- |
| `/lib/ld-uClibc-0.9.33.2.so` | 29,660 | `6ac2c6053dee25c9fd86f321ede49378` |
| `/lib/libuClibc-0.9.33.2.so` | 575,760 | `e2164dfc067f356af2dec37acf36e9e6` |
| `/lib/libpthread-0.9.33.2.so` | 67,192 | `169c64804236677ac3089092599bcd5b` |
| `/lib/libdl-0.9.33.2.so` | — | `d47a91f9f4dc51810e2f3476e91b7a1a` |
| `/lib/libcrypt-0.9.33.2.so` | — | `bef63eda9ad3f2e071dcb9128421e448` |
| `/lib/libresolv-0.9.33.2.so` | — | `184e78fa45e2ca9a57301073f541a2ff` |
| `/lib/libm-0.9.33.2.so` | — | `f22d9b58d9968d4dcce794681110c093` |
| `/lib/libubox.so` | — | `5ccfa7cd771c8d23dde7fb3de44578b4` |
| `/lib/libubus.so` | — | `f62f8a9f8a1376548945488e5b165115` |
| `/lib/libubacktrace-0.9.33.2.so` | — | `13f68d7ce6f7c8b8dcd9146bd8c680e3` |
| `/usr/lib/libz.so.1.2.7` | — | `5a1a7dafa664586f1d7866080422eeb9` |
| `/usr/lib/libaio.so.1.0.1` | — | `ba402bf775464a1c0b3dd47ec2b261ff` |
| `/usr/sbin/samba_multicall` | 4,325,084 | `5e422d3463f40b4405ef8325ce3603e8` |
| `/usr/sbin/shareUpdate` | 261,264 | `27b354b19dea3c45bd54fcaf3c7ac4c0` |

`/proc/<pid>/maps` 显示运行期实际加载的是上表中的 11 个库（`libaio`、`libcrypt`、`libdl`、`libpthread`、`libresolv`、`libubacktrace`、`libubox`、`libubus`、`libuClibc`、`ld-uClibc`、`libz`），与 ELF `NEEDED` 一致；运行期还会打开 `/tmp/lock/{brlock,locking,messages,notify,serverid}.tdb`、`/tmp/cache/gencache.tdb`、`/tmp/etc/secrets.tdb`。

现场 `shareUpdate` 与 2.24.11 样本（260,936 字节，`62d231ba…`）**不同**，不能拿样本文本直接替换；现场版本是 261,264 字节。

### 权限相关配置与运行态

`testparm -s` 与 `testparm -sv` 的现场结果：

| 项 | 现场值 |
| --- | --- |
| `hosts allow` / `hosts deny` | 两者均为空，等于不按来源地址做静态过滤 |
| `security` | `USER` |
| `map to guest` | `Bad User`（未知用户降级为访客，而不是直接拒绝） |
| `guest account` | `nobody` |
| `null passwords` | `Yes`（`testparm` 提示该项已弃用） |
| `passdb backend` | `smbpasswd`，账号库为空文件 |
| `server min/max protocol` | `LANMAN1` / `SMB3` |
| `smb encrypt` / `server signing` | `No` / `default` |
| 共享级 `guest ok` | 全局 `Yes`，各共享未单独关闭 |
| `force user` | `XiaoMi`、`XiaoMi-usb0`、`下载`、`共享`、`图片`、`文档` 均为 `root` |
| `create mask` | `XiaoMi` 系 `0777`；`下载/共享/图片/文档` `0666`；摄像机 `0222` |
| `directory mask` | 除 `[homes]` 为默认外均为 `0777` |
| `[摄像机监控视频$]` | `preexec = mkdir -p …/%U`、`vfs objects = readonly`、`readonly:period = "today 06:00:00","tomorrow 02:00:00"`，`browseable` 未关闭 |

`IPC$` 不出现在 `smb.conf` 中，也不在 `testparm` 的共享列表里；程序内含 `IPC$` 与 `lp_add_ipc`，属 Samba 内建隐式共享。因此“关闭 IPC$”不能靠改配置实现，只能改程序或在更高层拦截。

MAC 相关运行态：

| 项 | 现场值 |
| --- | --- |
| `/tmp/loginMac.cfg` | 采集时不存在（`No such file or directory`） |
| `/userdisk/datacenterConfig/nonLoginMac.cfg` | 存在，666 字节，`-rwxrwxrwx`，mtime `Nov 6 00:45` |
| 行数 | 37 行，每行 17 字符（12 位十六进制 + 5 个冒号） |
| 格式 | 全部小写、LF 换行、无空行、无重复、无 CRLF |
| 归属 | 与 `samba_multicall` 内 `/userdisk/datacenterConfig/nonLoginMac.cfg` 字符串一致 |

`/tmp/loginMac.cfg` 缺失说明“已登录设备 MAC 名单”是按需生成或不常驻；不能据此推断登录名单为空，只能说明采集时该文件不存在。

### 地址到 MAC 的解析路径

`strings -a samba_multicall` 给出完整链路，现场 `/proc/net/arp` 有 5 条 `br-lan` 邻居记录可佐证数据源存在：

1. 先读 `/proc/net/arp`，按 IP 匹配 `br-lan` 表项；
2. 未命中时执行 `arping -f -c 2 -w 1 -I br-lan <IP>`，接口名硬编码为 `br-lan`；
3. 解析输出 `after arping, get mac: %s, pid: %d`，失败路径为 `can not get mac from arp table, try arping`、`can not get mac after arping`、`can not format arping command`。

因此 MAC 判定依赖二层的 ARP/arping 结果，而不是 DHCP 租约或客户端自报，跨网段或 ARP 被隔离时会退化为“取不到 MAC”。这条链路与 `allow_access_internal_from_macfilter` 的日志格式（`allow_access_internal_from_macfilter, mac : %s, snum : %d`）对应。

### 启动链路补充

`/etc/init.d/samba` 的 `start_impl` 顺序为：`/usr/sbin/shareUpdate -s` → `updateconfig`（按 UCI 重新生成 `/var/etc/smb.conf` 并调用 `smb_tune`）→ `/usr/sbin/supervisord start`（拉起 `smbd -D`）→ `service_start /usr/sbin/nmbd -D` → 把 smbd/nmbd 的 PID 写入 `/dev/cgroup/cpu/samba/tasks`。`start()` 还要求 `/userdisk/appdata/app_infos/2882303761517280984.manifest` 的 `status` 为 `5` 才会真正启动，这解释了“配置正确但服务没起来”的一种现场状态。现场不存在 `/etc/supervisor*`，`supervisord` 以程序自带方式运行。
