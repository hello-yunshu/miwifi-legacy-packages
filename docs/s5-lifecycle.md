# S5 小米管理与服务生命周期

日期：2026-11-08
设备：小米路由器（192.168.3.2），原厂 Samba 4.0.21 继续运行；新版为 4.25.1，独立目录、独立端口 1445。
构建前缀：`/userdisk/data/samba-s2/root`（S2–S4 沿用的编译前缀；本轮未重定位）。

## 1. 结论摘要

1. 交付了启动与配置适配器 `recipes/samba/xiaomi-smb-adapter.sh`：从 UCI 只读生成配置、`testparm` 校验、保留 last-good、按 PID 文件控制实例。没有调用 `/etc/init.d/samba`、`shareUpdate`、`supervisord`。
2. 共享启停、权限切换、相机时间窗、配置失败与恢复、启动/停止/重启/重载/退出码，均在设备上实测通过；配置失败时旧文件字节不变（md5 相同）并输出可诊断错误。
3. **跨版本 `smbcontrol` 不兼容，且旧版控制新版会直接杀死新版实例**：4.0.21 的 `smbcontrol ... reload-config` 指向 4.25.1 实例后，新实例消失（`pidof` 为 0），旧工具退出码仍是 0；反向（4.25.1 → 4.0.21 隔离实例）退出码 1、旧实例存活。结论是两代消息协议不能混用。
4. **进程名有真实碰撞风险**：busybox `pidof` 按 `/proc/<pid>/exe` 解析后的基名匹配，用符号链接把 `samba-s5d` 指向 `smbd` 仍会被 `pidof smbd` 命中。适配器改为复制一份真实二进制启动，`pidof smbd` 才只返回原厂进程。
5. 未验证项：真实 App/管理界面调用 `shareUpdate`、真实 USB 插拔、MiniDLNA 重启与电视通知、新版替换原厂后的生命周期。这些标为 BLOCKED，不用“配置正确”冒充。

## 2. 原厂管理链路（静态与运行时证据）

### 2.1 `/etc/init.d/samba`

| 操作 | 行为 |
| --- | --- |
| `start` | 读 `/userdisk/appdata/app_infos/2882303761517280984.manifest`，仅当 `status == 5` 才启动；`/usr/sbin/shareUpdate -s`；`updateconfig` 生成 `/var/etc/smb.conf`；`/usr/sbin/supervisord start`；`service_start /usr/sbin/nmbd -D`；`pidof smbd` 把 PID 写入 `/dev/cgroup/cpu/samba/tasks` |
| `stop` | `/usr/sbin/supervisord stop`；`service_stop /usr/sbin/nmbd` |
| `reload` | `updateconfig`；`smbcontrol all reload-config` |
| `status` | `/usr/sbin/supervisord status`，把返回码原样 echo |

本轮核对：修改前 `/etc/init.d/samba status` 输出 `0`、退出码 0；清理后仍为 `0`。直接执行 `/usr/sbin/supervisord status` 而没有 `PROCLINE` 时返回 1，这是包装脚本的参数要求，不是状态回归。

### 2.2 `shareUpdate`（4.0.21，ARM）

从二进制字符串与 init/hotplug 调用点确认：

- 链接 libuci，带 `flock`；写 `/etc/config/samba`，用 `commit`/`save`。
- 共享变更后调用 `/etc/init.d/samba reload`（普通变更）或 `restart`（涉及只读/相机等）；日志串包括 `samba config reloaded.`、`set samba readonly and has restart samba`、`failed to lock file`。
- 共用链路会调用 `/etc/init.d/minidlna restart`，并向电视发送信号（`sSendSignalToMitv`），还会写 `/userdisk/datacenterConfig/xqSharePath.cfg`。
- 入口不是只有 init：App/管理界面经系统接口间接调用 `shareUpdate`；`/etc/hotplug.d/block/80-sambaAndDlna` 以 `-a`/`-r` 调它，`/etc/hotplug.d/usb/11-camera` 处理相机。

**因此新版不能复用 `shareUpdate`**：它假定 `/etc/config/samba`、`/var/etc/smb.conf`、原厂 `smbcontrol` 和原厂服务生命周期。适配器改为只读 UCI，自己生成、自己校验、自己控制。

