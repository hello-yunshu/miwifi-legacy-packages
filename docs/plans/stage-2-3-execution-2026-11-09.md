# 阶段 2/3 执行记录（2026-11-09）

- 范围：按 [R2D 软件升级总计划](r2d-software-upgrade-plan.md) 的八项候选完成阶段 2（离线构建）与阶段 3（设备隔离验证）。
- 设备：MiWiFi R2D / 固件 2.25.209 / ARMv7 / uClibc 0.9.33.2 / Linux 2.6.36。
- 硬边界执行情况：未向系统路径安装任何包；未改 `/etc/config/*`；未重启现役 `smbd`/`nmbd`/`crond`/`rpcd`；所有临时实例均使用独立目录、独立配置和非冲突端口。
- 构建脚本已入库：[recipes/stage2/](../../recipes/stage2/)（`env.sh`、`b1-dropbear.sh`、`b2-curl.sh`、`b4-minidlna.sh`、`b5-dnsmasq.sh`、`b6-lighttpd.sh`）。

## 1. 阶段 2：离线构建

### 1.1 构建环境

| 项 | 值 |
|---|---|
| 构建容器 | `miwifi-s1`（Ubuntu 24.04，按需补装 `cmake`/`libtool`） |
| 工具链 | `/toolchain/bin/arm-xiaomi-linux-uclibcgnueabi-gcc`（GCC 4.8.2） |
| C 库 | uClibc 0.9.33.2 |
| 源码 | `/work/sources/stage0-1-20261109` |
| 容器暂存 | `/work/stage2/<component>/root` |
| 设备安装前缀 | `/userdisk/data/r2d-cand/<component>/root` |
| RPATH | 直接烘焙为设备前缀，运行时不依赖容器路径 |

### 1.2 产物清单

体积与 sha256 均对设备上的最终文件复核（设备无 `sha256sum`，用 `ssh cat | shasum -a 256` 取得，见证据 `build-artifacts.txt`）。

| 编号 | 产物（设备路径） | 版本自证 | 体积(B) | sha256 | NEEDED | 冷/热耗时 |
|---|---|---|---|---|---|---|
| B1 | `b1-dropbear/root/sbin/dropbear` | `Dropbear v2026.94` | 320075 | `920648dd000fcfe570fd3c3239417f42eaf67452522f36679481fe70d2f04cba` | libutil, libcrypt, libc | 25s / 23s |
| B1 | `b1-dropbear/root/bin/dropbearkey` | 随同 2026.94 构建 | 182463 | `e8645f65e02c0bba0cdfc92c1fd5fd74c22f4828994d9eaf9bf6a6e77dc9af3b` | libutil, libc | 同上 |
| B2 | `b2-curl/root/bin/curl` | `curl 8.23.0 (arm-xiaomi-linux-uclibcgnueabi) libcurl/8.23.0` | 539272 | `1d32283974e07c8c2f97dc9f821d1ff889c4ac18edfb0157adde5b5ba4a105d1` | libpthread, libc | 60s / 62s |
| B3 | `/userdisk/data/s7root/versions/1.0.7-r2d/root/sbin/nmbd`（复用现役） | `Version 4.25.1` | 253126 | `fed9fd102260df44eeeb38312058a99414bd19e0196e9852588c75e733eabf9e`（设备 md5 `2283bda9f01dfa719ad276af28b655a0`） | 现役树 | 无构建 |
| B4 | `b4-dlna/root/sbin/minidlnad` | `Version 1.3.3` | 2955291 | `5db5b6d705c394fbe51c326f946a0eb8130894aaba909324f41cd7a4789a1fc5` | libjpeg, libid3tag, libz, libsqlite3, libexif, libvorbis, libogg, libpthread, libm, libc | 3s / 3s |
| B5 | `b5-dnsmasq/root/sbin/dnsmasq` | `Dnsmasq version 2.92rel2` | 368926 | `d4ed2c8aa1b2d12d769dab4098089048c501d7af3a18879ef7a23358337104e9` | libc | 5s / 4s |
| B6 | `b6-webdav/root/sbin/lighttpd` | `lighttpd/1.4.85` | 358859 | `3dae50006dfcb60da04fe3f852c79bcafea48e9165e791c5c3eaefc541ec90d8` | libdl, libc | 30s / 23s |
| B6 | `b6-webdav/root/lib/mod_webdav.so` | 随 lighttpd 1.4.85 | 57634 | `0a9228a4e0946045a288b0800a0c6570ae4d4e2918d5ac22537d47641b0570e7` | libxml2.so.16, libsqlite3, libc | 同上 |

