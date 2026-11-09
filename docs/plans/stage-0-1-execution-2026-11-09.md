# 阶段 0/1 执行记录（2026-11-09）

- 目标设备：MiWiFi R2D / 固件 2.25.209
- 执行时间：2026-11-09 16:21–16:45（Asia/Shanghai）
- 授权：阶段 0 设备写入（恢复 1.0.6 树、实测 rollback、`samba restart` 级中断）已放行；阶段 1 只做下载、校验与环境确认
- 顺序：阶段 0 全部门禁通过后才进入阶段 1
- 证据目录：[docs/evidence/2026-11-09-stage0-rollback](../evidence/2026-11-09-stage0-rollback/)

## 1. 阶段 0：只读基线 + 回滚资产

### 1.1 本地包核对（装机前）

| 项 | 记录值 | 判定 |
|---|---|---|
| 包 | `/Users/yunshu/Documents/GitHub/s8-release/miwifi-smb-1.0.6-r2d.tar.gz` | 存在 |
| 体积 | 14 307 338 B | 与计划一致 |
| MD5 | `b19d355c8f5c1fa0f3f67e542b15876d` | 与计划一致 |
| SHA-256 | `f2285da6cb6c236cf6ea9c8754c62e3788e88f8acbeb2af005bb3d4401b372c1` | 与计划一致 |
| 包内载荷 `payload/samba-tree.tar.gz` MD5 | `0f6001010c84a016cd46f129dbe47388` | 与设备 `state/1.0.6-r2d.md5` 一致 |

上传后设备侧复算 `md5sum` 同为 `b19d355c8f5c1fa0f3f67e542b15876d`，体积 14 307 338 B。

### 1.2 装机前快照

文件：[pre-install-snapshot.txt](../evidence/2026-11-09-stage0-rollback/pre-install-snapshot.txt)

| 项 | 快照值 |
|---|---|
| `current` | `/userdisk/data/s7root/versions/1.0.7-r2d/root` |
| `versions/` | 只有 `1.0.7-r2d` |
| `state/previous` | 不存在（`rollback` 会返回 6） |
| `s8-diskacl` | 8 条 MAC DROP + 1 条 RETURN |
| INPUT 前五条 | LAN tcp 139/445 跳转、LAN udp 137/138 跳转、guest tcp 139/445 DROP、原厂 `22,80,135:139,445` ACCEPT、`delegate_input` |
| cron | `* * * * * /userdisk/data/s8compat/versions/v1/diskacl-sync.sh # s8-diskacl` |
| smbd | pid 1687，持有 139/445 |
| 容量 | `/userdisk/data` 446.0G 可用；`/` 20.1M 可用 |

### 1.3 恢复与两次激活

`install` 只建树不激活；随后停实例、`activate 1.0.6-r2d`、`activate 1.0.7-r2d`，完成一次真实前后切换。

设备侧同时把安装器更新为仓库当前版本（含回滚门禁），旧脚本备份在 `state/xiaomi-smb-install.sh.pre-gate.bak`。安装日志见 `state/install.log`（已记录 install/activate/rollback-target 三类条目）。

> 实施修正：`xiaomi-smb-install.sh install` 接受的是**树载荷** `payload/samba-tree.tar.gz`，不是整包 tar。计划 §4.1 的命令已按此改为先解包再安装载荷；整包仍需保留用于 `install-release.sh` 的兼容层流程。

### 1.4 实测 `rollback` 与切回

文件：[rollback-to-106.txt](../evidence/2026-11-09-stage0-rollback/rollback-to-106.txt)、[switch-back-107.txt](../evidence/2026-11-09-stage0-rollback/switch-back-107.txt)

