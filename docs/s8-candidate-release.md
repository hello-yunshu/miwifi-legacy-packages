# S8 候选发布清单（draft）

日期：2026-11-08。状态：**release-candidate 草案，未签名**；本轮已完成干净环境复建（A/B 哈希一致）
与发布包 install/upgrade/rollback/uninstall 实机验证。不对外发布。

## 1. 版本与目标

| 项 | 值 |
| --- | --- |
| 上游 | Samba 4.25.1 |
| 发布版本 | `1.0.3-r2d`（包 `miwifi-smb-1.0.3-r2d.tar.gz`，SHA-256 `bbb6ff924c799f0b419d46e4e24e593deb2fd5a746c194f7c31c2dfa75131848`；已构建并已实机安装） |
| 源码 SHA-256 | `7f367545bca69aa96897628f82f0f04d4b66b3bcb36cb978b9bb952c4b4c428d`（43 590 836 B，`.tar.asc` 已用上游公钥验签） |
| 目标设备 | 小米路由器 R2D，ROM 2.25.209，Linux 2.6.36 / uClibc 0.9.33.2 / ARMv7 soft-float |
| 设备端安装前缀 | 设备当前 `versions/1.0.3-r2d/root`（2026-11-08 已安装，`previous=1.0.2-r2d`）；激活链接 `/userdisk/data/samba-s2/root` |
| 运行态 | 独立树、独立 PID/锁/状态/日志；不覆盖 `/usr/sbin/samba_multicall` |
| 适配器 | `recipes/samba/xiaomi-smb-adapter.sh` |

## 2. 构建环境

| 组件 | 版本/配置 |
| --- | --- |
| 工具链 | 小米官方 SDK `arm-xiaomi-linux-uclibcgnueabi`，GCC 4.8.2 (crosstool-NG 1.19.0) |
| 宿主 | linux/amd64 容器；工具链挂载 `/toolchain`，工作树 `/work` |
| configure 前缀 | `--prefix=/opt/samba-next --libdir=/opt/samba-next/lib`（部署时整树搬到版本目录） |
| 编译参数 | `-Os -fPIC -march=armv7-a -mfloat-abi=soft` |
| 关键开关 | `--disable-python --without-ad-dc --without-ads --without-ldap --without-pam --without-winbind --without-gpgme --without-regedit --without-systemd --bundled-libraries=ALL --disable-warnings-as-errors` |

完整参数与失败处置见 [S1 干净构建记录](s1-clean-build.md)。

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

## 5. 发布产物与散列

设备端可核对值（2026-11-08 15:3x）：

| 产物 | 大小 | MD5 | SHA-256（仓库内文件） |
| --- | --- | --- | --- |
| `miwifi-smb-1.0.3-r2d.tar.gz`（当前交付，已实机安装） | 14 299 319 B | `f305a1b94637afc8b4a9cd9b359d6c32` | `bbb6ff924c799f0b419d46e4e24e593deb2fd5a746c194f7c31c2dfa75131848` |
| `miwifi-smb-1.0.2-r2d.tar.gz`（**已作废/被 1.0.3-r2d 取代**） | 14 299 118 B | `bc10176f3d66aa9a412a4882f94f57e4` | `07d5eb5083bf3817e177b9135b0dfe32ddbeae6ed5014326cfeec593a5f037d3` |
| `miwifi-smb-1.0.1-r2d.tar.gz`（**已作废/被 1.0.2-r2d 取代**） | — | — | `cf4491148c47964619509a01865f25c0c8a1f5549c20181caf732d46ee8085ff` |
| `miwifi-smb-1.0.0-r2d.tar.gz`（**已作废/被取代**） | — | — | `ce4684b20472191da1debe647fe18f39b69ce78f578b31556affa61b5151fe9b` |
| `<root>/sbin/smbd` | 81 546 B | `52e105576e190ab6b977be419b3144fe` | 设备无 sha256sum，未记录 |
| `<root>/sbin/samba-s5d` | 81 546 B | `52e105576e190ab6b977be419b3144fe` | 由适配器在首次 start 时从 `smbd` 复制生成 |
| `<root>/sbin/nmbd` | 253 126 B | `2283bda9f01dfa719ad276af28b655a0` | 设备无 sha256sum，未记录 |
| `xiaomi-smb-adapter.sh` | 26 800 B | `f106c788052402fc4fb7dc2614543fd3` | `0357f7eb2c0aa48cfb9a5e10e83762b2a7d9193326e1551ef4b7e43609da2b42` |
| `s8-compat/hook.sh` | 2 143 B | `19fa4ad37729cf4d663d06f0a77d493f` | `7a455c2d9c4860d48ffc2a7796652cc7210530af308fa109f6c2461dba4da989` |
| `s8-compat/samba.init.wrapper` | 2 145 B | `03e596af3763e1164b5426cfe56fa25d` | `e21a1f1ef23baefce8138a09cd35f0159150300a2f80dc969ff646011804ec97` |
| `s8-compat/install.sh` | 5 544 B | `b5d4e0049500b8a2d68941339d893c6c` | `fff4f6b97cbd4e7c41353927293c1702e57374603f9d648be75f75e71fd1a191` |
| `s8-compat/90-s8-mounts` | 995 B | `861b98d819203e239228478f52fb8a5f` | `2d579477336ca52905d2b0656e6cb0ae15143b8ab55c225a704fc48cf66bc944` |
| `install-release.sh` | 4 683 B | `80e9fffe4216f76298a1e5d46508cfd4` | `821bef98863140b289cf7957f82bb7c66ceff47986cb4e546dd6c4871a9b8339` |

