# S1 干净构建记录：Samba 4.25.1

记录日期：2026-11-07。目标：用设备实际工具链从全新上游源码做一次可复现的干净交叉构建，产物状态为 lab，不进入设备。

## 结论

| 项目 | 结果 |
| --- | --- |
| 源码锁定 | 4.25.1，SHA-256 `7f367545bca69aa96897628f82f0f04d4b66b3bcb36cb978b9bb952c4b4c428d`，43,590,836 字节 |
| 签名 | `gpg --verify`（对解压后的 tar 流）完好，签名者 `Samba Distribution Verification Key <samba-bugs@samba.org>`，RSA 密钥 `81F5E2832BD2545A1897B713AA99442FB680B620` |
| 干净构建 | 达成。全新解压源码树 + 空输出目录，`configure`/`build`/`install` 全部 `rc=0` |
| 产物可用性 | `smbd --version`、`nmbd --version`、`testparm --version` 均输出 `Version 4.25.1`；`testparm -s` 载入设备同构配置通过；`smbd` 在 QEMU + 原厂 uClibc sysroot 下启动并进入 `waiting for connections` |
| 依赖可追溯 | 全部 `NEEDED` 只有 6 项落在系统库，设备 `/lib` 均存在；其余 178 个共享库随包提供 |
| 未达成项 | 未 strip（含调试信息）；未在真实设备运行（属 S6）；`--disable-python` 使 `samba-tool` 不可用 |

本构建与 2026-11-06 的 4.23.13 增量修复构建无继承关系：源码、补丁、依赖、输出目录全部重来。

## 版本锁定与验签

上游 stable 于 2026-11-07 核对为 4.25.1。归档目录（仓库外）保存 `samba-4.25.1.tar.gz`、`samba-4.25.1.tar.asc`、`samba-pubkey.asc`。

签名对象是解压后的 tar，对 `.tar.gz` 直接验签会得到 BAD signature。正确验证方式：

```bash
gunzip -c samba-4.25.1.tar.gz | gpg --verify samba-4.25.1.tar.asc -
# gpg: 完好的签名，来自于 "Samba Distribution Verification Key <samba-bugs@samba.org>"
```

公钥未经过信任路径认证（samba.org 发布页获取），因此结论是"签名有效"，不是"证书链可信"。

## 构建环境

| 组件 | 版本/配置 |
| --- | --- |
| 工具链 | 小米官方 SDK `sdk_package/toolchain`，`arm-xiaomi-linux-uclibcgnueabi`，GCC 4.8.2 20130603 (crosstool-NG 1.19.0) |
| C 库 | uClibc 0.9.33.2（sysroot 内 `libuClibc-0.9.33.2.so`，575,760 字节，MD5 `0c15e93496faa913c695ee9e09e0e384`） |
| 目标 | ARMv7-A，EABI5，soft float，解释器 `/lib/ld-uClibc.so.0` |
| 构建机 | Docker `ubuntu:24.04`，`--platform linux/amd64`（宿主为 Apple Silicon） |
| 执行器 | `qemu-arm-static` 8.2.2，`-L <sysroot>` 运行 ARM 代码生成器与自检程序 |
| 构建参数 | `-Os -fPIC -march=armv7-a -mfloat-abi=soft`，安装前缀 `/opt/samba-next`，`--libdir=/opt/samba-next/lib` |

工具链、源码、构建树都在仓库外；仓库只记录可复现要素与散列，不分发厂商二进制。

## 交叉依赖

Samba 自身的构建期依赖全部由本地构建，未使用发行版库：

| 依赖 | 版本 | 归档 SHA-256 | 说明 |
| --- | --- | --- | --- |
| zlib | 1.4 | `4f11c512053d7bab8d9e9b89bde3575add3e4c50a383b42ef6cb837035fc5a7c` | 压缩支持 |
| GMP | 6.3.0 | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` | nettle/hogweed 公钥运算 |
| Nettle | 3.10.2 | `fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5` | 必须启用 hogweed 与 GMP |
| GnuTLS | 3.8.13 | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` | SMB3 加密与签名 |

