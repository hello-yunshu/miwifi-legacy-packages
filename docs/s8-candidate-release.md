# S8 候选发布清单（draft）

日期：2026-11-08。状态：**release-candidate 草案，未签名、未做本轮干净环境复建**。不对外发布。

## 1. 版本与目标

| 项 | 值 |
| --- | --- |
| 上游 | Samba 4.25.1 |
| 源码 SHA-256 | `7f367545bca69aa96897628f82f0f04d4b66b3bcb36cb978b9bb952c4b4c428d`（43 590 836 B，`.tar.asc` 已用上游公钥验签） |
| 目标设备 | 小米路由器 R2D，ROM 2.25.209，Linux 2.6.36 / uClibc 0.9.33.2 / ARMv7 soft-float |
| 设备端安装前缀 | 版本树 `/userdisk/data/s7root/versions/v1/root`，激活链接 `/userdisk/data/samba-s2/root` |
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

| 产物 | 大小 | MD5 |
| --- | --- | --- |
| `<root>/sbin/samba-s5d` | 81 546 B | `52e105576e190ab6b977be419b3144fe` |
| `<root>/sbin/nmbd` | 253 126 B | `2283bda9f01dfa719ad276af28b655a0` |
| `xiaomi-smb-adapter.sh` | 23 607 B | `a23af66bfa3a9a355ebd2b5972b7fa72` |
| `xiaomi-smb-install.sh` | — | 见仓库提交（SHA-256 `8b72c98e…`） |

仓库内适配器 SHA-256：`c1248e9c88e3873d2c4492534d7c9881d3101f5d51af30715766f58e20a797b3`。

设备端无 `sha256sum`，只记录 MD5；发布包附 SHA-256 时以仓库内文件为准。

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
md5sum xiaomi-smb-adapter.sh        # a23af66bfa3a9a355ebd2b5972b7fa72

# 2. 二进制版本（必须带上私有库路径）
LD_LIBRARY_PATH=<root>/lib:<root>/lib/private <root>/sbin/samba-s5d --version

# 3. 隔离与配置
./xiaomi-smb-adapter.sh -r <root> check      # isolation=OK, config_drift=no

# 4. 实例状态
./xiaomi-smb-adapter.sh -r <root> -p 1445 status
```

`status` 退出码：0 运行、4 PID 文件异常、3 未运行。

## 9. 安装 / 升级 / 卸载 / 回滚

- 安装与升级：`recipes/samba/xiaomi-smb-install.sh`（版本目录 + 激活链接 + 编译前缀断言 + 幂等）。
- 卸载：`xiaomi-smb-install.sh uninstall`，保留 `/etc/config` 与原厂二进制。
- 回滚：`adapter stop` → `/etc/init.d/samba start`（或 `adapter vendor-start`）。原厂哈希基线见 [S7](s7-switch-rollback.md)。
- 139/445 接管：`adapter vendor-stop` → `adapter -P -p "139 445" start`；回滚 `adapter stop` → `adapter vendor-start`。TaskMonitor 协作细节见 [S8 共存研究](s8-taskmonitor-coexistence.md)。

## 10. 已知限制与阻断

| 项 | 状态 |
| --- | --- |
| 设备重启后的持久性与 445 归属 | BLOCKED（需授权重启） |
| 真实 USB 热插拔 | BLOCKED |
| 固件 OTA 覆盖适配路径 | BLOCKED |
| 真实跨版本升级 | BLOCKED |
| 真实摄像机 | BLOCKED（无设备） |
| Emby 非标端口 | BLOCKED（语义未知） |
| 原厂 445 吞吐基线 / 原厂撤销对照 | BLOCKED（MAC/凭据门控） |
| IPv6 | 未验证 |
| 发布签名 | 未完成（无密钥与签名流程） |
| 本轮干净环境复建 | 未完成（S1 已复建 4.25.1；本轮适配器改动未重跑全量构建） |

## 11. RC 门槛

- [x] 独立目录部署、哈希基线、可回滚
- [x] macOS SMB3 枚举/挂载（1445 与 445）
- [x] TaskMonitor 共存（注册/注销/自愈/445 协作接管）
- [x] 配置源漂移守卫
- [ ] 干净环境复建产物与本清单散列一致
- [ ] 签名与验证链
- [ ] 重启、OTA、USB、摄像机、Emby 场景
