# Samba 实验状态

小米官方 SDK GCC 4.8.2、ARM32/uClibc 0.9.33.2 环境下，上游 Samba 4.23.13 已完成交叉构建；在 Ubuntu 宿主的 QEMU 和原厂 libc 隔离环境中，Emby 目录、账户访问和 SMB 3.1.1 加密文件读取通过。真实路由器 Linux 2.6.36 内核尚未验证。4.23 已进入仅安全更新阶段，后续目标为 [4.25.1](https://www.samba.org/samba/history/)，尚未构建。

存在未完成的厂商兼容：MAC 授权策略、摄像机 readonly VFS、shareUpdate、热插拔及 WiFi 管理控制。离线策略模型只表达逆向分析的核心分支，不包含 IPC$、地址到 MAC、完整认证和 Samba 其他检查，不用于生产。

`recipes/samba` 为 4.23.13 增量实验快照，包含硬编码的 `/work`、`/toolchain` 和 `/qemu-arm` 路径，需要自备官方 SDK 和第三方源码；并未从干净环境完整重建，不能视为一键安装脚本。第三方补丁目录按上游许可证分开。未发布固件或二进制；SDK 和固件的再分发权限尚待核验。

[小米官方 SDK 下载地址](https://bigota.miwifi.com/xiaoqiang/sdk/tools/package/sdk_package.zip)。不要将该软件覆盖生产路由器。
