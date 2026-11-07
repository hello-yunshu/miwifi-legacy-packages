# Samba 实验状态

小米官方 SDK GCC 4.8.2、ARM32/uClibc 0.9.33.2 环境下，上游 Samba 4.25.1 已完成干净交叉构建：全新源码树 + 空输出目录，`configure`/`build`/`install` 全部成功，产物可报版本、`testparm` 通过、`smbd` 在 QEMU + 原厂 libc sysroot 下启动。详见 [S1 干净构建记录](s1-clean-build.md)。真实路由器 Linux 2.6.36 内核尚未验证，产物状态为 lab。

此前的 4.23.13 实验为增量修复构建，不作为 S1 成果，仅保留在 `recipes/samba` 作参考。

存在未完成的厂商兼容：MAC 授权策略、摄像机 readonly VFS、shareUpdate、热插拔及 WiFi 管理控制。离线策略模型只表达逆向分析的核心分支，不包含 IPC$、地址到 MAC、完整认证和 Samba 其他检查，不用于生产。

`recipes/samba` 为 4.23.13 增量实验快照，包含硬编码的 `/work`、`/toolchain` 和 `/qemu-arm` 路径，需要自备官方 SDK 和第三方源码；并未从干净环境完整重建，不能视为一键安装脚本。第三方补丁目录按上游许可证分开。未发布固件或二进制；SDK 和固件的再分发权限尚待核验。

[小米官方 SDK 下载地址](https://bigota.miwifi.com/xiaoqiang/sdk/tools/package/sdk_package.zip)。不要将该软件覆盖生产路由器。

## 官方 SDK 归档记录

2026-11-07 重新从官方地址下载并核对，归档本体保存在仓库之外，不进入 Git：

| 项目 | 记录 |
| --- | --- |
| 来源 | `https://bigota.miwifi.com/xiaoqiang/sdk/tools/package/sdk_package.zip`（HTTP 200，无账号或授权要求） |
| 大小 | 146,743,834 字节 |
| SHA-256 | `6831c2bb92a1bed8eda5a22874c8f4e1897cf27f221f51ad691fec13fcf074ec` |
| 内容校验 | `unzip -t` 通过；13,654 个条目；解压后约 487,896,423 字节 |
| 工具链 | `sdk_package/toolchain/arm-xiaomi-linux-uclibcgnueabi`，GCC 4.8.2；运行库 `libc.so.0`、`ld-uClibc-0.9.33.2.so` |
| Samba 源码 | 归档内无 Samba 源码，Samba 仍取上游源码归档 |
| 本地存放 | 仓库外归档目录（研究归档 `build/` 同级），不同步、不提交 |

该地址与 2026-11-07 先前研究归档中的副本逐字节一致（同一 SHA-256），说明本次下载未引入新版本或镜像差异。归档只作构建工具链使用；厂商二进制与工具链不随仓库分发，再分发权限仍未核验。