| 判定项 | 实测 | 判定 |
|---|---|---|
| 1. `rollback` 返回 0 并打印目标 | rc=0，`rolled-back-to 1.0.6-r2d` | PASS |
| 2. 切换后指针 | `current -> versions/1.0.6-r2d/root`，`previous=1.0.7-r2d` | PASS |
| 3. 1.0.6 树可执行且前缀可解析 | `sbin/smbd`、`bin/testparm` 可执行；`smbd -b` → `/userdisk/data/samba-s2/root/sbin` | PASS |
| 4. 1.0.6 实际运行 | pid 12734 持 139/445；`diskacl-status`：`chain=present jumps=2 legacy_chain=absent guest=enforced`；`smbutil view -N //guest@192.168.3.2` 见 3 个共享 | PASS |
| 5. 切回 1.0.7 后复查 | pid 13985 持 139/445；链 8 DROP + RETURN；guest DROP 在原厂 ACCEPT 前；cron 行在；`smbutil` 见 3 个共享 | PASS |
| 6. 一条 SSH + 本地包 | 全程单密钥会话与本机包完成，无需新入口 | PASS |

### 1.5 只读基线补齐

文件：[post-restore-baseline.txt](../evidence/2026-11-09-stage0-rollback/post-restore-baseline.txt)、[final-rollback-asset.txt](../evidence/2026-11-09-stage0-rollback/final-rollback-asset.txt)

| 项 | 实测 | 判定 |
|---|---|---|
| 端口归属 | 22 dropbear(6121)；80/8443 `sysapihttpd`(6728)；137/138 原厂 `nmbd`(14349)；139/445 `samba-s5d`(13985)；无 53 | PASS |
| 二进制身份 | 运行进程 exe = `versions/1.0.7-r2d/root/sbin/samba-s5d`；`smbd --version` = 4.25.1；nmbd exe = `/usr/sbin/samba_multicall` | PASS |
| 容量基线 | `/userdisk/data` 931.2G / 已用 485.2G / 可用 446.0G；`/` 107.9M / 已用 87.7M / 可用 20.1M | PASS |
| `homes` 三条判定 | `uci get samba.@samba[0].homes` = `1`；`testparm -s` 输出 `[homes] browseable=No read only=No`；`smbutil view -N` 列出 `homes` | PASS |

### 1.6 终态

```
current  -> versions/1.0.7-r2d/root
previous -> 1.0.6-r2d
versions -> 1.0.6-r2d/ 1.0.7-r2d/
```

回滚资产可用：`previous` 指向真实树，`smbd -b` 可解析，安装/激活日志记有 `rollback-target: 1.0.6-r2d verified tree+baked-prefix, not started`。设备 `release/` 保留 1.0.6 与 1.0.7 两个包。

## 2. 阶段 1：源码锁定与构建环境确认

构建环境：容器 `miwifi-s1`（Ubuntu 24.04，镜像 ID `sha256:fe8156…6ef852`），工具链 `/toolchain/bin/arm-xiaomi-linux-uclibcgnueabi-gcc`（GCC 4.8.2）、uClibc 0.9.33.2、`qemu-arm-static`。未安装任何新包，未编译。

| 项 | 锁定的源码/版本 | 校验值（SHA-256） | 完整性 | 依赖与工具链 | 预计构建时长（估算） | 能否进阶段 2 |
|---|---|---|---|---|---|---|
| A0 | 无新构建 | — | — | 现役 1.0.7 包 + 1.0.6 回滚包 | 0 | 可进入（仅冷启动核对） |
| A1 | `samba-4.25.1.tar.gz` | 未取得（下载链路限速，43.6 MB 未完成） | `.asc` 已取到，未验签 | 容器已有 4.25.1 解包源码树；GMP/Nettle/GnuTLS/zlib | 30–45 min | **BLOCKED**：上游 4.25.2 返回 404，无新版本 |
| B1 | `dropbear-2026.94.tar.bz2` | `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81` | `.asc` 验签通过（`F734 7EF2 … F29C 6773`） | 自带 libtom；zlib 可选；`configure` 存在 | 2–5 min | 可进入（构建）；部署仍需备用端口 |
| B2 | `curl-8.23.0.tar.xz` | `8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5` | `.asc` 验签通过（Daniel Stenberg `5CC9 08FD B71E 12C2`） | 调用方只用 HTTP；TLS 后端未锁（系统 mbedTLS 9 不可直接复用） | 5–10 min | 可进入（HTTP-only 私有树）；部署待逐调用方 |
| B3 | 复用 1.0.7 树 `sbin/nmbd` | 253 126 B；`nmbd -V` = 4.25.1 | 现役产物 | 零构建 | 0 | 可进入（切换）；部署受发现功能证据限制 |
| B4 | `minidlna-1.3.3.tar.gz` | `39026c6d4a139b9180192d1c37225aa3376fdf4f1a74d7debbdbb693d996afa4` | 与 SF 公布值一致 | 依赖见下表；**cmake 与 libtool 缺失** | 20–40 min | **BLOCKED**：构建环境缺 cmake（libjpeg-turbo 3.x）与 libtool（libid3tag 归档） |
| B5 | `dnsmasq-2.92rel2.tar.xz` | `43d72b8c129bdf33d17bafedc98823f63e46b5005128066bf0d2a472a32ce06a` | `.asc` 验签通过（键 `15CDDA6AE19135A2`，本机 trust unknown） | 最小构建无需 DBus/DNSSEC/IDN | < 2 min | 可进入（构建）；部署 BLOCKED：未触发 |
| B6 | `lighttpd-1.4.85.tar.xz` + `libxml2-2.15.4` + `sqlite-autoconf-3540100` | `18de51b3…` / `98087fd1…` / `926ef8d3…` | lighttpd `.asc` 验签通过 | Autotools 已具备；无生成后的 `configure`，需 `autogen.sh` | 10–20 min | **BLOCKED**：前置未决项（撤权语义/看护/端口） |

