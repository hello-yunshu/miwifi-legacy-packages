# SMB 1.0.7-r2d 升级审计

- 目标：MiWiFi R2D / 固件 2.25.209
- 审计日期：2026-11-09
- 范围：1.0.7-r2d 包身份、Samba 运行状态、磁盘访问 ACL、访客网 SMB 防护、同步/恢复、证据与文档一致性
- 方法：审阅仓库脚本、差异和设备侧既有证据；**本次没有连接或改动设备，也没有重新运行测试**
- 主证据：[设备安装记录](../evidence/2026-11-09-diskacl/install-1.0.7-run.txt)、[安装后快照](../evidence/2026-11-09-diskacl/install-1.0.7-post-snapshot.txt)、[重启服务复核](../evidence/2026-11-09-diskacl/restart-selfcheck-1.0.7.txt)、[cron 自愈实测](../evidence/2026-11-09-diskacl/cron-guest-healthcheck-1.0.7.txt)、[离线回归记录](../evidence/2026-11-09-diskacl/offline-test-device-busybox1194.txt)

## 1. 总结

**判定：有条件通过；SMB 服务升级已在设备运行，1.0.7 的访客防护规则面和恢复路径通过；访客侧端到端连接测试因无线驱动无法创建访客 BSS 而 BLOCKED，升级后整机重启验证仍缺。另外，客户端枚举会显示 `homes` 共享，配置来源已查明，但该共享的实际内容访问权限尚未验证。**

需要区分两个版本维度：

- SMB 服务本体是 Samba **4.25.1**，通过 `/userdisk/data` 私有运行树提供 139/445。
- **1.0.7-r2d 不是 Samba 源码版本升级**。它由 1.0.6 派生，Samba payload 未变；本次包的改动是兼容层访客网 ACL 与自愈逻辑。设备日志记录 smbd MD5 `52e105576e190ab6b977be419b3144fe`，与已验证的 Samba 4.25.1 产物一致。

## 2. 证据核对

| 核对项 | 证据与结果 | 审计判断 |
|---|---|---|
| 1.0.7 版本身份 | 决策记录包含包 SHA-256 `38c0cb1c14bedb88368a3d66172caca1e2430234a2fe534fe6324298e603fbf0`；设备目录、VERSION 与载荷/兼容层 MD5 为 `1.0.7-r2d` | 设备文件身份吻合；安装日志没有记录输入 tar 的 SHA-256，后续安装应把包散列写入安装日志 |
| Samba payload 是否改变 | 1.0.7 中 `payload/samba-tree.tar.gz` SHA-256 `0101e0a7d786c5b6ca5740720ff03cb6ba48ce0d45dd5473f54318f2e6eb2d58`，沿用 1.0.6；设备 smbd MD5 `52e105576e190ab6b977be419b3144fe` | SMB 4.25.1 服务已部署；1.0.7 更新的是兼容层，不是 smbd |
| 设备安装与端口 | 安装日志记录停服务、解包、激活 `1.0.7-r2d`、启动成功；139/445 归 `samba-s5d`，绑定 `192.168.3.2` | 安装路径和当前监听证据通过 |
| per-device ACL | LAN TCP 139/445、UDP 137/138 跳转到 `s8-diskacl`；`lan=no` MAC 被 DROP、链尾 RETURN；`yes→no` 重启后约 10 秒生效，`no→yes` cron 同步实测约 22 秒 | 名单内拒绝与恢复有实机证据；未知状态不全局 DROP |
| 正常客户端 | 不在 DROP 名单的 macOS 主机成功 `smbutil view`、挂载、列目录和卸载 | 共享访问正向路径通过 |
| `homes` 共享 | UCI `homes=1`；适配器生成 `[homes]`（comment `Home Directories`、`browseable=no`、`read only=no`、`create mode=0750`）；macOS 枚举记录显示 `homes` | 确认为配置启用的 Samba 特殊 home-share，不是磁盘上意外多出的普通目录；是否能连接/读写仍未知 |
| 访客规则 | `br-guest` 上 TCP 139/445 的无条件 DROP 位于原厂全接口 ACCEPT 之前；安装后和 Samba restart 后状态均为 `diskacl_guest=enforced` | 规则位置、接口范围、服务重启后的保持有实机证据 |
| cron 自愈 | 删除访客 DROP 后约 50 秒恢复，健康检查显示 `enforced` | 缺规则的自动恢复有设备实测 |
| 离线回归 | 保存的日志显示 32 cases / 135 assertions / 0 failures；含 rule ordering、幂等、refused、clear、缺规则恢复、错位修复及无 `macfilter` 情况 | 有较全面的模型回归；本轮只审阅日志，未重新运行 |

## 3. 代码审计结论

### 3.1 做得正确的部分

- 访客设备不依赖 `macfilter`：规则直接按 `br-guest` 限定，不会因访客随机 MAC 不在名单中而漏拦。
- 访客 DROP 明确限制接口和 SMB TCP 端口，并放在原厂宽泛 ACCEPT 之前；它不会拦 LAN 或其它接口。
- 访客规则独立于 per-device 链；后者尾部 `RETURN` 不会意外让访客流量穿过。
- `diskacl-sync.sh` 在名单文件缺失时仍检查访客规则，在规则缺失或位于 ACCEPT 之后时调用 adapter 修复。
- 设备链与访客规则均采用“只改自有规则”的方式；clear 删除项目自有规则和旧危险链，不 flush 整个 INPUT。
- 1.0.7 的 Samba payload 未变，降低了本次兼容层变更与 Samba 协议实现变更同时发生的风险。

