# S8 候选发布清单

日期：2026-11-09。状态：**1.0.7-r2d 已实机安装并运行，未签名，不对外发布**。
1.0.7 由 1.0.6 派生，Samba 载荷字节不变，只更新兼容层（访客网 SMB 拦截与自愈）。
发布流程本身沿用 1.0.3 时代的结构；本文只把过期数据换成 1.0.7 的实测值，取不到的标注“未记录/待补”。

## 1. 版本与目标

| 项 | 值 |
| --- | --- |
| 上游 | Samba 4.25.1 |
| 发布版本 | `1.0.7-r2d`（包 `miwifi-smb-1.0.7-r2d.tar.gz`，14 308 996 B，SHA-256 `38c0cb1c14bedb88368a3d66172caca1e2430234a2fe534fe6324298e603fbf0`，MD5 `02f6918e9bef88743dc78d7519a2ca7b`；已实机安装） |
| 与上一版差异 | 仅兼容层：`xiaomi-smb-adapter.sh`（新增 `br-guest` 的 TCP 139/445 无条件 DROP）、`diskacl-sync.sh`（每分钟健康检查与自愈）、`README-INSTALL.txt`；`payload/samba-tree.tar.gz` 字节不变（SHA-256 `0101e0a7d786c5b6ca5740720ff03cb6ba48ce0d45dd5473f54318f2e6eb2d58`，MD5 `0f6001010c84a016cd46f129dbe47388`） |
| 源码 SHA-256 | `7f367545bca69aa96897628f82f0f04d4b66b3bcb36cb978b9bb952c4b4c428d`（43 590 836 B，`.tar.asc` 已用上游公钥验签） |
| 目标设备 | 小米路由器 R2D，ROM 2.25.209，Linux 2.6.36 / uClibc 0.9.33.2 / ARMv7 soft-float |
| 设备端安装前缀 | `current -> /userdisk/data/s7root/versions/1.0.7-r2d/root`（2026-11-09 03:09 安装）；兼容层 `s8compat/current -> versions/v1` |
| 版本标识 | 版本目录内只有 `root/`；包内 `VERSION` 不随载荷安装，设备侧以版本目录名与 `state/1.0.7-r2d.md5`（载荷 tar 的 MD5）识别 |
| 运行态 | 独立树、独立 PID/锁/状态/日志；`samba-s5d` 监听 `192.168.3.2:139,445`，不覆盖 `/usr/sbin/samba_multicall` |
| 适配器 | `recipes/samba/xiaomi-smb-adapter.sh`（设备 `versions/v1` 副本 MD5 `00ca962470ad328081dc98fd0219f5af`） |
| 同步脚本 | `recipes/samba/s8-compat/diskacl-sync.sh`（设备副本 MD5 `2a00da5e6c6288629d7e5c7436d62692`，cron 每分钟） |

## 2. 构建环境

| 组件 | 版本/配置 |
| --- | --- |
| 工具链 | 小米官方 SDK `arm-xiaomi-linux-uclibcgnueabi`，GCC 4.8.2 (crosstool-NG 1.19.0) |
| 宿主 | linux/amd64 容器；工具链挂载 `/toolchain`，工作树 `/work` |
| configure 前缀 | `--prefix=/opt/samba-next --libdir=/opt/samba-next/lib`（部署时整树搬到版本目录） |
| 编译参数 | `-Os -fPIC -march=armv7-a -mfloat-abi=soft` |
| 关键开关 | `--disable-python --without-ad-dc --without-ads --without-ldap --without-pam --without-winbind --without-gpgme --without-regedit --without-systemd --bundled-libraries=ALL --disable-warnings-as-errors` |

`1.0.7-r2d` 未重新编译 Samba，直接复用 1.0.6 的载荷；构建参数与产物见 [S1 干净构建记录](s1-clean-build.md)。

## 3. 依赖与许可证

