# 决策记录

本文件记录各阶段中由执行侧自行拍板的细节决策与理由（用户明确表示不需要就排版、目录、命名、补丁取舍等细节回问）。

## S1（干净构建）

- D-S1-01 用 4.25.1 而非继续 4.23.13：4.23.13 是增量修复路径，不能作为“干净构建”证据；4.25.1 为当时最新稳定版，且用户指定。
- D-S1-02 构建在 Docker（linux/amd64）内的真实设备工具链里进行，产物用 QEMU 用户态冒烟：设备根分区只读且空间紧张，不能在设备上编译。
- D-S1-03 采用 `--bundled-libraries=ALL` 并自带 gnutls/nettle/hogweed/gmp：SDK sysroot 缺这些库的可用版本，系统库方案不可行。

## S2（隔离回归）

- D-S2-01 运行根选 `/userdisk/data/samba-s2`，不选 `/userdisk` 直挂点。`/userdisk` 是 ubi2_0（ubifs，仅 137.4M 可用，且有擦写寿命），`/userdisk/data` 是 sda1 ext4（446.5G 可用），容量与写入寿命都更适合放安装树、TDB 与日志。原厂 `/etc/config/samba` 的两个共享本就指向 `/userdisk/data`，说明该盘在设备正常运行期内始终在线。
- D-S2-02 以设备路径为新前缀做一次干净重建，而不是给 S1 产物打 ELF 补丁或 chroot 运行。理由：`/opt` 只读，S1 的 `RPATH` 与 `MODULESDIR` 均为编译期固化（源码中 `get_dyn_MODULESDIR()` 来自编译期 dynconfig，Samba 4.25.1 的参数表里没有可运行期覆盖的 `modules dir`），而模块目录是 smbd 加载 auth/idmap/vfs 模块的必需路径。改字符串长度会破坏 ELF 偏移，chroot 会引入“跑的不是设备原生路径下的 libc”的争议。重建保持源码 tar 散列与 5 个补丁不变，只改 `--prefix`/`--libdir` 与 `-rpath`，代价约 10 分钟（S1 全量编译实测约 7 分钟）。
- D-S2-03 新实例端口取 TCP 1445，只监听 `192.168.3.2`，不启 nmbd。原厂占 139/445 与 UDP 137/138；不上 1445/1446 之外的相邻端口，避免与未来 NetBIOS 用例混淆。
- D-S2-04 不写 `/etc/init.d`、不动 `/etc/config/samba`、不建 `/opt`。新实例完全靠 `nohup` 启动并在关闭时删除整棵新根，回滚是单条 `rm -rf`。
- D-S2-05 冒烟客户端用随包 ARM `smbclient`（与本实例同一套库），目标 `127.0.0.1:1445`，避免依赖构建机或 PC 端 SMB 栈的版本差异。
- D-S2-06 原厂 PID 清单不作为回滚判据。原厂 smbd 按连接派生，PID 集合在两次只读采集之间已从 4 个变为 5 个（多出 22286）；回滚核对改用“监听端口归属 + 二进制 MD5 + 根分区只读且用量 81%”。
- D-S2-07 重建时显式预建 waf 输出目录 `bin/c4che`。全新解压的 4.25.1 树没有 `bin/`，`configure` 在 store 阶段写 `bin/c4che/build.config.py` 时不会自建父目录，导致 `FileNotFoundError`；预建目录不改源码、不改参数，属于构建环境准备，不掩盖任何编译问题。
- D-S2-08 本机运行验证用 `/userdisk -> <DESTDIR>/userdisk` 临时符号链接补齐编译期绝对路径。前缀已经是设备路径，QEMU 进程按绝对路径访问 `/userdisk/...` 时在容器里找不到；设备上该路径原生存在，因此这只是本机验证脚手架，验证结束即删除，不进入任何部署脚本。
- D-S2-09 本轮隔离实例沿用原厂协议下限（`server min protocol = LANMAN1`），不提前关闭 SMB1。开发计划 S2 测试组写的是“SMB1 禁用”，但那是产品策略目标；当前阶段要回答的是“新 Samba 能否承接原厂现有客户端”。等 macOS/Emby/摄像机/电视的客户端矩阵给出证据后，再决定是否抬到 SMB2，避免先关协议再回头补兼容。
- D-S2-10 部署脚本必须预建 `var/lock`、`var/locks`、`var/cache`、`var/private`、`var/log`、`var/run/ncalrpc`。`ncalrpc` 目录来自编译期默认值，smbd 不会代为逐级创建，缺失时直接以 `Failed to create pipe directory` 退出；把它写进部署清单比运行期再加 `ncalrpc dir` 配置更少分叉。
- D-S2-11 TDB robust mutex 在本工具链组合下不可用（`mutexes requested but not available` 打印在 level 0），不回退到改源码或关日志。先用 fcntl 锁跑完隔离回归，把该项作为实机并发用例的显式检查点；如果实机上出现锁语义问题，再评估换锁实现或调整 build 参数，不在 S2 静默掩盖。
- D-S2-12 启动脚本固定导出 `LD_LIBRARY_PATH=<root>/lib:<root>/lib/private`，不依赖编译期 `RPATH`。实测 uClibc 0.9.33.2 不会用主程序的 `DT_RPATH` 去解析“依赖库的依赖”：只设默认时缺 `libsecrets3-private-samba.so`，只加 `lib/private` 时缺 `libhogweed.so.6`，两者都加才正常。因此不再为补齐 `RPATH` 重建或打补丁。
- D-S2-13 `libidmap-private-samba.so` 的两个未解析 winbind 符号按“调用不到”归档，不为此改源码、不补桩。处置是：不把 libidmap 及 `lib/idmap/*.so` 交付给 smbd 使用；若将来启用 winbindd 或需要 idmap 后端模块，必须在同一构建里同时产出 winbindd，否则 `lib/util/modules.c` 的 `RTLD_NOW` 会在加载时被这两个符号卡住。
- D-S2-14 实机验证采取“一次性运行、当场回滚”：验证结束即停实例并 `rm -rf /userdisk/data/samba-s2`，不在设备上留后台服务、开机项或残留树。理由是新实例对局域网开放访客写权限，长期驻留超出本阶段授权范围；证据以日志摘录入文档、完整日志留在仓库外，需要复跑时重新上传即可。

