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