| 依赖 | 版本 | 归档 SHA-256 |
| --- | --- | --- |
| zlib | 1.4 | `4f11c512053d7bab8d9e9b89bde3575add3e4c50a383b42ef6cb837035fc5a7c` |
| GMP | 6.3.0 | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |
| Nettle | 3.10.2 | `fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5` |
| GnuTLS | 3.8.13 | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` |

许可证与再分发边界见 [THIRD_PARTY.md](../THIRD_PARTY.md)。厂商工具链与厂商二进制不随仓库分发。

## 4. 补丁

| 补丁 | 作用 |
| --- | --- |
| `samba-cross-asn1-rule.patch` | 交叉构建下 asn1 规则的执行方式 |
| `samba-cross-codegen-executor.patch` | codegen 包装器使用 `SAMBA_CODEGEN_EXECUTOR` |
| `samba-sdk-generic-selection.patch` | 旧 GCC 下 `charset.h` 的泛型选择 |
| `samba-sdk-reflink-guard.patch` | `replace.c` 的 reflink 能力保护 |
| `samba-sdk-spawn.patch` | `sdk_spawn.h` / `local_np.c` / `queue_process.c` 进程创建适配 |
| `gnutls-sdk-thread-local.patch` | 仅作用于 GnuTLS 源码，不在 Samba 树内 |

补丁集合与 1.0.6 相同；1.0.7 未改 Samba 源码。

## 5. 发布产物与散列

| 产物 | 大小 | MD5 | SHA-256 |
| --- | --- | --- | --- |
| `miwifi-smb-1.0.7-r2d.tar.gz`（当前交付，已实机安装） | 14 308 996 B | `02f6918e9bef88743dc78d7519a2ca7b`（本地与设备一致） | `38c0cb1c14bedb88368a3d66172caca1e2430234a2fe534fe6324298e603fbf0` |
| `payload/samba-tree.tar.gz` | 14 397 433 B | `0f6001010c84a016cd46f129dbe47388`（设备 `state/1.0.7-r2d.md5` 同值） | `0101e0a7d786c5b6ca5740720ff03cb6ba48ce0d45dd5473f54318f2e6eb2d58` |
| `miwifi-smb-1.0.6-r2d.tar.gz`（回滚用，仅本地保留） | 14 307 338 B | `b19d355c8f5c1fa0f3f67e542b15876d` | `f2285da6cb6c236cf6ea9c8754c62e3788e88f8acbeb2af005bb3d4401b372c1` |
| `<root>/sbin/smbd` | 81 546 B | `52e105576e190ab6b977be419b3144fe` | 设备无 sha256sum，未记录 |
| `<root>/sbin/samba-s5d` | 81 546 B | `52e105576e190ab6b977be419b3144fe` | 由适配器首次 start 时从 `smbd` 复制生成 |
| `<root>/sbin/nmbd` | 253 126 B | `2283bda9f01dfa719ad276af28b655a0` | 设备无 sha256sum，未记录 |
| `compat/xiaomi-smb-adapter.sh` | 44 433 B | `00ca962470ad328081dc98fd0219f5af` | `dae67b6ecbbf02faf5a5625153e2c2d13b737ca58483dd1f8e7a04e66c3efac9` |
| `compat/diskacl-sync.sh` | 4 274 B | `2a00da5e6c6288629d7e5c7436d62692` | `53ffbf6d568c84fe83d21f5906934a0d8d342d4c5f9207ef1ebd98279723ef0c` |
| `compat/hook.sh` | 2 143 B | `19fa4ad37729cf4d663d06f0a77d493f` | `7a455c2d9c4860d48ffc2a7796652cc7210530af308fa109f6c2461dba4da989` |
| `compat/samba.init.wrapper` | 2 145 B | `03e596af3763e1164b5426cfe56fa25d` | `e21a1f1ef23baefce8138a09cd35f0159150300a2f80dc969ff646011804ec97` |
| `compat/install.sh` | 7 146 B | `46c8350493d7382dcd43a1c45527746c` | `907022c1d29c98f3d279a7fc77e2e5cdec8cdab26995a214c24ea4351afa4814` |
| `compat/90-s8-mounts` | 995 B | `861b98d819203e239228478f52fb8a5f` | `2d579477336ca52905d2b0656e6cb0ae15143b8ab55c225a704fc48cf66bc944` |
| `install-release.sh` | 5 263 B | `90644f0f18e6df24aad5079ca75fefd2` | `6bd05049962118469a3c3ff09ee4173073fffc679d34b33af6ac0bd4f9fcc9e6` |
| `xiaomi-smb-install.sh` | 8 761 B | `11b16106a9f7a610503883f4f46dbefe` | `8b5d928e0ddc7fe7fa9683600ae1bcc83348427b3e5f4ad2e86e8b2eb0c9cd58` |

设备端无 `sha256sum`，设备侧只核对 MD5；SHA-256 以仓库内文件为准。兼容层 `MANIFEST`
已于 2026-11-09 阶段 5 在设备上 `md5sum -c` 核对 4/4 通过（`xiaomi-smb-adapter.sh`、`diskacl-sync.sh`、
`hook.sh`、`samba.init.wrapper`），并与仓库副本一致；该结果只覆盖兼容层文件，不等于整棵运行树校验通过。
证据：`docs/evidence/2026-11-09-stage4/cross-check.txt`。

## 6. 客户端与设备矩阵（已知）

| 客户端 | 协议 | 结果 |
| --- | --- | --- |
| macOS Finder / `mount_smbfs` | SMB 3.1.1 | 枚举、挂载、列目录、卸载通过（1445 与 445 两种模式） |
| `smbtorture` 基础套件 | SMB1/2/3 | S2/S6 记录通过项见 [S2](s2-isolated-regression.md)、[S6 实机](s6-device-test.md) |
| Linux `smbclient` | SMB2/3 | 合成读写、签名、加密通过 |
| 真实摄像机 | SMB1/固定 445 | **未验证** |
| Emby | 非标端口 | **未验证** |
| 访客网客户端 | SMB | **BLOCKED**（本机无法创建访客 BSS，详见 §10） |

## 7. 资源观测（摘要）

- 远端顺序读达 100 Mbps 线速的 91–97%；签名约 50% 成本，加密约一个数量级。
- 空闲 CPU/内存接近原厂；根分区可用 20 588 KB 不变。
- 连接子进程故障隔离、配置损坏保留 last-good 已验证。

## 8. 验证方式

```sh
# 1. 散列（设备端）
md5sum <root>/sbin/samba-s5d                        # 52e105576e190ab6b977be419b3144fe
md5sum /userdisk/data/s8compat/versions/v1/xiaomi-smb-adapter.sh   # 00ca962470ad328081dc98fd0219f5af
md5sum /userdisk/data/s8compat/versions/v1/diskacl-sync.sh         # 2a00da5e6c6288629d7e5c7436d62692
md5sum /userdisk/data/release/miwifi-smb-1.0.7-r2d.tar.gz           # 02f6918e9bef88743dc78d7519a2ca7b

