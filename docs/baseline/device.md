# 脱敏设备清单

只记录平台、程序与配置事实，不含设备地址、MAC、序列号、共享名称或账号。证据编号见 [evidence.md](evidence.md)。

## 平台与系统

| 项目 | 记录 | 等级 |
| --- | --- | --- |
| 型号 | R2D，首个且唯一的首版支持型号 | 现场 |
| 固件 | 2.25.209 | 现场 |
| 架构 | ARMv7 / ARM32 EABI5，小端 | 现场、反汇编 |
| C 运行库 | uClibc 0.9.33.2，ELF 解释器 `/lib/ld-uClibc.so.0` | 现场、反汇编 |
| 内核 | Linux 2.6.36（项目基线记录） | 现场记录，本轮未复核 |
| 实际可用内存 | 未采集 | 待确认 |
| 磁盘与文件系统 | 未采集；样本可见 `/userdisk`、`/extdisks`、`/tmp` 等路径 | 待确认 |
| 包数据库 | 现场是否存在可用 opkg 数据库未确认 | 待确认 |

样本 ROM 2.24.11 的版本文件把内核字段写成占位值 `0.0.1`，不能用它推断内核版本；其 opkg 状态把 `samba4-server 4.0.21-1` 标为 not-installed，但同一镜像内存在对应程序，说明该样本的包数据库记录本身不可作为安装状态依据。见 [evidence.md](evidence.md) 的 E7。

## 原厂 Samba 与运行入口

| 项目 | 记录 | 等级 |
| --- | --- | --- |
| 版本 | 4.0.21，带小米定制 | 现场、样本、反汇编 |
| multicall | `/usr/sbin/smbd`、`nmbd`、`smbpasswd` 均指向 `/usr/sbin/samba_multicall` | 现场、反汇编 |
| 程序散列 | 现场 SHA-256 `6709018c70061bbb2ab63ff9dacec917ea4ff024ca493800ac0028c814f620f2`；MD5 `5e422d3463f40b4405ef8325ce3603e8`；大小 4,325,084 字节 | 反汇编，本轮复核 |
| ELF | 32 位小端 ARM、EABI5、动态链接、已 strip、入口 `0xc454` | 反汇编，本轮复核 |
| 动态依赖 | `libaio.so.1`、`libdl.so.0`、`libubus.so`、`libubox.so`、`libcrypt.so.0`、`libresolv.so.0`、`libpthread.so.0`、`libz.so.1`、`libc.so.0`、`libubacktrace.so.0` | 反汇编，本轮复核 |
| 模块目录 | 检查的 `/usr/lib/samba` 及其 vfs 子目录未列出独立模块；至少摄像机只读逻辑是内建的 | 反汇编 |

出现动态依赖不等于每个库都在请求路径中被调用。覆盖 multicall 会同时改变 smbd、nmbd、smbpasswd 三个入口，不能把它当作只替换文件共享进程。

## 运行状态与路径

| 项目 | 记录 | 等级 |
| --- | --- | --- |
| 服务监听 | 445 TCP 现场确认 | 现场 |
| NetBIOS/139 | 未逐项确认 | 待确认 |
| 进程参数 | 样本 init 使用 `smbd -D` 和 `nmbd -D`；现场实际参数未采集 | 样本、待确认 |
| 进程检查 | init 用 `pidof smbd` / `pidof nmbd` 判断启动成功 | 样本 |
| 配置入口 | `/etc/samba/smb.conf` 是指向 `/var/etc/smb.conf` 的软链接 | 现场、样本 |
| 账号库 | `/etc/samba/smbpasswd`，现场为空文件 | 现场 |
| 锁目录 | 程序内可见 `/var/lock`、`/var/locks` | 反汇编 |
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

## 待补采的只读清单

以下命令只读取状态，不修改设备；输出需先脱敏再进入仓库，原始输出留在研究档案：

```sh
uname -a
cat /proc/version
cat /proc/cpuinfo | sed -n '1,30p'
cat /proc/meminfo | sed -n '1,12p'
df -h
cat /proc/self/mounts
ps w
netstat -lntup
cat /etc/openwrt_release
cat /etc/config/version
ls -l /usr/sbin/smbd /usr/sbin/nmbd /usr/sbin/smbpasswd
sha256sum /usr/lib/libc.so.0 /lib/ld-uClibc.so.0 /usr/lib/libpthread.so.0
```

内存、磁盘、进程参数和库散列补齐前，S0 的现场基线只能视为部分完成。