`smbd` 的 MD5 在 2026-11-08 的干净复建（A 构建）中与设备值一致；`samba-s5d` 是适配器
启动时从 `smbd` 复制出来的同内容文件，不是独立产物。

设备端无 `sha256sum`，只记录 MD5；发布包附 SHA-256 时以仓库内文件为准。

兼容层的 `MANIFEST` 只覆盖 `hook.sh`、`xiaomi-smb-adapter.sh`、`samba.init.wrapper` 三项，**不覆盖** `samba-s5d`、`nmbd` 与私有库；“`md5sum -c` 三项 OK”不能当作整棵运行树校验通过。

## 6. 客户端与设备矩阵（已知）

| 客户端 | 协议 | 结果 |
| --- | --- | --- |
| macOS Finder / `mount_smbfs` | SMB 3.1.1 | 枚举、挂载、列目录、卸载通过（1445 与 445 两种模式） |
| `smbtorture` 基础套件 | SMB1/2/3 | S2/S6 记录通过项见 [S2](s2-isolated-regression.md)、[S6 实机](s6-device-test.md) |
| Linux `smbclient` | SMB2/3 | 合成读写、签名、加密通过 |
| 真实摄像机 | SMB1/固定 445 | **未验证** |
| Emby | 非标端口 | **未验证** |

## 7. 资源观测（摘要）

- 远端顺序读达 100 Mbps 线速的 91–97%；签名约 50% 成本，加密约一个数量级。
- 空闲 CPU/内存接近原厂；根分区可用 20 588 KB 不变。
- 连接子进程故障隔离、配置损坏保留 last-good 已验证。

## 8. 验证方式

```sh
# 1. 散列
md5sum <root>/sbin/samba-s5d        # 52e105576e190ab6b977be419b3144fe
md5sum xiaomi-smb-adapter.sh        # f106c788052402fc4fb7dc2614543fd3

# 2. 二进制版本（必须带上私有库路径）
LD_LIBRARY_PATH=<root>/lib:<root>/lib/private <root>/sbin/samba-s5d --version

# 3. 隔离与配置
./xiaomi-smb-adapter.sh -r <root> check      # isolation=OK, config_drift=no

# 4. 实例状态
./xiaomi-smb-adapter.sh -r <root> -p 1445 status
```

`status` 退出码：0 运行、1 degraded、3 未运行、4 PID 文件异常/不属于本树、5 端口被其它进程占用。`stop` 在无 pidfile、stale PID 或正常 kill 后都会等待端口释放，仍占用返回 5（2026-11-08 审计修复）。

## 9. 安装 / 升级 / 卸载 / 回滚

- 安装与升级：`recipes/samba/xiaomi-smb-install.sh`（版本目录 + 激活链接 + 编译前缀断言 + 幂等）。
- 版本号：包名与 `VERSION` 使用 `<semver>-r2d`（如 `1.0.2-r2d`），版本目录名与之一致；同版本号不同字节禁止复用。
- 从 `1.0.1-r2d` 就地升级到 `1.0.2-r2d` 已验证：`/etc/config/samba` 未改、UCI 段未重写、hotplug 入口 md5 一致、兼容层仍为 `versions/v1`、`MANIFEST.md5` 校验通过。
- 卸载：`xiaomi-smb-install.sh uninstall`，保留 `/etc/config` 与原厂二进制。
- 回滚：`/userdisk/data/s8compat/install.sh rollback`（停止新版 → `current -> v0-vendor` → 原厂 init 全链路）。原厂哈希基线见 [S7](s7-switch-rollback.md)。
- 139/445 接管：开机与 App 入口由兼容层负责，见 [S8 替换与接管](s8-taskmonitor-replacement.md)；手动演练仍可用 `adapter vendor-stop` → `adapter -P -p "139 445" start`。