### 2.1 A1 / 上游状态

- `https://download.samba.org/pub/samba/stable/samba-4.25.2.tar.gz` → HTTP 404；`4.25.1` → HTTP 200，即当前最新。
- 容器内已有解包的 Samba 4.25.1 源码（`/work/sources`）；本次尝试另取官方 tarball 归档，链路限速导致 43.6 MB 未下完（首次 6.5 MB 截断件验签报“已损坏的签名”，已删除），`.asc` 已取到但未对完整 tarball 验签。A1 因上游无新版本本就不进入阶段 2，此项不阻塞阶段 1 结论。

### 2.2 B4 依赖锁定（MiniDLNA）

| 依赖 | 版本 | SHA-256 | 备注 |
|---|---|---|---|
| libexif | 0.6.24 | `d47564c433b733d83b6704c70477e0a4067811d184ec565258ac563d8223f6ae` | GitHub release |
| libjpeg-turbo | 3.0.4 | `99130559e7d62e8d695f2c0eaeef912c5828d5b84a0537dcb24c9678c9d5b76b` | 3.x 以 CMake 为主 |
| libid3tag | 0.16.3 | `0561009778513a95d91dac33cee8418d6622f710450a7cb56a74636d53b588cb` | Codeberg tag 归档，无签名 |
| flac | 1.4.3 | `6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70` | 可选（FLAC 元数据） |
| libogg | 1.3.5 | `0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664` | libvorbis 依赖 |
| libvorbis | 1.3.7 | `0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab` | 可选（Ogg 元数据） |
| SQLite | 3.54.1 | `926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e` | 已在容器 |

`configure.ac` 必需项：`jpeg`、`exif`、`id3tag`、`sqlite3`；`avformat`/`vorbisfile`/`FLAC`/`avahi` 为可选。

### 2.3 B2 调用方盘点（设备只读）

文件：[curl-callers.txt](../evidence/2026-11-09-stage0-rollback/curl-callers.txt)

| 类型 | 对象 | 用法 | 是否可改指向 |
|---|---|---|---|
| Shell | `/etc/init.d/miDebug.sh` | `curl -s http://api.miwifi.com/...` | 可（显式命令） |
| Shell | `/etc/init.d/mitvapp` | `curl localhost:/cgi-bin/luci/...` | 可 |
| Shell | `/usr/sbin/wifishare.sh` | `curl` 拉 `api.miwifi.com` 配置与 CDN | 可 |
| Shell | `/usr/bin/netspeed`（Lua） | `curl -s -I` 取跳转 | 可 |
| Shell | `/etc/mixbox/scripts/helper.sh` | 已优先 `/opt/bin/curl`，否则系统 curl | `/opt/bin/curl` 当前不存在 |
| ELF | `app_status`、`indexservice`、`mediaservice`、`datacenter`、`quarkd`、`plugin*` 等 | 链接 `libcurl.so.4`，不是 CLI | 不属替换范围 |