依赖构建中的真实失败与处置（均为工具链限制，不是 Samba 代码问题）：

| 失败原文 | 定位 | 处置 |
| --- | --- | --- |
| `checking for __gmpn_zero_p in -lgmp... no`（`cannot find -lgmp`） | nettle 的 config.log 缺库搜索路径 | 重建 nettle/gnutls 时加 `LDFLAGS=-L<prefix>/lib` |
| `static_assert(...)`: `expected ',' before ')' token` | GCC 4.8 只支持双参数 `_Static_assert`，uClibc `<assert.h>` 又把 `static_assert` 定义成单参数宏 | 用 `-include` 注入 shim：先 `#include <assert.h>`，再 `#undef static_assert` / `#define static_assert(x) _Static_assert(x, "...")`，靠头文件保护防止二次覆盖 |
| `parser_aux.c:50: 'WORD_BIT' undeclared` | uClibc 0.9.33.2 不暴露 `WORD_BIT` | 同一 shim 中 `#define WORD_BIT 32` |
| `No rule to make target '../gl/libgnu.la'` | 只 `make -C lib`，未先构建 gnulib 目录 | 先 `make -C gl` 再 `make -C lib` |

## configure 参数

```text
--prefix=/opt/samba-next --libdir=/opt/samba-next/lib
--cross-compile --hostcc=gcc --cross-execute=/work/run-arm.sh
--disable-python --without-ad-dc --without-ads --without-ldap --without-pam --without-winbind
--without-gpgme --without-regedit --without-winexe --without-systemd --without-systemd-userdb
--without-json --without-acl-support --without-quotas --disable-cups --disable-iprint
--disable-avahi --disable-spotlight --disable-wsp --without-libarchive --without-libunwind
--without-automount --without-dmapi --without-fam --without-cluster-support --disable-glusterfs
--disable-cephfs --with-shared-modules='!vfs_snapper' --bundled-libraries=ALL
--disable-warnings-as-errors
```

`--libdir` 是显式决策。默认值在 x86_64 构建机上是 `lib64`，会把公共库装到 `lib64`，与设备 `/usr/lib` 惯例不一致，也会误导部署脚本。改为 `lib` 后公共库、私有库（`lib/private`）与模块（`lib/vfs`、`lib/idmap` 等）都在同一树内。

`--disable-warnings-as-errors` 是必要的：GCC 4.8 会对新代码发出较多告警，沿用 `-Werror` 会在无实际错误处中断。判定标准仍然是"真实编译错误必须暴露"，本轮所有 `error:` 输出都来自 pidl 的 `Unable to determine origin of type` 提示，属生成器告警，不是编译失败。

## 补丁序列

5 个补丁对 4.25.1 全部干净应用（`patch -p1`，`rc=0`），逐个已用反向 `--dry-run` 确认已生效：

| 补丁 | 作用 |
| --- | --- |
| `samba-cross-asn1-rule.patch` | 交叉构建下 asn1 规则的执行方式 |
| `samba-cross-codegen-executor.patch` | 让 `et_compile_wrapper.sh` / `asn1_compile_wrapper.sh` 使用 `SAMBA_CODEGEN_EXECUTOR` |
| `samba-sdk-generic-selection.patch` | 旧 GCC 下 `charset.h` 的泛型选择 |
| `samba-sdk-reflink-guard.patch` | `replace.c` 的 reflink 能力保护 |
| `samba-sdk-spawn.patch` | `sdk_spawn.h`、`local_np.c`、`queue_process.c` 的进程创建适配 |

另有 `gnutls-sdk-thread-local.patch` 只作用于 GnuTLS 源码，不在 Samba 树内。

## 构建过程与失败点

| 阶段 | 结果 |
| --- | --- |
| configure | `rc=0`，3m40s（首次因 qemu 路径与缺失 perl 模块失败，见下） |
| build | `rc=0`，4m36s，3456 个任务 |
| install | `rc=0`，1m45s（`DESTDIR` 到仓库外前缀） |

本轮遇到并修复的真实失败：