### 3.2 剩余风险和限制

1. **访客侧端到端访问 BLOCKED。** 已尝试启用 `guest_2G` 并执行 `wifi up`，但 Broadcom 驱动返回 `WLC_SET_VAR(bss): Invalid argument`，`wl1.2` 未创建，`br-guest` 始终无成员。配置已恢复为禁用状态。规则位置和自愈已有实机证据，但没有访客客户端实际访问 `139/445` 后被拒绝的记录；restart 快照中访客 DROP 计数仍为 0。
2. **IPv6 不在这条规则覆盖范围内。** 代码使用 IPv4 `iptables`，没有配置 `ip6tables` 对应规则。当前 SMB 生产绑定和现场 IPv6 条件限制了实际路径，但计划/产品文案应避免宣称此规则覆盖 IPv6。
3. **1.0.7 后的完整设备冷启动未见证据。** 当前证据覆盖安装、Samba restart、cron 同步，不覆盖升级后整机重启时 `br-guest` 创建顺序、cron 行持久性、SMB 和管理入口的整体恢复。
4. **错误恢复行为是保守的。** 如果检测到 `br-guest` 但无法创建/校验访客 DROP，`diskacl-apply` 会返回错误并停止后续名单 ACL 更新；旧链可能继续生效。此时访客隔离失败会明确报错，但用户设备 `lan=yes/no` 变更也可能暂时不同步。需在运行手册中要求检查 adapter log、INPUT 规则和 sync cron，而不能只看 Samba 进程仍在运行。
5. **现有访客规则只阻断 SMB TCP 139/445。** 仓库记录 UDP 137/138 由原厂 guest zone 拦截；应继续把这项作为固件基线假设，若防火墙规则变化需重新核实。

### 3.3 `homes` 共享

- 客户端枚举中的 `homes` **确实存在**。来源是持久 UCI 选项 `samba.@samba[0].homes=1`；适配器在此值为真时明确输出 `[homes]`，注释为 `Home Directories`。升级包 1.0.7 的改动不是新增此行为；原厂配置已有 `homes=1`，而 1.0.7 未改 Samba payload。
- 它是 Samba 的特殊 home-directory 服务段，不等同于某个额外普通目录。Samba 文档说明 `[homes]` 会按已认证用户动态映射其 Unix home；配置未给该段指定固定 `path`。([Samba `smb.conf` 文档](https://www.samba.org/samba/docs/current/man-html/smb.conf.5))
- 现有证据能证明客户端列表中看到它，**不能证明匿名/guest 能连入，也不能证明用户 home 内容可读或可写**。配置中的 `browseable=no` 不是访问控制，不能仅凭该选项判定安全；也不能仅凭枚举判定数据已泄露。
- 计划动作：先核实有效用户、Unix home 路径及 Samba passdb；在得到维护授权/适当测试条件后，分别测 guest 和有效用户对 `homes` 的 tree connect、目录内容和写入。若产品不需要该服务，再设计禁用 `homes` 的变更并验证普通共享与原厂 App 逻辑不受影响。

## 4. 文档一致性问题

审计发现 D-S9-10 的“装机需另行确认”与设备安装证据不一致；文档现已改为记录 1.0.7 已安装，并新增 D-S9-11 记录安装后状态、访客规则恢复测试和访客端到端 BLOCKED 原因。未 commit/push/tag 的事实保留。

较早的设备清点和 S8/S9 文档是历史快照。它们的 Samba 包版本、nmbd 状态和防火墙状态不能替代本次 1.0.7 设备快照；尤其 nmbd 当前 binary 仍需单独核对。

## 5. 发布准入和下一步

当前可维持 1.0.7 在设备上运行；不据此宣称访客隔离已完成全路径验收。建议按以下顺序补证：

1. 在有安全测试条件时核实 `homes`：确认对应 UNIX 用户、home 路径、passdb 状态；分别检查 guest/有效用户连接、列目录和写入权限。若不需要，决定是否将 `homes=0`，再单独包版本化、回归及回滚。
2. 在能实际创建访客 BSS 并接入访客网的设备上测试 TCP 139/445：确认客户端连接失败且 INPUT DROP 计数增长；从 LAN 正常客户端再次枚举并挂载共享。不要为了补测继续改动这台设备的无线配置。
3. 在维护会话和回滚路径已确认后，做一次整机重启；复核 139/445 进程身份、访客 DROP 位置、cron 行/进程、per-device 链、SSH 22 和 Web 80。
4. 将冷启动与可完成的客户端证据归档；若访客 BSS 仍不可用，保留 BLOCKED。若访客网有 IPv6 地址或 IPv6 SMB 服务，再单独设计 IPv6 验证。

未完成上述验证前，状态建议写为：**1.0.7-r2d 已安装，Samba 4.25.1 运行正常，访客 SMB IPv4 规则部署并自愈通过；访客客户端阻断因 Broadcom 驱动无法创建 BSS 而 BLOCKED，`homes` 内容访问权限待验，升级后整机重启待验。**