## S3（小米 MAC 策略适配）

- D-S3-01 采用内部窄补丁，不用 VFS 模块或外部策略接口。VFS 能挂到 `connect_fn`，但共享枚举（srvsvc `NetShareEnumAll`、SMB1 RAP `NetShareEnum`）直接读 `lp_services()`，不经过 VFS，单用 VFS 会漏掉“枚举”入口；外部策略接口要为每次连接/枚举加 IPC，并新增失败模式，与原厂“进程内 helper”不同层。补丁落在 `share_sanity_checks()`、`init_srv_share_info_ctr()` 与两个 RAP 循环，覆盖全部入口。
- D-S3-02 策略配置用环境变量（`XIAOMI_*`），不新增 loadparm 参数。理由：不扩 smb.conf 参数表、不改 `/etc/config/samba`，默认值直接对齐原厂路径；关闭/改路径只影响本进程，回滚简单。
- D-S3-03 MAC 缓存只缓存 IP→MAC（默认 60s），列表每次判定都重读文件。这样“改列表”立即生效，不需要等缓存过期；缓存只挡住“同一 IP 的重复 trafficd/arping 查询”。
- D-S3-04 列表比较用 `strcmp`（大小写敏感），MAC 统一转小写。原厂 `0x1ca140` 就是 `strcmp`，且 trafficd 输出大写、判定前转小写，所以列表写大写不会命中——照抄该行为，不用 `strequal` 的宽松匹配。
- D-S3-05 MAC 解析失败按“未命中”处理：只允许 browseable 共享，绝不授予 non-browseable 整盘。实现里失败分支不缓存失败结果，下次连接会重试。
- D-S3-06 `IPC$` 与 `snum < 0`（连接级）直接放行，对齐 `0x1cab08`。放行发生在列表/解析之前，避免枚举会话因取不到 MAC 被整体拒绝。
- D-S3-07 trafficd/arping helper 可用 `XIAOMI_TRAFFICD_CMD=none`、`XIAOMI_ARP_INTERFACE=none` 关闭；默认开启。测试里用“关掉 ARP 回退”证明 MAC 确实来自 trafficd，而不是 `/proc/net/arp` 偶然命中。
- D-S3-08 枚举过滤用 `xiaomi_mac_share_visible()` 原地替换 `lp_browseable()`，不新增第二层过滤。这样枚举与 tree connect 共用同一套判定，避免“枚举里看得到、连不上”或相反的分叉。
- D-S3-09 测试实例临时开 `server signing = no`、`map to guest = Bad User`、本地 passdb 用户 `nobody`、`log level = 5`。这些只是为了让 macOS/`smbprotocol` 客户端能完成认证并留下判定日志，不写进产品配置建议；正式部署仍用 S2 的配置基线。
- D-S3-10 设备部署复用 `/userdisk/data/samba-s2/root` 路径与 S2 的一次性回滚流程（D-S2-14），不新建第二套目录。部署包 14,513,779 B，解压后启动 1445，结束即删。
- D-S3-11 macOS Finder/`mount_smbfs` 非 445 端口挂载标 BLOCKED，不作为 S3 通过条件。证据是：URL 端口形式能连到本实例并协商到 SMB3_11，但客户端在 session setup 后被重置/挂起；`smbutil view -p`、`mount_smbfs -p` 均无端口选项，原厂占 445 且本轮不允许停原厂。等价入口用 SMB2/3 客户端（设备 `smbclient` + macOS `smbprotocol`）验证。
- D-S3-12 原厂撤销的实机对照标 BLOCKED：需要改写生产列表 `/tmp/loginMac.cfg` 或 `nonLoginMac.cfg`，超出本轮授权。改为代码级对照（原厂判定点同在 tree connect）+ 新实例实测“已连会话继续、新连接立即按新列表”。
- D-S3-13 测试期一次清理脚本用 `sbin/smbd -D` 匹配进程，误匹配原厂 `/usr/sbin/smbd -D`，导致原厂 smbd 被监督进程重启（PID 集合变化，配置/二进制未变）。如实记入 S3 文档，后续启停只匹配 `samba-s2/root/etc/s` 路径，不再用宽匹配。