| 失败原文 | 根因 | 处置 |
| --- | --- | --- |
| `/work/run-arm.sh: 2: exec: /usr/bin/qemu-arm: not found`，随后 `Samba requires large file support ... sizeof(off_t) < 8` | 容器内只有 `qemu-arm-static` | 改 `run-arm.sh` 路径 |
| `perl module "Parse::Yapp::Driver" not found`（`pidl/wscript:27`） | `pidl` 被顶层 `wscript` 无条件 `RECURSE`，缺该 perl 模块直接抛 `WafError` | 安装 `libparse-yapp-perl`（含 `yapp`），不是绕过检查 |
| `FileNotFoundError: arm-xiaomi-linux-uclibcgnueabi-gcc` | 新开的 `docker exec` 会话没有 `/toolchain/bin` | 构建命令内显式导出 `PATH` |
| `[qemu-arm]: Could not open '/lib/ld-uClibc.so.0'`，10 个 `*_ET` 任务失败 | `heimdal_build/wscript_build:92` 从环境取 `SAMBA_CODEGEN_EXECUTOR`，未设置时裸调 qemu | 导出 `SAMBA_CODEGEN_EXECUTOR="qemu-arm-static -L <sysroot> -E LD_LIBRARY_PATH=..."` |
| `task in 'HEIMDAL_KX509_ASN1_ASN1' failed with exit status 255`（`make install`） | 同上，install 阶段触发 asn1 重生成 | 同上 |

## 产物清单

安装树 41 MiB（含随包第三方库）：

| 路径 | 内容 | 大小 |
| --- | --- | --- |
| `sbin/smbd` | 主服务 | 81,534 字节 |
| `sbin/nmbd` | NetBIOS 名服务 | 253,126 字节 |
| `bin/testparm` | 配置校验 | 43,291 字节 |
| `bin/smbclient` | 客户端 | 140,459 字节 |
| `lib/` | 公共库 53 项、私有库 125 项、模块 183 项 | 32 MiB |
| `libexec/`、`bin/` 其余工具 | 辅助程序 | 7.1 MiB |

关键散列（SHA-256）：

| 文件 | SHA-256 |
| --- | --- |
| `sbin/smbd` | `cb037de215537fd8905fffff80110e07b924b23e606385ac8813f975b8cc0641` |
| `sbin/nmbd` | `bb5ee9816dbe756500e55a05dc9311b97ac509e9119f16a324b1b5a51f0adb65` |
| `bin/testparm` | `41ef5a550be2e178250d66dad616a73e76381037359db0f5095483b935370e7d` |
| `bin/smbclient` | `9cab17683ea94fdae0b31d975e0f8686eacbfe5cb48ab699b668dc18ba8f3b18` |
| `lib/libgnutls.so.30.42.0` | `c7e3630ceeb56eb854eec143dc59a657ede207044df83b07c833241e8bc2a9c8` |
| `lib/libhogweed.so.6.11` | `c9e4e550eeba13d4862157da4e156fc5ef434e0447877730cf757ebefdb5e00d` |
| `lib/libnettle.so.8.11` | `f1ff96b51c1f86d81606639acfa7f6a78f2706609c80302a6ce68ed7a005a0c0` |
| `lib/libgmp.so.10.5.0` | `2f43ab027864c4816b7c9b438977fe4f2d9125d72acf2ce81f6dcbee3eae34eb` |

ELF 信息（`smbd`）：`ELF 32-bit LSB executable, ARM, EABI5, dynamically linked, interpreter /lib/ld-uClibc.so.0`，`RPATH=/opt/samba-next/lib`，29 个 `NEEDED`，未 strip。`nmbd`、`testparm`、`smbclient` 同解释器、同 `RPATH`。

公共库改为 `--libdir=lib` 后，两次构建的 4 个主程序 SHA-256 完全一致，说明产物不依赖输出目录布局。

## 依赖闭包

对整树 183 个模块与全部可执行文件求 `NEEDED` 并集，只有 6 项落在系统库：

`ld-uClibc.so.0`、`libc.so.0`、`libpthread.so.0`、`libdl.so.0`、`libcrypt.so.0`、`libubacktrace.so.0`