B4 依赖构建耗时（冷）：zlib 2s、libjpeg-turbo 35s、libexif 7s、libid3tag 2s、libogg 1s、libvorbis 5s、flac 13s、sqlite 15s、ffmpeg 17s。
B6 依赖构建耗时：sqlite 16s（冷）/24s（热）、libxml2 9s（冷）/15s（热）。

依赖落位核验：

- 设备无 `ldd`（`ash: ldd: not found`），改用 ELF `NEEDED` + 内嵌 `RPATH` 核验。
- B1/B2/B4/B6 的 `RPATH` 均为各自 `/userdisk/data/r2d-cand/<component>/root/lib`；B4 的媒体库依赖全部落在私有树。
- B5 无 `RPATH`，`NEEDED` 仅 `libc.so.0`，不引入任何私有库。
- 各产物仍依赖 `libc/libm/libpthread/libdl/libutil/libcrypt` 等基础运行时；这些属于计划 §3 明确不单包升级的系统级组件，未尝试替换。

### 1.3 构建要点

- **B2 curl**：8.x 默认 threaded resolver 在 uClibc 0.9.33.2 + 2.6.36 上会卡在 `eventfd` 读取，必须 `--disable-threaded-resolver`；最终为静态 libcurl、`--without-ssl`，协议仅 `http`。
- **B4 MiniDLNA**：1.3.3 硬依赖 ffmpeg 的 `libavutil/libavcodec/libavformat`，阶段 1 未锁定该源码，本轮新增 `ffmpeg-6.1.2.tar.xz`（10,466,152 B，sha256 `3b624649725ecdc565c903ca6643d41f33bd49239922e45c9b1442c63dca4e38`），仅启用 `image2` 解复用与 `mjpeg,png` 解码。`libid3tag` 源码树仅支持 CMake，改用 CMake 构建；minidlna 链接需把 `LIBS="-lm -lpthread"` 放在末尾。
- **B6 lighttpd**：`--without-pcre2 --without-pcre --with-webdav-props --with-webdav-locks` 生成 `mod_webdav.so`；sqlite 的 `--disable-tcl` 不是有效参数，已移除。
- **B3 nmbd**：零构建，候选即现役 `4.25.1`，完成体积、md5、sha256 与 `-V` 记录。

### 1.4 失败与 BLOCKED（阶段 2）

| 项 | 状态 | 说明 |
|---|---|---|
| A1 Samba 上游维护 | BLOCKED（无部署对象） | 上游当前 stable 仍为 4.25.1；后台补拉 samba-4.25.1 源码失败且 A1 本就无新版本，不影响本轮构建 |
| B3 nmbd | 无需构建 | 复用现役 4.25.1，哈希已记录 |
| 其余 B1/B2/B4/B5/B6 | PASS | 全部产物构建成功，无构建失败项 |

阶段 2 出口：**满足**。所有需要构建的候选均产出二进制并完成版本自证、依赖落位、体积、sha256 与冷/热耗时记录；无拿旧产物顶替的项。

## 2. 阶段 3：设备隔离验证

所有临时实例均未占用生产端口，验证后停止并清理。证据目录：[docs/evidence/2026-11-09-stage2-3/](../evidence/2026-11-09-stage2-3/)。

### 2.1 B1 Dropbear 2026.94

- 启动方式：私有树二进制，`-p 2222`、独立 host key、`-F -E` 前台运行，pid/日志写私有目录。
- 验证结果：
  - 实例监听 `0.0.0.0:2222`，banner 为 `SSH-2.0-dropbear_2026.94`：**PASS**。
  - 公钥认证：**FAIL**。服务端在认证前拒绝，日志为
    `/userdisk/data/r2d-cand must be owned by user or root, and not writable by group or others`。
    现场权限：`/` 为 `755 1000 1000`，`/userdisk`、`/userdisk/data`、`/userdisk/data/r2d-cand` 为 `777 0 0`。Dropbear 的父目录权限检查无法通过配置绕过，修复它需要改设备目录属主/权限，超出本轮硬边界，因此本项记为 FAIL（环境限制），不改设备状态。
  - 断线重连未能在密钥认证通过前验证，随本项 FAIL 一并未决。
- 清理：停止实例后 `2222` 已释放；生产 dropbear（pid 6121，端口 22）未变。
- 证据：[b1-dropbear-verify.txt](../evidence/2026-11-09-stage2-3/b1-dropbear-verify.txt)。