# 2. 二进制版本（必须带上私有库路径）
LD_LIBRARY_PATH=<root>/lib:<root>/lib/private <root>/sbin/samba-s5d --version

# 3. 隔离与配置
./xiaomi-smb-adapter.sh -r <root> check      # isolation=OK, config_drift=no

# 4. 实例与磁盘访问状态（生产用 139/445，不是默认 1445）
./xiaomi-smb-adapter.sh -r <root> -p "139 445" status
./xiaomi-smb-adapter.sh -r <root> diskacl-status
```

`status` 退出码：0 运行、1 degraded、3 未运行、4 PID 文件异常/不属于本树、5 端口被其它进程占用。
`diskacl-status` 应给出 `chain=present jumps=2 legacy_chain=absent guest=enforced`。

## 9. 安装 / 升级 / 卸载 / 回滚

- 安装与升级：`install-release.sh upgrade`（版本目录 + 激活链接 + 编译前缀断言 + 幂等），底层调用 `xiaomi-smb-install.sh`。
- 版本号：包名与 `VERSION` 使用 `<semver>-r2d`，版本目录名与之一致；同版本号不同字节禁止复用。
- 已测升级链：`1.0.1→1.0.2→1.0.3→1.0.4→1.0.6→1.0.7`，其中 1.0.6→1.0.7 是就地升级，`/etc/config/samba` 未改、UCI 段未重写、兼容层仍为 `versions/v1`。
- 卸载：`xiaomi-smb-install.sh uninstall`，保留 `/etc/config` 与原厂二进制。
- **回滚（现状已变化）**：2026-11-09 清理后，设备只保留现役 1.0.7；`state/previous` 已删除，旧版本目录与 `release/` 旧包均已移除。因此 `install-release.sh rollback` 与 `xiaomi-smb-install.sh rollback` 会直接返回 6（`no previous version recorded`），不会切换 `current`。**当前回滚 = 从本地 `s8-release/miwifi-smb-1.0.6-r2d.tar.gz` 重新上传并安装**（哈希见 §5），再用 `activate` 指回。
- 原厂回退：`/userdisk/data/s8compat/install.sh rollback`（停止新版 → `current -> v0-vendor` → 原厂 init 全链路）。原厂哈希基线见 [S7](s7-switch-rollback.md)。
- 139/445 接管：开机与 App 入口由兼容层负责，见 [S8 替换与接管](s8-taskmonitor-replacement.md)；手动演练仍可用 `adapter vendor-stop` → `adapter -P -p "139 445" start`。

## 10. 已知限制与阻断

| 项 | 状态 |
| --- | --- |
| 按设备磁盘访问（`macfilter.lan`） | **已生效**：`s8-diskacl` 8 条 DROP + `RETURN`，两条 INPUT 跳转；`yes→no` 约 10 秒、`no→yes` cron 约 22 秒（上限 60 秒），见 [diskacl.md](diskacl.md) |
| 访客网 SMB（TCP 139/445） | **规则已强制**：`-i br-guest -p tcp -m multiport --dports 139,445 -j DROP` 位于原厂无接口限定 ACCEPT 之前；删除后 cron 约 50 秒重建。**端到端未验证（BLOCKED）**：Broadcom 驱动 `WLC_SET_VAR(bss)` 失败，`wl1.2` 无法创建，`br-guest` 无成员 |
| 访客 UDP 137/138 | 由原厂 `zone_guest` 拒绝，本项目未重复添加规则 |
| 1.0.7 安装后整机冷启动 | **已验证（2026-11-09 阶段 4）**：重启后 139/445 归 `samba-s5d`；链 8 DROP + RETURN；访客 DROP 位次不变；cron 行持久；22/80 可达。证据 `docs/evidence/2026-11-09-stage4/post-reboot-check.txt` |
| 回滚目标 | **已恢复**：`state/previous=1.0.6-r2d`，`versions/1.0.6-r2d/root/sbin/smbd` 可执行；1.0.7 树同时保留（见 §9） |
| 设备重启后的 139/445 归属 | **已验证（2026-11-09 阶段 4）**：冷启动后仍为 `samba-s5d` 监听；137/138 同时切到私有 `nmbd` 4.25.1 并在冷启动后保持 |
| 已有挂载的 USB 共享识别 | 1.0.6 时代已修（挂载派生层 + `90-s8-mounts`），1.0.7 载荷未变，未重跑 |
| 真实 USB 热插拔 | 1.0.6 时代已通过（单口设备 + SanDisk 128 G 双分区）；1.0.7 未重跑 |
| 固件 OTA 覆盖适配路径 | BLOCKED（2.24.11 rootfs 无 SSH 服务端，会自我锁死） |
| 真实跨版本升级 | 已实测包内升级；设备不在真实旧固件上，不涉及固件侧升级 |
| 真实摄像机 | BLOCKED（无设备） |
| Emby 非标端口 | BLOCKED（语义未知） |
| 原厂 445 吞吐基线 / 原厂撤销对照 | BLOCKED（MAC/凭据门控） |
| IPv6 | 二进制支持；生产未启用，设备只有 link-local。`s8-diskacl` 与访客规则均为 IPv4 `iptables`，未覆盖 IPv6 |
| 发布签名 | 未完成（无密钥与签名流程）；明确列为发布前置条件 |
| 干净环境复建 | 1.0.6 时代已完成：A `1049 s` / B `1077 s`，`smbd`/`nmbd` 与设备一致；1.0.7 仅兼容层变化，未重新构建 |

## 11. RC 门槛（1.0.7）

- [x] 1.0.7-r2d 实机安装：`current -> versions/1.0.7-r2d/root`，`samba restart` 后 pid 迁移、139/445 仍归 `samba-s5d`
- [x] 磁盘访问链未退化：8 DROP + 1 RETURN，`jumps=2`，`legacy_chain=absent`
- [x] 访客规则位置正确：`br-guest` DROP 在原厂 ACCEPT 之前；`guest=enforced`
- [x] cron 自愈：手动删除访客规则后约 50 秒恢复
- [x] 离线回归：32 cases / 135 assertions / 0 failures（sh、dash、busybox 1.36、设备 busybox 1.19.4）
- [x] 发布包散列：设备 tar MD5 与本地一致；`install-release.sh verify` 通过
- [ ] 访客端到端（真实访客客户端访问 139/445 被拒）
- [x] 1.0.7 安装后整机冷启动（2026-11-09 阶段 4，含 139/445、链、访客位次、cron、22/80 核对）
- [ ] 签名与验证链
- [ ] 真实 App/云端、OTA、摄像机、Emby 场景

证据索引：[docs/evidence/2026-11-09-diskacl/](evidence/2026-11-09-diskacl/)；逐项设计见 [decisions.md](decisions.md) D-S9-01…11。