## S4（摄像机 readonly 适配）

- D-S4-01 采用“只挂 `create_file`、删除上游 `readonly_connect`”的实现，不沿用 4.25.1 上游的 connect 语义。依据是原厂 `samba_multicall` 的 `vfs_fn_pointers` 表只有 `+0x50`（`create_file_fn`）非零，`connect_fn` 为空；上游在 connect 时置 `conn->read_only`，会让窗口内已有文件仍可读、新文件不可写，与实测原厂“窗口内纯读也 `ACCESS_DENIED`”不符。
- D-S4-02 不复用旧 VFS ABI 的二进制模块，也不把原厂 `readonly.so` 拷进新树。旧模块按 4.0.21 的 `vfs_fn_pointers` 布局注册（`smb_register_vfs(30, ...)`），在新版 VFS 结构下偏移不成立；改为在新版 `vfs_readonly.c` 源码内复刻同一语义。
- D-S4-03 `readonly:period` 的解析继续用 Samba 自带 `get_date()`（`date(1)` 语法），不自己写时间解析器。原厂就是 `get_date`，自写解析会在“畸形输入返回 -1 → 放行”这类边界上产生分叉；保留 `-1` 放行是与原厂一致的“失败开放”行为。
- D-S4-04 默认值保持 `"today 0:0:0"` / `"tomorrow 0:0:0"`，即“未配置 period = 全天拒绝”。这是原厂的默认数组（`0x42ac44`），不是本项目的选择；也正因为如此，误配或漏配 `vfs object` 时表现为整共享不可访问，而不是静默放开。
- D-S4-05 跨午夜不按“次日”特判，也不把 `today 06:00`→`tomorrow 02:00` 理解成“连续拒绝到次日 02:00”。原厂每次 open 都用“当天”重新求值：过零点后 `today 06:00` 又指向当天未来，`begin > now` 直接放行。因此该配置的实际拒绝段是每天 06:00–24:00，放行段是 00:00–06:00（共 6 小时），而不是“02:00–06:00 空档”。实测 01:30 放行、23:00 与 06:00 拒绝、05:59:59 放行，照此实现，不做“跨午夜自动加一天”的修正。
- D-S4-06 端点按闭区间（`begin <= now && now <= end`），与反汇编一致；不改成左闭右开。实测 06:00:00 与 04:00:00 均拒绝、05:59:59 与 04:00:01 均放行。
- D-S4-07 `conn->read_only` 为真时跳过钩子，交给核心的“共享只读”逻辑。原厂如此，实测 `read only = yes` + 活动窗口表现为“可读、不可写”，与窗口内普通共享的“全拒绝”不同；两者不能混为一谈。
- D-S4-08 加一个仅测试用的 `XIAOMI_READONLY_NOW`（epoch 秒）覆盖时间源。设备是生产路由器，不能改系统时钟做边界跳跃；不设该变量时走 `time(NULL)`，产品路径不受影响。真时钟单独跑了一轮，避免“只有假时钟”的验证漏洞。
- D-S4-09 原厂行为对照用“原厂二进制 + 独立第二实例（1446）”，不直接写生产相机共享。生产共享写入会产生真实文件、且 445 被原厂占用；第二实例用同一 `samba_multicall`、合成配置、独立 lock/pid/private/state/cache/ncalrpc，能拿到真实原厂代码路径又不触碰生产数据。测试共享设 `browseable = no` 是为了让 macOS 测试机通过原厂 `nonLoginMac.cfg` 策略，不修改生产 MAC 列表。
- D-S4-10 新版实例测试时设 `XIAOMI_MAC_FILTER=0`，把 S3 的 MAC 策略与 S4 的 readonly 语义解耦。理由：两个策略叠加会让“拒绝”无法归因；S3 已单独验证 MAC 策略，S4 只需回答 readonly 行为。该开关只是 S3 补丁提供的环境变量，不改默认值。
- D-S4-11 停止与清理只按 PID 文件（`kill $(cat var/run/smbd.pid)`）和精确目录（`/userdisk/data/samba-s2`、`/userdisk/data/s4vendor*`），不做任何 `pgrep -f smbd` / `pkill -f smbd` / 通配路径匹配。这是对 D-S3-13 事故的直接约束；本轮全程未出现原厂 PID 变化。
- D-S4-12 端口判断按“监听套接字 + PID”核对，不用“进程名出现 smbd”判断。核对项固定为：TCP 139/445 归属原厂 `smbd`、UDP 137/138 归属 `nmbd`、1445/1446 无残留、`/tmp/run/smbd.pid` 内容与 mtime 未变。
- D-S4-13 原厂隔离用“TDB mtime + 目录归属”双重核对，不只依赖配置里写了独立路径。本轮发现 `/tmp/lock/locking.tdb` 的 mtime 在测试期间变过一次，遂用第二次独立实例（`s4vendor2`）复测：前后 mtime 未变、实例自己 `lock/` 下生成了 `locking.tdb`/`brlock.tdb`/`serverid.tdb`，确认变化来自原厂自身相机访问流量，不是串写。
- D-S4-14 S3 的三个 BLOCKED 在 S4 的处置：Finder/`mount_smbfs` 非 445 仍 BLOCKED，S4 不依赖（create 语义用 `smbprotocol` 在 1445 覆盖）；原厂撤销实机对照不适用于 S4（readonly 无撤销逻辑）；IPv6 与 SMB1 RAP 不适用于判定路径（`create_file` 协议无关，SMB1 已实测，RAP 浏览不经该钩子）。三项均未绕过，均写明理由。
- D-S4-15 真实摄像机接入标 BLOCKED，不用“配置正确/`testparm` 通过”冒充。原因：无设备；摄像机通常固定 445，而本轮禁止停原厂。兼容性差异只记录到能实测的层面（SMB1/SMB2/SMB3.1.1 文件客户端、中文名、200/260 字节路径），摄像机固件的认证与路径拼接行为保持“未验证”。