结论：脚本调用方全部使用 HTTP；`/usr/bin/curl` 被一堆厂商 ELF 依赖（经 `libcurl.so.4`），不能替换系统文件；私有 curl 只能通过显式路径服务上述脚本（`/opt` 当前不存在可写的 `curl`）。条目保留，部署范围收窄为“显式路径 + 逐调用方”。

### 2.4 环境缺口

- `cmake`、`libtool` 在容器中缺失：影响 libjpeg-turbo 3.x 与 libid3tag 源归档构建。
- 容器仍无 Dockerfile/镜像配方，环境可复现性未闭环。
- curl 的 TLS 后端未锁定：若只需要 HTTP，可 `--without-ssl`；若需 HTTPS，需另锁 mbedTLS/OpenSSL 私有构建。

## 3. 落位对照：计划出口条件 → 证据 → 判定

### 3.1 阶段 0

| 计划出口条件（§4.1） | 实际证据 | 判定 |
|---|---|---|
| 本地包体积/MD5/SHA-256 与计划一致 | §1.1 本文件 | PASS |
| 装机前快照落盘（current/versions/previous/链/INPUT/cron/pid） | [pre-install-snapshot.txt](../evidence/2026-11-09-stage0-rollback/pre-install-snapshot.txt) | PASS |
| 1.0.6 `install` 不激活 | `state/install.log` 16:23:01 条目；§1.3 | PASS |
| 两次 `activate` 完成前后切换 | `state/install.log` 16:23:13 / 16:23:15 | PASS |
| `rollback` 真实切走（判定 1–4） | [rollback-to-106.txt](../evidence/2026-11-09-stage0-rollback/rollback-to-106.txt) | PASS |
| 切回 1.0.7 后五项复查 | [switch-back-107.txt](../evidence/2026-11-09-stage0-rollback/switch-back-107.txt)、[post-restore-baseline.txt](../evidence/2026-11-09-stage0-rollback/post-restore-baseline.txt) | PASS |
| 全程一条 SSH + 本地包 | 执行记录 | PASS |
| `previous` 指向可解析前缀的真实树 | [final-rollback-asset.txt](../evidence/2026-11-09-stage0-rollback/final-rollback-asset.txt) | PASS |
| 端口归属/二进制身份/容量/`homes` 三条 | [post-restore-baseline.txt](../evidence/2026-11-09-stage0-rollback/post-restore-baseline.txt) | PASS |
| 冷启动后复查 | 未重启整机 | 未执行（属 A0，不属阶段 0 出口） |

### 3.2 阶段 1

| 计划出口条件（§4.4） | 实际证据 | 判定 |
|---|---|---|
| 工具链/容器/QEMU 确认 | §2 环境段 | PASS |
| B1 源码锁定并验签 | §2 表 | PASS |
| B2 源码锁定 + 调用方结论 | §2.3、[curl-callers.txt](../evidence/2026-11-09-stage0-rollback/curl-callers.txt) | PASS |
| B3 复用现役产物确认 | §2 表 | PASS |
| B4 源码与依赖锁定 | §2.2 | PASS（源码）/ BLOCKED（构建环境缺 cmake、libtool） |
| B5 源码锁定并验签 | §2 表 | PASS |
| B6 源码锁定 | §2 表 | PASS（源码）/ BLOCKED（设计未决） |
| A1 上游触发 | §2.1 | BLOCKED：无新版本 |
| 每项写清来源/校验/依赖/时长/能否进阶段 2 | §2 表 | PASS |
| 阶段 1 不装包、不重启服务 | 执行记录 | PASS |

## 4. 结论

- 阶段 0：**通过**。回滚资产恢复为可用状态（`previous -> 1.0.6-r2d`，树完整、前缀可解析），并完成一次真实 rollback 与切回。
- 阶段 1：源码锁定完成 6/8（B1、B2、B3、B4、B5、B6 已锁；A0 无需锁；A1 无新版本）。可进入阶段 2 构建的为 B1、B2（HTTP-only）、B3、B5；B4、B6、A1 分别因构建环境与设计/上游条件阻塞。