### 2.2 B2 curl 8.23.0（HTTP-only）

- 启动方式：以 B6 lighttpd 在 `127.0.0.1:18081` 起本地 HTTP 服务作为被测端。
- 验证结果：
  - `--version` 为 8.23.0，协议列表仅 `http`：**PASS**。
  - `GET /hello.txt` → `200`，退出码 `0`，正文 `hello-r2d-curl`：**PASS**。
  - `HEAD` → `200`，退出码 `0`：**PASS**。
  - `-f` 访问不存在路径 → 退出码 `22`：**PASS**。
  - `https://` → `curl: (1) Protocol "https" is disabled`，退出码 `1`：**PASS**（确认只覆盖 HTTP）。
  - 连接拒绝 → 退出码 `7`：**PASS**。
- 清理：停 lighttpd 后 `18081` 释放；无 `lighttpd`/`curl` 残留；生产监听（22/80/139/445/8443）未变。
- 证据：[b2-curl-verify.txt](../evidence/2026-11-09-stage2-3/b2-curl-verify.txt)、[b2-curl-cleanup.txt](../evidence/2026-11-09-stage2-3/b2-curl-cleanup.txt)。

### 2.3 B3 nmbd 4.25.1

- 现状核对：生产 `nmbd -D`（pid 14349，`/usr/sbin/samba_multicall`）独占 UDP 137/138；私有树 `nmbd -V` 为 `Version 4.25.1`。
- 隔离尝试：`nmbd` 的帮助里只有 `-p` 可改 137 端口，**138 没有对应开关**；设备无 `/proc/self/ns`，无法用 network namespace 隔离。启动第二实例必然与生产 137/138 冲突，或需改动生产 `nmbd`。
- 判定：**BLOCKED**。未启动第二实例，未触碰生产 `nmbd` 与 137/138 归属。
- 证据：[b3-nmbd-blocked.txt](../evidence/2026-11-09-stage2-3/b3-nmbd-blocked.txt)。

### 2.4 B4 MiniDLNA 1.3.3

- 启动方式：`minidlnad -f <私有 minidlna.conf> -P <私有 pid 文件>`；配置 `media_dir=P,...`、`port=18200`、`friendly_name=R2D-MiniDLNA-Test`、`inotify=no`。
- 验证结果：
  - 配置生成与数据库创建成功，日志 `Creating new database ... files.db`：**PASS**。
  - 索引：放入 1 个 `.jpg` 后日志 `Scanning ... finished (1 files)!`：**PASS**。
  - HTTP：`/rootDesc.xml` → `200`，`friendlyName` 正确：**PASS**。
  - UPnP SOAP `Browse` → `200`，返回 `Music/Pictures/Video` 容器：**PASS**。
  - 电视真机发现：**BLOCKED**（本轮无电视端配合）。
- 清理：停止后 `18200` 释放，无 `minidlnad` 残留；生产 pid 未变。私有树内保留测试媒体/索引作为候选目录的一部分。
- 证据：[b4-minidlna-verify.txt](../evidence/2026-11-09-stage2-3/b4-minidlna-verify.txt)。

### 2.5 B5 dnsmasq 2.92rel2

- 启动方式：独立配置目录，`dnsmasq --test -C <conf>` 先做语法检查；正式实例 `--port=5353 --listen-address=127.0.0.1 --bind-interfaces`，pid/日志写私有目录。
- 验证结果：
  - `--test` 输出 `dnsmasq: syntax check OK.`，退出码 `0`：**PASS**。
  - 监听 `127.0.0.1:5353`（pid 16074）：**PASS**。
  - 手工构造 A 查询 `r2d.test`，UDP 应答前 12 字节 `12 34 85 80 ...`（`85 80` = 标准响应 + RA/RD，无错误），ANSWER 计数 `00 01`，地址 `7f 00 00 01`：**PASS**。
  - 未启用 DHCP/租约，未接管现有 DNS。
- 清理：停止后 `5353` 释放；复查 `53` 无监听（与验证前一致）；无 `dnsmasq` 残留进程。
- 证据：[b5-dnsmasq-verify.txt](../evidence/2026-11-09-stage2-3/b5-dnsmasq-verify.txt)、[b5-dnsmasq-cleanup.txt](../evidence/2026-11-09-stage2-3/b5-dnsmasq-cleanup.txt)。

### 2.6 B6 lighttpd 1.4.85 + mod_webdav

