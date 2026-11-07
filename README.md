# MiWiFi Legacy Packages

面向小米路由器 R2D 旧版官方固件的社区软件包研究与构建项目。目标是为旧设备提供可审计、可复现、能持续更新的独立软件包，同时研究小米 WiFi 相关功能的兼容性。

**当前状态：研究阶段，无可供安装的软件包。请勿替换路由器原厂程序。** 本项目与小米没有官方关联。

- [设备软件清单及升级优先级](docs/inventory.md)
- [Samba 实验与构建边界](docs/samba.md)
- [许可证及第三方代码](THIRD_PARTY.md)
- `tools/policy.py` 是离线模型，不能作为真实权限控制使用。

## 验证

```sh
python3 -m unittest discover -s tools -v
```

根目录 LICENSE 适用于本项目原创代码，具体第三方补丁按 THIRD_PARTY.md 标注；上游软件各自保持其原许可证。此仓库不包含小米 SDK、固件镜像或原厂二进制。
