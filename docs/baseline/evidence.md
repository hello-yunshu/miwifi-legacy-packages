# 证据索引

基线日期 2026-11-07。证据本体保存在本机研究档案（与仓库同级的 `research/`、`build/` 及项目研究笔记），**不随公开仓库分发**，原因是其中含厂商 ROM、厂商程序、构建产物与现场摘要，再分发权限尚未核查。下表给出可核对的散列与公开上游来源。

## 证据编号

| 编号 | 内容 | 位置（本地档案） | 公开性 |
| --- | --- | --- | --- |
| E1 | 现场只读审计：init 链路、manifest、配置校验值、MAC 列表成员关系、sysapi、445 监听、日志级别 | 项目研究笔记 `xiaomi-smb-management-audit.md` | 摘要公开；原始输出不公开 |
| E2 | 现场 `samba_multicall` 与反汇编：完整反汇编、MAC 策略、访问钩子、摄像机只读片段 | `research/device/` | 厂商二进制不公开 |
| E3 | Emby mechListMIC 隔离诊断与对照实验 | 项目研究笔记 `smb-diagnosis.md` | 摘要公开 |
| E4 | 官方 ROM 下载、拆包与隔离认证对照 | `research/roms/`、笔记 `xiaomi-rom-smb-donor-research.md` | ROM 不公开；散列公开 |
| E5 | 官方 SDK 构建 Samba 4.23.13 与 Emby/加密读取回归 | `build/artifacts/`、笔记 `xiaomi-sdk-samba-build-report.md` | 产物不公开；散列与结果摘要公开 |
| E6 | 上游 Samba 源码、VFS 头文件与访客 MIC 修复提交 | `research/upstream/`，另见下方链接 | 公开 |
| E7 | 官方 ROM 2.24.11 样本静态文件：init、UCI 配置、模板、shareUpdate、opkg 元数据 | `research/roms/R2DSTA-extracted/` | 厂商内容不公开 |
| E8 | 本仓库离线策略模型与单元测试 | `tools/policy.py`、`tools/test_policy.py` | 公开 |
| E9 | 2026-11-07 现场只读采集：系统、内存、磁盘、进程、端口、库散列、`testparm`、MAC 列表格式、ARP、`/proc/<pid>/maps` | `research/s0-live/01-system.txt` … `13-maps.txt` | 脱敏摘要公开；原始输出不公开 |

## 本轮复核命令与结果

以下命令在 2026-11-07 于本机执行，用于防止文档照抄未经核对的历史结论。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 现场程序散列 | `shasum -a 256`、`md5` | SHA-256 `6709018c…f620f2`；MD5 `5e422d34…3603e8`；4,325,084 字节 |
| ELF 类型 | `file`、`objdump -f` | ELF 32 位小端 ARM EABI5、动态链接、解释器 `/lib/ld-uClibc.so.0`、strip、入口 `0xc454` |
| 动态依赖 | `objdump -p … \| grep NEEDED` | 10 个 NEEDED：`libaio.so.1`、`libdl.so.0`、`libubus.so`、`libubox.so`、`libcrypt.so.0`、`libresolv.so.0`、`libpthread.so.0`、`libz.so.1`、`libc.so.0`、`libubacktrace.so.0` |
| MAC 列表路径 | `strings -a … \| grep loginMac` | `/tmp/loginMac.cfg`、`/userdisk/datacenterConfig/nonLoginMac.cfg` 均存在 |
| 摄像机日志 | `strings -a …` | `create file failed caused by readonly timerange limit.` 存在 |
| 关键地址 | 在 `disassembly.txt` 中定位 | `0x1ca140`、`0x1ca258`、`0x1cab08`、`0x1cad7c`、`0x2274a8`、`0x22749c`、`0x2275e4` 均存在 |
| VFS 接口版本 | `grep SMB_VFS_INTERFACE_VERSION` | 4.0.21 为 30；4.18.0 为 48 |
| 样本 shareUpdate 符号 | `strings … \| grep` | `sUpdateSambaConfigFile`、`sModifySambaAccessControl`、`sModifySambaAccess`、`sReloadSamba`、`sRestartSamba`、MiniDLNA 相关字符串均存在 |
| 样本包记录 | 读取 `samba4-server.control` | 版本 4.0.21-1，架构 brcm4709；同一状态标记为 not-installed，但镜像内有程序 |
| 仓库测试 | `python3 -m unittest discover -s tools -v` | 1 个测试通过 |

## 样本与实验散列

| 对象 | 散列 |
| --- | --- |
| 样本 `shareUpdate` | SHA-256 `62d231bad65f5cc38037e699429897a44547bb97256c8908d79d2094bbdeeb9a`，260,936 字节 |
| R2D 2.24.11 样本程序 | SHA-256 `546a0cb6f8a9c130a1cccbc031f39d0258e1512ed50c08cb3a317e076aaedefe` |
| R3D 样本程序 | SHA-256 `774f093a44c3dd73ef73108b1f979a1203e2de7f9196abafa56f5e7f6eff0ada` |
| AX9000 样本程序 | SHA-256 `e16fa1e733a44e8ed0d0c1d8e30b1635228765304f99b16bb07c7d97879e883b` |
| Samba 4.23.13 实验包 | `02ac6439905f1201ec106e51b75e67132cee869d90f4b9e002839e2d4aaffd9e` |
| 实验读取文件 | SHA-256 `fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83`（访客与加密读取一致） |
| 构建容器镜像 | `ubuntu:24.04 sha256:d9b8c34d61a9b9a3c44cab883d7d2f2619d674966ab520186f799cf32e3e0377` |

## 隔离实验结论（E3、E5）

- 现场原厂 Samba：Emby 4.10.2.0 在访客映射后于 mechListMIC 校验返回 `0xc000000d`，HTTP 500；临时回环对照删除该字段后变 HTTP 200 并列出条目，证明阻断点，不作为修复。
- 4.23.13 实验服务：访客目录、存在检查、账户目录、错误密码拒绝、私有共享拒绝访客、SMB 3.1.1 访客读取、强制加密读取均通过；完整播放未测。
- 实验使用 Ubuntu 宿主内核与 QEMU，不能提升为真实 R2D 内核或性能证据。

## 上游来源

- Samba 4.0.21 `auth/gensec/spnego.c`、`source3/modules/vfs_readonly.c`、`source3/include/vfs.h`
- Samba 4.18.0 `auth/ntlmssp/ntlmssp_server.c`、`auth/gensec/spnego.c`、`source3/include/vfs.h`
- 访客 MIC 修复提交 `d667520568996471b55007a42b503edbabb1eee0`、`65462958522baee6eedcedd4193cfcc8cf0f510e`
- 上游发布历史 <https://www.samba.org/samba/history/>

## 已知局限

1. E1—E5、E7 的原始材料不在公开仓库，外部无法逐字节复现；本仓库只提供散列与结论摘要。
2. E5 是增量修复后的构建，未从全新目录做完整重跑；不能算作 S1 的干净构建证据。
3. 现场运行基线（内存、磁盘、进程参数、库散列）已由 E9 补齐；动态权限行为（检查顺序、撤销即时性、列表写入者）仍无法用只读方式观测。
4. 所有隔离实验使用宿主内核，未验证 Linux 2.6.36。