设备 `/lib` 只读列举确认这 6 项全部存在（设备还额外有 `libresolv.so.0`、`librt.so.0`、`libutil.so.0`、`libm.so.0`、`libz.so.1` 等）。其余 178 个 `NEEDED`（`*-private-samba.so`、`libndr*`、`libsamba-*`、`libgnutls`、`libnettle`、`libhogweed`、`libgmp`）全部在安装树内。

## 运行验证（QEMU + 原厂 sysroot）

| 检查 | 结果 |
| --- | --- |
| `smbd --version` / `nmbd --version` / `testparm --version` | `Version 4.25.1` |
| `testparm -s`（与设备同构：`security = user`、`map to guest = Bad User`、`LANMAN1`–`SMB3`、`smb encrypt = no`） | `Loaded services file OK.` / `Server role: ROLE_STANDALONE` |
| `smbd -F --no-process-group -p 1447` 启动 | 初始化 passdb、锁、消息库后进入 `waiting for connections` |
| `smbd -b` | `SBINDIR=/opt/samba-next/sbin`、`LIBDIR=/opt/samba-next/lib`、`MODULESDIR=/opt/samba-next/lib` |

QEMU 使用宿主内核，不能替代 Linux 2.6.36 实机验证。

## 与设备现有 `samba_multicall` 对照

| 维度 | 设备 4.0.21（`/usr/sbin/samba_multicall`） | 本次 4.25.1 |
| --- | --- | --- |
| 形态 | 单文件 multicall，4,325,084 字节，已 strip，MD5 `5e422d3463f40b4405ef8325ce3603e8` | `smbd`/`nmbd` 分体 + 53 公共库 + 125 私有库 + 183 模块 |
| 解释器 | `/lib/ld-uClibc.so.0` | 同 |
| `NEEDED` | `libaio.so.1`、`libdl.so.0`、`libubus.so`、`libubox.so`、`libcrypt.so.0`、`libresolv.so.0`、`libpthread.so.0`、`libz.so.1`、`libc.so.0`、`libubacktrace.so.0` | 6 项系统库 + 178 项自带库 |
| 符号 | 已 strip，动态符号仅 17 个导出、316 个未定义 | 未 strip；整树未定义符号 6,766 个，导出 31,709 个 |
| 依赖 libc | 设备 `libuClibc-0.9.33.2.so`，575,760 字节，MD5 `e2164dfc067f356af2dec37acf36e9e6` | SDK sysroot `libuClibc-0.9.33.2.so`，575,760 字节，MD5 `0c15e93496faa913c695ee9e09e0e384` |

符号级结论：以"设备 `libuClibc` + `libpthread` 的导出符号"加上"本次安装树的自有导出符号"为并集，去匹配整树未定义符号，剩余只有 `backtrace`/`backtrace_symbols`（设备 `libubacktrace.so.0` 提供，已列入 `NEEDED`）、`crypt`（`libcrypt.so.0`）、`dlopen`/`dlsym`/`dlerror`/`dlclose`（`libdl.so.0`），以及 `find_domain_from_name`、`get_global_winbindd_state_offline` 两项。

后两项来自 `libidmap-private-samba.so`，其定义只存在于 `source3/winbindd/*.c` 与 torture 测试中；因为 `--without-winbind`，实现未编译进树。当前 `security = user` 配置下 smbd 启动不触发该路径，但它是一个必须在 S2 覆盖的运行时风险，而不是可忽略的链接残留。

结论分档：

- **不可直接替换**：设备是单文件 multicall + `shareUpdate`/`supervisord` 生命周期，新树是目录树 + 分体进程，路径、PID/锁/状态目录、模块加载方式都不同；`smbcontrol` 也不能假设可跨版本控制旧进程。切换必须走 S5/S7 的适配与回滚，不能覆盖 `/usr/sbin/samba_multicall`。
- **需适配**：`RPATH=/opt/samba-next/lib` 固定；公共库、私有库、模块必须整体落位；`/` 为只读 ubifs（107.9 MB，已用 81%），41 MiB 产物无法落在根分区，需要 `/userdisk` 或外挂盘；旧 GCC 补丁 5 项需随源码保留。
- **必须放弃**：`--without-winbind` 下的 winbind idmap 后端与域相关能力；`--disable-python` 下的 `samba-tool` 等 Python 工具；`--without-ad-dc`、`--without-ads` 的 AD DC/成员能力；`--disable-cups/iprint` 的打印服务；`--without-acl-support`、`--without-quotas` 的 POSIX ACL 与配额语义。