## S5（小米管理与服务生命周期）

- D-S5-01 新版生命周期不复用原厂 `shareUpdate`、`/etc/init.d/samba`、`supervisord`。静态与运行证据表明它们会写 `/etc/config/samba`、生成 `/var/etc/smb.conf`、调用原厂 `smbcontrol`，还会重启 MiniDLNA 并给电视发信号；任何一条都违反本轮约束。适配器只做“UCI 只读 → 新版配置 → 自己的实例”。
- D-S5-02 UCI 读取一律用 `uci -c <dir>` 指向 shadow 目录（本轮为 `/userdisk/data/samba-s5/uci` 的只读复制）。这样能真实复现 App 写入后的配置形态，又不碰 `/etc/config/samba`；测试结束核对其 md5 未变。
- D-S5-03 配置采纳分三道：渲染规则校验、4.25.1 `testparm`、隔离路径/端口检查；相机共享额外检查 `lib/vfs/readonly.so` 存在。任一失败返回 3 并保留旧 `smb.conf`（字节不变）与 last-good，同时把诊断写进 `var/log/adapter.log`。只做 `testparm` 不够：它不加载 VFS 模块，模块缺失时配置会“通过”但行为退化。
- D-S5-04 S5 只负责把 `misc.smb_ctl.limit/start_time/end_time` 渲染为 `vfs object = readonly` 与 `readonly:period`，不复制 S4 的时间判断。拒绝仍由 S4 的 `create_file` 钩子执行；因此 S4 的“06:00–24:00 拒绝”语义与本阶段的共享级 `read_only` 互不影响。实测 deny/allow 两态与 S4 文档一致。
- D-S5-05 4.0.21 的 `socket options`、`write cache size`、`default cpumask` 在 4.25.1 中不可用或已移除（`SO_SNDBUFFORCE` 被 uClibc 拒绝），适配器不再输出，只保留 `smb2 max read/write/trans`。不把被忽略的参数写进配置冒充“已迁移”，性能调优留到后续阶段重新测量。
- D-S5-06 新版进程用 `sbin/samba-s5d` 的**真实副本**启动，不用符号链接。实测：符号链接时 `pidof smbd` 会包含新版 PID（busybox 按 `/proc/<pid>/exe` 解析后的基名匹配），原厂 init 的 start 还会把这些 PID 写进 samba cgroup；换成真实副本后 `pidof smbd` 只返回原厂进程。
- D-S5-07 停止只读自己的 PID 文件，并校验 `/proc/<pid>/exe` 在 `ROOT/sbin/` 下才发信号；死 PID 只清文件，活的外来 PID 返回 4 且不杀。全程没有 `pidof`/`pkill`/`killall`/宽匹配。这是 S3 事故后的硬约束。
- D-S5-08 `reload` 只允许“新版 `smbcontrol` + 新版自己的配置”。实测旧版 `smbcontrol` 指向新版实例会把实例杀掉且自身返回 0；新版指向旧版返回 1 且旧实例存活。两代消息协议不可交叉，管理链路里不得混用。
- D-S5-09 启动前用 `smbd -b` 的 `SBINDIR` 校验编译前缀与 `ROOT` 一致（允许符号链接映射后解析相等）。当前树编译在 `/userdisk/data/samba-s2/root`，错位部署会出现“能启动但 VFS/auth 模块找不到”的半失效状态，因此直接拒绝；重定位推迟到后续阶段。
- D-S5-10 真实磁盘插拔标 BLOCKED：`/extdisks/sdb1` 是生产盘，不允许拔。改用“共享路径不存在”验证共享级降级——生成/启动正常，目标共享 `BAD_NETWORK_NAME`，其他共享不受影响；这不等价于热插拔，不冒充。
- D-S5-11 MiniDLNA 重启与电视通知标 BLOCKED：设备上 MiniDLNA 未运行、无电视。适配器不调用 `init.d`、不碰 `/etc/config/minidlna`；清理后其配置与 `/tmp/minidlna.conf` mtime 仍为 2018-10-16。替换后是否需要保留原厂这条共用链路，留待产品决定。
- D-S5-12 `supervisord`/`TaskMonitorServer` 的停止匹配规则标 BLOCKED：验证它需要执行 `supervisord stop`，会停掉原厂 smbd。已用 `pidof` 实验证明名字层必须去重，并用真实副本规避；监控服务内部匹配逻辑未验证，替换时必须重测。
- D-S5-13 App/管理界面层标 BLOCKED：没有调用 App，验证的是“UCI 变化 → 新版配置 → 实际行为”。App 写入、manifest `status` 门控、`shareUpdate` 的 flock/重入不在本轮结论内。
- D-S5-14 S3/S4 遗留项（Finder/`mount_smbfs` 非 445、真实摄像机、原厂撤销对照、IPv6/SMB1 RAP、系统时间跳变与长连接）不参与 S5 的生成/启停判定，与本阶段判定无关，未重新测试；不把“无关”写成“已通过”。
- D-S5-15 适配器实现中曾用 `[][\r\n]` 判非法共享名，busybox grep 把 `r`/`n` 也当字符，误拒 `S5Missing`；改为只拒绝方括号后复测通过。`adapter.log` 中 03:26:00 的 `reject share name: S5Missing` 是已修复缺陷的残留证据，最终结论以修复后为准。
- D-S5-16 本轮测试结束后按 PID 文件和精确目录清理；原厂 `samba_multicall`/`/etc/config/samba`/`/var/etc/smb.conf`/模板 md5、139/445/137/138 归属、smbd 1448 与 nmbd 8469、根分区可用量均与动手前一致。