- 启动方式：`lighttpd -D -f <私有配置>`，端口 `18080`，临时 docroot，basic 认证，加载 `mod_webdav.so`。
- 验证结果：
  - 未认证访问 → `401`：**PASS**。
  - `PUT` → `201`，文件落盘：**PASS**。
  - `GET` → `200`，正文 `hello-webdav-r2d`：**PASS**。
  - `PROPFIND` → `207`，返回 `getcontentlength`/`getcontenttype`/`getetag`：**PASS**。
  - `LOCK` → `200`，返回 `Lock-Token`：**PASS**。
  - 加锁后 `DELETE` → `423`，文件仍可 `GET`：**PASS**。
  - `UNLOCK` → `204`，随后 `DELETE` → `204`，再 `GET` → `404`：**PASS**。
- 未决三项（**未实现、未验证，不记为 PASS**）：
  - 5 秒撤权时延；
  - 策略异常 fail-closed；
  - 看护进程存活。
- 清理：停止后 `18080` 释放，无 `lighttpd` 残留；删除 `/tmp/w_*` 测试文件；生产 139/445 未变。
- 证据：[b6-webdav-verify.txt](../evidence/2026-11-09-stage2-3/b6-webdav-verify.txt)、[b6-webdav-cleanup.txt](../evidence/2026-11-09-stage2-3/b6-webdav-cleanup.txt)。

## 3. 清理核对总表

| 项 | 临时端口 | 端口已释放 | 无残留进程 | 生产 pid/监听未变 |
|---|---|---|---|---|
| B1 Dropbear | 2222 | 是 | 是 | 是（dropbear 6121） |
| B2 curl | 18081 | 是 | 是（含最终清扫发现的 1 个 curl） | 是 |
| B3 nmbd | 未启动 | — | — | 是（nmbd 14349 持 137/138） |
| B4 MiniDLNA | 18200 | 是 | 是 | 是 |
| B5 dnsmasq | 5353 | 是 | 是（含最终清扫发现的 1 个 ash） | 是（53 无监听） |
| B6 WebDAV | 18080 | 是 | 是（含 `/tmp/w_*` 已删） | 是（139/445 归 13985） |

最终全量复查：`ps | grep r2d-cand` 为空；`netstat` 中 `2222/5353/18080/18081/18200` 均无监听；生产 `nmbd`/`dropbear` pid 与验证前一致。

## 4. 出口判定

- **阶段 2：满足。** 六个需要构建的组件（B1、B2、B4、B5、B6 及 B6 的 libxml2/SQLite 依赖）全部构建成功；B3 零构建复用并完成哈希记录；A1 无上游新版本，无可部署对象。
- **阶段 3：可隔离项全部收口。**
  - PASS：B2（HTTP-only 全项）、B4（配置/索引/HTTP/SOAP）、B5（语法+UDP 应答）、B6（WebDAV 方法与认证）、B1 的启动/banner/清理。
  - FAIL：B1 公钥认证（设备父目录 `777`/属主 1000，修它必须改设备状态）。
  - BLOCKED：B3（138 无端口开关且无 netns）、B4 电视真机发现（无电视端）。
  - 未决：B6 的 5 秒撤权、fail-closed、看护进程存活（本轮未实现，未验证）。

## 5. 证据索引

全部原始输出位于 [docs/evidence/2026-11-09-stage2-3/](../evidence/2026-11-09-stage2-3/)：

| 文件 | 内容 |
|---|---|
| `build-artifacts.txt` | 产物 size/sha256/NEEDED、冷热耗时、设备端版本与哈希复核、RPATH |
| `b1-dropbear-verify.txt` | Dropbear 启动、banner、权限拒绝日志、端口释放、生产 pid |
| `b2-curl-verify.txt` | curl 版本、HTTP 状态与退出码、HTTPS 禁用 |
| `b2-curl-cleanup.txt` | 端口/进程清理与最终清扫 |
| `b3-nmbd-blocked.txt` | nmbd 身份、版本、137/138 归属、端口开关、无 netns |
| `b4-minidlna-verify.txt` | 配置、索引、HTTP、SOAP Browse、清理 |
| `b5-dnsmasq-verify.txt` | 语法检查、UDP 监听与应答字节 |
| `b5-dnsmasq-cleanup.txt` | 端口/进程清理与最终清扫 |
| `b6-webdav-verify.txt` | 401/201/200/207/LOCK/423/204/404 |
| `b6-webdav-cleanup.txt` | 端口/进程/临时文件清理 |