## 阻挡 S2 的具体问题

1. **运行根与隔离目录未定**：新树需要固定 `prefix` 与 `lock/state/cache/private` 目录，且不能与原厂 4.0.21 共用 TDB、锁与 PID 文件。S2 的隔离回归要先给出这组目录，否则测试会污染原厂状态。
2. **winbind 缺失符号**：`libidmap-private-samba.so` 的 `find_domain_from_name`、`get_global_winbindd_state_offline` 未解析。S2 必须显式覆盖 idmap 后端用例，确认不触发；若触发则需改为 `--with-winbind` 或裁剪 idmap 模块。
3. **设备 libc 与 SDK sysroot 不是同一二进制**：同为 0.9.33.2、同大小，但 MD5 不同，说明原厂对 libc 做过定制构建。符号比对显示所需 libc 符号全部存在，但这只是静态结论；真实加载要在设备上验证（写操作，属 S6，需单独授权）。
4. **随包第三方库的体积与许可**：41 MiB 中 `lib/` 占 32 MiB，含 GnuTLS/Nettle/GMP/hogweed。发布前需核对这些库的再分发条件与对应源码；S1 只在实验室使用。
5. **未 strip**：`nmbd` 等含调试信息，体积可再压缩；不影响功能，但会影响落位空间评估。
6. **内核 2.6.36 未验证**：QEMU 用的是宿主内核，文件锁、inotify、sendfile、线程模型等仍需 S6 实机确认。

## 复现步骤

```bash
# 1. 仓库外准备：官方 SDK 解压出的 toolchain、4.25.1 源码包与签名
# 2. 进入 linux/amd64 容器，挂载 toolchain 为 /toolchain、工作树为 /work
# 3. 构建依赖（zlib 1.4 → gmp 6.3.0 → nettle 3.10.2(含 hogweed+gmp) → gnutls 3.8.13）
#    统一 CFLAGS='-Os -fPIC -march=armv7-a -mfloat-abi=soft'
#    gnutls 需 -include static_assert shim（见上表）
# 4. 全新解压 samba-4.25.1.tar.gz，应用 5 个补丁
# 5. 导出 PATH=/toolchain/bin:$PATH 与 SAMBA_CODEGEN_EXECUTOR
# 6. ./configure（参数见上）→ make -j → make install DESTDIR=<仓库外前缀>
# 7. 补 4 个第三方库到 <前缀>/lib，再跑版本、testparm 与启动检查
```

构建脚本、日志与安装树都在仓库外，不提交；仓库只保留本记录与散列。厂商工具链与二进制不随仓库分发。

## 决策记录

| 决策 | 理由 |
| --- | --- |
| 用 4.25.1 而非 4.23.13 继续 | 4.23 已进入仅安全更新阶段，S1 目标是当前 stable |
| `--libdir=/opt/samba-next/lib` | 避免宿主 x86_64 默认 `lib64` 造成布局漂移，与设备 `/usr/lib` 惯例一致 |
| 公共库/私有库/模块同树安装 | 设备无包管理器，单树落位便于整体替换与回滚 |
| `--disable-python` | 目标无 Python 运行时；代价是放弃 `samba-tool`，文件服务不受影响 |
| `--without-winbind/ads/ldap/ad-dc` | 设备是 standalone 文件服务，先缩小攻击面与体积；winbind 相关缺口已单列 |
| `--bundled-libraries=ALL` + 外部 GnuTLS | 内部库全部静态进树，加密栈用上游最新且可追溯版本 |
| 保留 5 个旧补丁 | 逐个验证仍适用于 4.25.1，不盲目新增补丁 |
| 构建产物不 strip | 先保证可诊断性；体积优化留到打包阶段 |
| 构建脚本与安装树留在仓库外 | 不分发厂商工具链二进制，仓库只记录可复现要素 |