### 2.3 supervisord / taskmonitor

`/usr/sbin/supervisord` 是 shell 包装：要求 `PROCLINE`（init 导出 `/usr/sbin/smbd -D`），再调用 `taskmonitorTool` → `TaskMonitorServer`。也就是说原厂“进程是否在跑”的判定不在 init 脚本里，而在监控服务里；本轮没有在停产原厂服务的前提下验证其停止匹配规则（见 §6）。

### 2.4 UCI 键

- `samba.@samba[0]`：`name`、`workgroup`、`description`、`charset`、`homes`。
- `samba.@sambashare[N]`：`name`、`path`、`preexec`、`users`、`read_only`、`guest_ok`、`create_mask`、`dir_mask`、`browseable`、`force_user`。
- `misc.samba.smb_tune` 及 `smb_sndbuf`/`smb_rcvbuf`/`smb_wcache`/`smb2_max_buf`/`default_cpumask`。
- `misc.smb_ctl.limit`、`start_time`、`end_time`：本机**没有**该 section（`uci show` 报 not found），即相机共享走默认 `1` 与默认时间窗。

## 3. 适配器

文件：`recipes/samba/xiaomi-smb-adapter.sh`

```
generate   从 UCI 渲染、校验、保留 last-good
start      生成后启动（-N 跳过生成）
stop       只按 PID 文件停止
restart    stop + start
reload     generate + 新版 smbcontrol reload-config
status     running / degraded / stale / stopped
check      打印隔离与配置事实
```

选项：`-r` 根目录、`-c` UCI 目录、`-p` 端口、`-b` 绑定地址、`-n` 进程名、`-N` 跳过生成。

退出码：0 成功；1 运行失败；2 调用/树错误；3 配置被拒绝；4 PID 文件陈旧或指向外来进程（不杀）；5 端口占用；6 reload 通道失败（配置保留，需重启）。

关键实现：

- **只读 UCI**：全部读取走 `uci -c <dir>`，测试用 shadow 目录；从未写 `/etc/config/samba`。
- **三道采纳校验**：渲染规则（绝对路径、`..`、共享名方括号、重名）→ `testparm -s`（4.25.1）→ 隔离检查（禁止 `/tmp/lock`、`/tmp/run`、`/var/etc` 等原厂路径与 139/445）。相机共享再检查 `lib/vfs/readonly.so` 是否存在，防止“配置对、模块缺”静默退化为可写共享。
- **last-good**：成功才 `mv` 覆盖；失败删除临时文件，`smb.conf` 字节不变，`smb.conf.last-good` 保留上一版。
- **启动**：先确认编译前缀与 `ROOT` 一致（`smbd -b` 的 `SBINDIR`），用真实副本 `sbin/samba-s5d` 启动，`umask 077`，写自己的 `pid directory`。不匹配直接拒绝，避免模块路径半失效。
- **停止**：只读自己的 PID 文件；校验 `/proc/<pid>/exe` 在 `ROOT/sbin/` 下才发 TERM，超时再 TERM->KILL 同一 PID。死 PID 清 PID 文件；活的外来 PID 返回 4，绝不杀。
- **reload**：只用新版 `smbcontrol -s <自己的 conf> smbd reload-config`；失败返回 6，不重启、不改配置。

## 4. 生命周期矩阵（设备实测）

| 场景 | 结果 |
| --- | --- |
| `status` 运行中 | `running pid=… port=1445`，rc 0 |
| `stop` | rc 0，PID 消失、端口释放 |
| `stop` 再执行 | `stopped (no pidfile)`，rc 0 |
| `start` | rc 0，PID/端口就绪 |
| `start` 重复 | `already running pid=…`，rc 0，不产生第二实例 |
| `restart` | rc 0，PID 变化（如 3163），端口不变 |
| 陈旧 PID（写入原厂 1448） | `status` rc 4；`stop` rc 4 且拒绝杀；1448 存活 |
| 崩溃后死 PID 文件 | `status` rc 4；`start` 清理死 PID 后正常启动（30250 → 2413） |
| 端口被占（`nc -l -p 1445`） | `start` rc 5，不启动 |
| 停止状态 `reload` | rc 3 |
| 运行中 `reload` | rc 0，PID 不变（25066 / 30250 两轮） |
| 编译前缀不符 | rc 2，明确报 `tree prefix mismatch` |