## S6（实机受控实验）

- D-S6-01 没有备用同型号设备，本轮在生产路由器上做“独立目录 + 非标准端口 1445”的受控实验：不停止、不替换、不改写原厂 4.0.21，端口归属与配置保持不变；真正的切换、停原厂和回滚全部留给 S7。这是对计划“优先备用设备”的现实替代，不把受控实验当成上线。
- D-S6-02 部署树用 S3 完整安装树叠加 S4 的 `lib/vfs/readonly.so`。S4 的 prefix 树缺少 `libgnutls.so.30` 等依赖，单独打包会让 `testparm`/`smbd` 直接失败；S6 因此显式组合并在部署后核对 `readonly.so` md5 `83e70d25…`。
- D-S6-03 编译前缀仍是 `/userdisk/data/samba-s2/root`。S6 用临时符号链接 `samba-s2 -> samba-s6` 映射，适配器启动前用 `smbd -b` 的 `SBINDIR` 加 `readlink -f` 校验；不重编译、不改 `SBINDIR`，避免出现“能启动但模块找不到”的半失效状态。
- D-S6-04 内核兼容结论按实测记录：`getrandom`、`renameat2`、`memfd_create`、`copy_file_range` 在 2.6.36 上为 ENOSYS；`/dev/urandom`、epoll/eventfd/timerfd/signalfd/inotify、accept4、splice、sendfile、posix_fallocate、fcntl/flock、futimens 均可用。robust mutex 在 uClibc 头文件层就不可用，继续使用 fcntl 锁并接受日志中的 `mutexes requested but not available`；未观察到功能失败。
- D-S6-05 S6 的 UCI 是 `/etc/config` 的只读复制，随后在复制件里删除生产共享、只保留 `S6rw`/`S6ro`/`S6摄像机` 三个合成共享。理由：1445 上不应暴露 `/userdisk/data` 等生产路径；功能语义已由 S3–S5 覆盖，S6 只需内核/性能/资源结论。原厂 `/etc/config/samba` 全程只读，清理后 md5 未变。
- D-S6-06 客户端矩阵在测试进程上设 `XIAOMI_MAC_FILTER=0`，把 S3 的 MAC 策略与 S6 的协议/性能解耦。默认开启时 macOS 会话被 `STATUS_ACCESS_DENIED` 拒绝，说明策略仍生效；S6 不据此判断客户端兼容性，也不修改生产 MAC 列表。
- D-S6-07 签名行为按实测记录：`server signing = default` 下认证会话实际要求签名；访客会话不能签名，smbprotocol 以 `require_signing=False` 连接会被拒绝。A/B 用同一认证用户、同一热缓存：未签名 40.2–45.8 MB/s，签名 19.6–22.0 MB/s，签名成本约 50%。不把“default”理解为“不要求签名”。
- D-S6-08 加密用 `server smb encrypt = required` 加 `smb encrypt = required` 两处同时设置才生效；仅设置 share 级时客户端报 “server doesn't support SMB3 encryption”。加密单流 3.7–3.8 MB/s，`user` CPU 约 1.3 核，属 CPU 受限；保持默认 `smb encrypt = disabled`，加密作为可选能力记录，不作为 S6 默认配置。
- D-S6-09 原厂 445 吞吐基线标 BLOCKED：访客 SMB1 tree connect 返回 `NT_STATUS_ACCESS_DENIED`，MAC/凭据门控；SMB2 访客无法签名；没有既有账号口令。没有用“本机回环”或“新建原厂账号”替代。性能阈值改按 100Mbps 线速和 2 核/248MB 余量制定：远端单流 ≥ 8 MB/s、签名单流 CPU ≤ 50%、加密 ≤ 70%、空闲 RSS ≤ 32 MB、管理界面 p95 < 200 ms、根分区可用空间不减少。
- D-S6-10 吞吐以 smbclient 自身报告的纯传输值为准，不把设备侧客户端约 4 s 的初始化算进去；远端 macOS 数字用 smbprotocol 端到端测量。实测远端 10.7–11.4 MB/s（约 91–97% 线速），本机未签名 40–46 MB/s、签名 SMB2 20–22 MB/s、SMB3 加密 3.7–3.8 MB/s、写 32 MB/s、4 并发聚合 31–48 MB/s。
- D-S6-11 资源以实测记录：新实例空闲 RSS 11.0 MB（父 4.6 + notifyd 3.2 + cleanupd 3.2），原厂 4.5 MB；空闲 CPU 均 1.3%。4 并发峰值 RSS 73.2 MB，16 并发 16/16 成功、峰值 51.9 MB；空闲 60 s 日志零增长，16 次连接增长 4800 B。RSS 求和会重复计算共享库，报告里明确是 RSS 而非 PSS。
- D-S6-12 失败诊断按“精确杀子进程”做：4 路并发中 `kill -9` 一个连接子进程，该客户端断开，其余 3 路完成，父进程存活、新连接可用。配置拒绝用相对路径共享复测：`generate` 返回 3，`smb.conf` md5 不变；只读共享和相机时间窗均为真实拒绝并在日志中给出原因。
- D-S6-13 持久化只验证“写入 → stop → start → 读回”，md5 一致；设备重启持久性标 BLOCKED，因为重启生产路由器会中断联网和管理，不符合本轮约束。`/userdisk` 是 ubifs、`/userdisk/data` 是 ext4，测试文件只落在 ext4 合成目录。
- D-S6-14 遗留 BLOCKED 逐项处置：Finder/`mount_smbfs` 非 445 仍 BLOCKED（`smbutil` 报 socket 未连接、`mount_smbfs` 挂起且未挂载）；原厂撤销对照 BLOCKED（需改原厂 MAC/配置）；IPv6 BLOCKED（`br-lan` 只有 fe80 链路本地，无全局地址）；SMB1 RAP BLOCKED（无真实 RAP 客户端）；真实摄像机 BLOCKED（无硬件）；Emby 非标端口 BLOCKED（设备上无 Emby 进程）；MiniDLNA/电视通知、USB 热插拔、supervisord 匹配、App 集成沿用 S5 的 BLOCKED，不以近似场景代替。跨版本 `smbcontrol` 继续规避，不做跨版本调用。
- D-S6-15 清理只按 PID 文件与精确路径：stop 校验 `/proc/<pid>/exe` 在 `ROOT/sbin/` 下，随后删除 `/userdisk/data/samba-s6`、`/userdisk/data/s6`、`samba-s2` 符号链接、`共享/s6perf.bin` 硬链接及 `/tmp/s6*` 临时文件；未用 `pidof`/`pkill`/通配杀进程。核对：四个原厂 md5 不变、139/445 仍为 1448、137/138 仍为 8469、`pidof smbd` 仍为 `26994 1448`、根分区可用 20588 KB 不变、1445 无监听、无测试进程与目录。
- D-S6-16 S6 开始时 `/etc/config/samba` 的 md5 是 `8556a19b…`，与 S5 记录的 `244eb53e…` 不同，mtime 为 11-08 05:05，早于本轮开始（12:45），期间未再变化。该差异属外部改动，不归因于 S6，也不回滚它；S6 的恢复基线以本轮动手前状态为准。