## 10. 已知限制与阻断

| 项 | 状态 |
| --- | --- |
| 设备重启后的持久性与 445 归属 | **已关闭**：两次重启后均为 `samba-s5d` 监听 139/445（6336、6377；审计复测 6861、6216，收尾 23809），**没有原厂 smbd 进程**（`/usr/sbin/smbd` 是 `samba_multicall` 的符号链接，判据为 cmdline + exe），见 [S8 替换与接管](s8-taskmonitor-replacement.md#62-两次重启结果) |
| 已有挂载的 USB 共享识别 | **已修**：`render()` 增加挂载派生层（读 `/proc/mounts` 的 `/extdisks/<dev>`，UCI 优先、幂等、不回写 UCI），新增 `/etc/hotplug.d/block/90-s8-mounts` 独立触发 reload；离线 14 用例/31 断言、设备 busybox 同样 0 失败，设备 live 模式 1 用例/5 断言合成 `[XiaoMi-usb0]`。证据见 [发布就绪复核](release-readiness-2026-11-08.md) §2.7 / 决策 D-S8-33、D-S8-34 |
| 真实 USB 热插拔 | **已通过**（2026-11-08，单口设备 + SanDisk Extreme Pro 128 G / Ventoy 双分区）：插入 5 s/5 s（≤15 s）、拔出 9.6 s（≤15 s）、重插 14 s（≤20 s，物理插入起 18 s）；`samba-s5d` pid 8906 三次事件未换；无重复段/悬空路径/半更新；六次 hotplug 均为 `90-s8-mounts` 幂等跟随、原厂 `shareUpdate` 实际生效。证据见 [发布就绪复核](release-readiness-2026-11-08.md) §2.7 / 决策 D-S8-38 |
| 固件 OTA 覆盖适配路径 | BLOCKED |
| 真实跨版本升级 | 已实测包内升级：1.0.0→1.0.1、1.0.1→1.0.2（`upgrade → rollback → install`，UCI 未变、hotplug/兼容层无漂移）；设备不在真实旧固件上，不涉及固件侧升级 |
| 真实摄像机 | BLOCKED（无设备） |
| Emby 非标端口 | BLOCKED（语义未知） |
| 原厂 445 吞吐基线 / 原厂撤销对照 | BLOCKED（MAC/凭据门控） |
| IPv6 | 已实测：二进制支持（测试实例 `interfaces = ::1`、1445 监听成功）；生产未启用，设备只有 link-local，无全局地址 |
| 发布签名 | 未完成（无密钥与签名流程）；明确列为发布前置条件 |
| 本轮干净环境复建 | 已完成：A `1049 s` / B `1077 s`，`smbd`、`smbclient`、`libsmbd-base-private-samba.so`、GnuTLS/nettle/gmp 哈希一致，`smbd`/`nmbd` 与设备一致（见 [发布就绪复核](release-readiness-2026-11-08.md) §1） |

## 11. RC 门槛

- [x] 独立目录部署、哈希基线、可回滚
- [x] macOS SMB3 枚举/挂载（1445 与 445）
- [x] TaskMonitor 替换边界（33–34 条动态清单、server 缺位实测、版本化兼容层、回滚）
- [x] 配置源漂移守卫（手动路径 fail-closed；hook 启动/重载记录后接受）
- [x] 重启后 139/445 归属（两次重启 + 审计复测）与 App 入口路径（入口级）
- [x] 干净环境复建产物与本清单散列一致（`smbd` `52e10557…`、`nmbd` `2283bda9…`，A/B 一致）
- [x] 真实 USB 拔插三阶段（插入/拔出/重插，单口设备 + SanDisk 128 G 双分区；见 §10）
- [ ] 签名与验证链
- [ ] 真实 App/云端、OTA、摄像机、Emby 场景

审计完成度与逐项证据见 [2026-11-08 审计](audit-2026-11-08.md)。