## 5. 配置矩阵（设备实测）

shadow UCI 目录为 `/userdisk/data/samba-s5/uci`，原厂配置只读复制。

| 变更 | 结果 |
| --- | --- |
| 共享 `read_only=yes` + reload | 列表成功、写入 `ACCESS_DENIED`；改回 `no` 后写成功；PID 不变 |
| 新增共享 `S5Test` + reload | 树连接成功、可列目录；删除 section + reload 后 `BAD_NETWORK_NAME` |
| 相机 `misc.smb_ctl.limit=0` | 生成的配置无 `vfs object`，共享可列 |
| 相机 `limit=1` + 窗口 `00:00:00`–`tomorrow 00:00:00` | 配置写入 `vfs object = readonly`，列表 `ACCESS_DENIED` |
| 共享路径改成相对路径 | rc 3，`smb.conf` md5 不变，日志记录 `reject share path (not absolute)` |
| 共享重名 | rc 3，旧配置不变，日志记录 `reject duplicate share` |
| `guest_ok=maybe` | `testparm` 拒绝，rc 3，旧配置不变 |
| 相机共享但 `readonly.so` 缺失 | rc 3，日志 `rejected: readonly module missing` |
| 路径不存在（模拟磁盘不在） | 生成/启动正常；该共享返回 `BAD_NETWORK_NAME`，其他共享不受影响 |
| 修复 UCI 后再次 generate | rc 0，md5 回到 `8b92b487…e07c` |

`smb_tune=1` 的原厂参数里，`socket options`、`write cache size`、`default cpumask` 在 4.25.1 构建中不可用/被移除（`SO_SNDBUFFORCE` 被 uClibc 拒绝），适配器不再输出，仅保留 `smb2 max read/write/trans`。

## 6. 进程身份与跨版本控制

### 6.1 `pidof` 碰撞（实测）

| 启动方式 | `pidof smbd` | 说明 |
| --- | --- | --- |
| 符号链接 `samba-s5d -> smbd` | 含新版 2413/2422/2423 | busybox 按 `/proc/<pid>/exe` 解析后的基名匹配 |
| 真实副本 `sbin/samba-s5d` | 只有原厂 30631/19696/1448 | 新版只被 `pidof samba-s5d` 命中 |

符号链接方案会让原厂 `pidof smbd` 把新版算进去（init 的 start 还会把它们写入 samba cgroup），因此适配器改用真实副本。

### 6.2 `smbcontrol` 跨版本

| 方向 | 命令 | 结果 |
| --- | --- | --- |
| 新版 → 新版 | 适配器 `reload` | rc 0，实例存活 |
| 旧版 → 旧版（隔离 1446） | `/usr/bin/smbcontrol -s … smbd reload-config` | rc 0，实例存活（基线） |
| **旧版 → 新版** | 4.0.21 `smbcontrol -s <新配置> smbd reload-config` | 工具 rc 0，**新版实例被杀**（30250 消失，PID 文件残留，日志无退出记录） |
| 新版 → 旧版 | 4.25.1 `smbcontrol -s <旧配置> smbd reload-config` | rc 1，旧实例存活、端口 1446 仍在 |

结论：两代控制通道不可交叉使用；旧版把新版进程当自家目标时不仅无效，还会终止新版。新版对旧版则失败退出。管理脚本不得调用原厂 `smbcontrol` 操作新版实例。

## 7. 隔离与副作用核对

运行中（pid 3163）：

- `/proc/3163/fd` 中除设备/socket/pipe 外没有 `/tmp`、`/var`、`samba-s2` 路径；`cwd` 与所有 TDB/锁目录都在 `ROOT` 下。
- 配置只引用 `ROOT/var/{lock,state,cache,private,run}`，端口 1445；隔离检查通过。
- `pidof smbd` 只返回原厂 PID（真实副本方案）。
- 原厂 `samba_multicall` md5 `5e422d34…03e8`、`/etc/config/samba` md5 `244eb53e…561a`、`/var/etc/smb.conf` md5 `bcad8b90…cf99`、模板 md5 `95ad7d41…5b94`，均与动手前一致。
- 原厂 smbd 父进程 1448、nmbd 8469 存活；139/445 仍属 1448，137/138 仍属 8469。
- MiniDLNA 未运行；`/etc/config/minidlna` 与 `/tmp/minidlna.conf` mtime 仍是 2018-10-16；适配器不调用任何 `init.d` 或 `shareUpdate`。
- 根分区可用 20588 KB（81%），与开始时一致；`/userdisk/data` 用量 52%。

## 8. 差异与限制

- **BLOCKED：真实 App/管理界面操作**。没有调用 App 的 `shareUpdate`；本轮验证的是“UCI 变化 → 新版配置 → 行为”这一层。App 到 UCI 的写入、manifest 的 `status` 门控、以及 `shareUpdate` 的 flock/重入未在新版链路上实测。
- **BLOCKED：真实 USB 磁盘插拔**。设备上 `/extdisks/sdb1` 是生产盘，不允许拔插；`/etc/hotplug.d/block/80-sambaAndDlna` 只做静态核对。用“路径不存在”验证了共享级降级（`BAD_NETWORK_NAME`），不等价于热插拔。
- **BLOCKED：MiniDLNA 重启与电视通知**。设备上 MiniDLNA 未运行，无电视可测；只能确认适配器不触碰这条链路。原厂 `shareUpdate` 确实会重启 MiniDLNA 并发送电视信号，替换时需另行决定是否保留。
- **BLOCKED：`supervisord` 停止匹配规则**。验证它是否会误停新版需要执行 `supervisord stop`，会停掉原厂 smbd，按约束不做。已用 `pidof` 实验证明名字层面必须去重，并用真实副本规避；监控服务内部的匹配逻辑仍未验证。
- **跨版本 `smbcontrol` 不可用**（见 §6.2），不是配置问题。
- 编译前缀绑定：当前二进制只能部署在 `/userdisk/data/samba-s2/root` 或等价映射；重定位推迟到后续阶段，适配器对不匹配直接拒绝。
- 部署树来自 S3 打包的 tarball，里面是 S3 的 `readonly.so`（md5 `0d9f8743…`），不含 S4 的 `create_file` 版本；本轮测试时补入 S4 模块（`83e70d25…`，30702 字节），并给适配器加了“相机配置必须伴随模块存在”的检查。这也说明打包链路需要把 S4 产物纳入，否则会出现配置正确但语义退化为上游 connect 只读。
- S4 的时间窗语义与本阶段无冲突：S5 只负责把 `misc.smb_ctl.*` 渲染成 `vfs object`/`readonly:period`，拒绝仍由 S4 的 `create_file` 钩子执行；共享级 `read_only` 与此独立。
- S3/S4 遗留项：Finder/`mount_smbfs` 非 445、真实摄像机、原厂撤销对照、IPv6/SMB1 RAP、系统时间跳变与长连接，均不参与 S5 的生成/启停判定，与本阶段无关；未重新测试。

## 9. 复现与清理

关键命令（设备上）：

```
A=/userdisk/data/samba-s5/xiaomi-smb-adapter.sh
$A -r /userdisk/data/samba-s5/root -c /userdisk/data/samba-s5/uci generate
$A -r /userdisk/data/samba-s5/root -c /userdisk/data/samba-s5/uci start
$A -r /userdisk/data/samba-s5/root -c /userdisk/data/samba-s5/uci reload
$A -r /userdisk/data/samba-s5/root -c /userdisk/data/samba-s5/uci stop
```

清理按精确路径/PID：适配器 `stop`（PID 文件）；原厂隔离实例按它自己的 `run/smbd.pid` 校验 `cmdline` 含 `s5vendor/smb.conf` 后 TERM；删除 `/userdisk/data/{samba-s5,s5vendor,s5share}` 与临时创建的 `/userdisk/data/samba-s2` 符号链接。

清理后核对：无 1445/1446 监听、无 `samba-s5d`/`s5vendor` 进程、`pidof smbd` 仅原厂、原厂 md5/PID/端口/MiniDLNA 全部复原。
