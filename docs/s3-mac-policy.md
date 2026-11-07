# S3 小米 MAC 策略适配

本轮只做 S3：把原厂 `samba_multicall` 的 MAC 访问控制语义在 Samba 4.25.1 隔离实例上恢复，并给出接口取舍、覆盖表、真值表、最小补丁、负向集成测试与阻塞项。未进入 S4。

## 1. 原厂语义（S0 基线的可执行化）

反汇编结论（`docs/baseline/mac-policy.md`，本轮按 `objdump` 重新核对）：

- `0x1ca140` `mac_in_list(list, mac)`：读 `/tmp/loginMac.cfg` 与 `/userdisk/datacenterConfig/nonLoginMac.cfg`，逐行去空白后 `strcmp`（大小写敏感），命中返回 0。
- `0x1ca258` `can_access_and_browse(mac, snum)`：命中列表 → 仅允许 `browseable = no` 的共享；未命中 → 仅允许 `browseable = yes` 的共享。即 XOR。
- `0x1cab08` `allow_access_internal_from_macfilter(snum)`：`snum == -1`（连接级）直接允许；`lp_servicename(snum) == "IPC$"` 直接允许；否则取远端 MAC 调 `0x1ca258`。
- `0x1ca92c`/`0x3200d0` MAC 获取顺序：内存缓存 `ip_mac` → `ubus call trafficd ip | jason.sh -b`（MAC 大写）→ `/proc/net/arp` → `arping -f -c 2 -w 1 -I br-lan <ip>`，成功后回写缓存。判定前统一转小写，因此列表条目必须小写才命中。

真值表（实现与测试都按此表）：

| MAC 可解析 | 列表命中 | 共享 browseable | 结果 |
| --- | --- | --- | --- |
| 是 | 是 | 否 | 允许 |
| 是 | 是 | 是 | 拒绝 |
| 是 | 否 | 是 | 允许 |
| 是 | 否 | 否 | 拒绝 |
| 否 | — | 是 | 允许 |
| 否 | — | 否 | 拒绝（解析失败不得授予整盘） |
| IPC$ / `snum < 0` | — | — | 允许 |

## 2. 接口方案比较与取舍

| 方案 | 能覆盖 tree connect | 能覆盖 NetShareEnumAll | 能覆盖 SMB1 RAP 枚举 | 代价/风险 |
| --- | --- | --- | --- | --- |
| 内部窄补丁（`share_sanity_checks` + srvsvc + RAP 循环） | 是 | 是 | 是 | 3 处判定点 + 1 个新模块；无外部进程 |
| VFS 模块 | 只能拿到 `connect_fn`，无法表达“枚举过滤”；且枚举路径不经过 VFS | 否 | 否 | 需要额外 .so、配置加载，覆盖不全 |
| 外部策略接口（IPC/守护进程） | 是 | 是 | 是 | 每连接/每枚举 IPC 延迟，新增失败模式；与原厂“进程内 helper”不一致 |

结论：选内部窄补丁。理由是可覆盖全部三条入口、行为与原厂同层（tree connect 时判定）、不引入外部依赖。VFS 方案在枚举上不可达，单独使用会漏掉“共享枚举”入口，放弃。

## 3. 实现

新增 `source3/smbd/xiaomi_mac_policy.{c,h}`（约 455 行），提供：

- `xiaomi_mac_share_allowed(remote, snum)`：连接/树连接判定（IPC$、`snum < 0` 放行；解析失败按未命中处理）。
- `xiaomi_mac_share_visible(remote, snum)`：枚举过滤（用 `browseable` 语义替换 `lp_browseable()`）。
- `xiaomi_mac_filter_enabled()`：未配置时默认开启，便于批量部署。

配置全部走环境变量，不改 loadparm 参数表：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `XIAOMI_MAC_FILTER` | 开 | `0/off/disabled` 关闭 |
| `XIAOMI_LOGIN_MAC_FILE` | `/tmp/loginMac.cfg` | 登录列表 |
| `XIAOMI_NONLOGIN_MAC_FILE` | `/userdisk/datacenterConfig/nonLoginMac.cfg` | 非登录列表 |
| `XIAOMI_ARP_FILE` | `/proc/net/arp` | ARP 回退 |
| `XIAOMI_ARP_INTERFACE` | `br-lan` | arping 接口 |
| `XIAOMI_TRAFFICD_CMD` | `ubus call trafficd ip \| jason.sh -b` | 可设 `none` 关闭 |
| `XIAOMI_MAC_CACHE_TTL` | `60` | IP→MAC 缓存秒数，0 表示不缓存 |

判定点：

1. `source3/smbd/smb2_service.c` `share_sanity_checks()`：`allow_access()` 之后插入策略判定，拒绝返回 `NT_STATUS_ACCESS_DENIED`。
2. `source3/rpc_server/srvsvc/srv_srvsvc_nt.c` `init_srv_share_info_ctr()`：枚举计数与填充处用 `xiaomi_mac_share_visible()` 替换 `lp_browseable()`。
3. `source3/smbd/smb1_lanman.c` 两个 `NetShareEnum` 循环：同上替换 4 处。

补丁：`recipes/samba/patches/samba-s3-mac-policy.patch`（对 4.25.1 原树 `patch -p1 --dry-run` 通过，无 fuzz）。应用顺序：先应用 `apply-samba-patches.sh` 的 5 个基线补丁，再应用本补丁。

## 4. 测试环境与前置状态

- 实例根：`/userdisk/data/samba-s2/root`（复用 S2 布局），`lock/state/cache/private` 全在新根；根分区只读，未写入 `/`。
- 监听：`192.168.3.2:1445`，不启 nmbd，未占用 139/445/137/138。
- 原厂只读前态：`samba_multicall` MD5 `5e422d3463f40b4405ef8325ce3603e8`，`/etc/config/samba` MD5 `244eb53e5019b95a408aebe49602561a`（mtime 2018-10-16），smbd/nmbd 监听 139/445/137/138，根分区 81%。
- 测试期对自有实例配置做的便利项：`server signing = no`、`map to guest = Bad User`、本地 passdb 加 `nobody`、`log level = 5`。这些只用于让测试客户端完成认证，不进入产品建议。
- 设备 MAC `f0:b4:29:2b:80:41`；测试 PC（macOS）`192.168.3.176`，MAC `5c:9b:a6:95:d0:07`（trafficd 输出大写）。

## 5. 测试结果

### 5.1 本地 QEMU（10 项，全 PASS）

覆盖：小写命中放行 non-browseable、大写不命中、MAC 变化后拒绝、ARP 文件缺失/垃圾内容拒绝、列表路径为目录拒绝、filter 关闭放行、nonLogin 命中放行、未命中只放行 browseable。

### 5.2 设备矩阵（14 项，全 PASS）

以设备自连 `192.168.3.2:1445` 为客户端，用 `XIAOMI_ARP_FILE=<测试文件>` + `XIAOMI_TRAFFICD_CMD=none` 精确控制 MAC 来源：

| 用例 | 期望 | 结果 |
| --- | --- | --- |
| 未命中：pub 可访问 | 列表内容可见 | PASS |
| 未命中：full 拒绝 | `NT_STATUS_ACCESS_DENIED` | PASS |
| 命中（小写）：full 允许 | `full.txt` 可见 | PASS |
| 命中：pub 拒绝 | `NT_STATUS_ACCESS_DENIED` | PASS |
| 命中：枚举只出现 full | 枚举含 `full` | PASS |
| 命中：枚举不出现 pub | 枚举无 `pub` | PASS |
| 大写条目不命中 | full 拒绝、pub 允许 | PASS |
| MAC 变化（IP 复用） | 命中失效 | PASS |
| ARP 垃圾内容 | 解析失败，full 拒绝、pub 允许 | PASS |
| 中文文件名 `中文文件名.txt` | 能被列出 | PASS |
| nonLogin 列表同样生效 | full 允许 | PASS |

### 5.3 真实远端客户端（macOS，经 trafficd）

用 Python `smbprotocol` 从 `192.168.3.176` 连 `192.168.3.2:1445` 做 tree connect：

- 列表为空：`pub` TREE_OK，`full` ACCESS_DENIED。
- 列表写入 `5c:9b:a6:95:d0:07`：`pub` ACCESS_DENIED，`full` TREE_OK。
- 服务端日志证明 MAC 由 trafficd 解析并归一为小写：

```
xiaomi-mac-policy: Allowed connection from 192.168.3.176 to [pub] (snum 0, mac 5c:9b:a6:95:d0:07, browseable yes, listed no)
xiaomi-mac-policy: Denied connection from 192.168.3.176 to [full] (snum 1, mac 5c:9b:a6:95:d0:07, browseable no, listed no)
share_sanity_checks: xiaomi mac policy denied connection from 192.168.3.176 to share full
```

- 关闭 ARP 回退（`XIAOMI_ARP_FILE=/tmp/no-such-arp`、`XIAOMI_ARP_INTERFACE=none`）后重复上述两态，结果不变，确认解析来自 trafficd 而非 `/proc/net/arp`。
- `5.2` 的枚举用例走 srvsvc（`NetShareEnumAll`），SMB1 RAP 路径只做了代码挂钩，未在设备上用 SMB1 客户端验证（见阻塞 3）。

### 5.4 撤销与已连会话

- 会话以“命中”状态建立并打开 `full`，中途清空列表：同一会话内第二次 `ls` 仍然成功（已连会话不被踢）。
- 同时新建连接：`full` 立即被拒，`pub` 立即放行。
- 与原厂对照：原厂判定点在 tree connect（`0x305d64`/`0x30b5f0`），同样是“连接建立后不回查、后续新连接按新列表”，代码级等价；原厂撤销的实机复现会改写生产列表，标 BLOCKED（见阻塞 4）。

## 6. 阻塞与限制

1. **macOS Finder/`mount_smbfs` 走非 445 端口：BLOCKED。** `smbutil view -p`/`mount_smbfs -p` 无端口参数；`//guest@192.168.3.2:1445/share` 的 URL 端口形式能被解析并连到本实例（服务端日志有 `Negotiated protocol SMB3_11`），但客户端在 session setup 后被重置或挂起；原厂占 445 且本轮不允许停原厂，因此无法用 Finder 挂载作为证据。等价的“共享枚举 + 直接访问 + 认证后 tree connect”已用 SMB2/3 客户端覆盖。
2. **IPv6：未实测。** 本实例只监听 IPv4，`::ffff:` 归一逻辑仅代码审查覆盖；若后续启用 IPv6 监听需补实测。
3. **SMB1 RAP 枚举：仅代码挂钩。** 设备实例未开 SMB1 客户端用例；SMB2/3 枚举已实测。
4. **原厂撤销实机对照：BLOCKED。** 需要在原厂运行时改写 `/tmp/loginMac.cfg` 或 `nonLoginMac.cfg`，属于生产列表写操作，本轮不做，只给代码级等价结论。

## 7. S2 两个异常的结论

- **TDB robust mutex level 0**：内核 2.6.36 + uClibc 组合下不可用，Samba 回落到 fcntl 锁，只影响并发 TDB 访问的健壮性。S3 的判定不依赖 TDB（列表是普通文件、MAC 缓存为进程内内存），本轮全部用例在告警存在的情况下通过，结论：不阻塞 S3 判定；保留为并发压测检查点。
- **CP850 回落 ASCII**：只影响非 UTF-8 代码页的 SMB1 名称换算；SMB2/3 使用 UTF-16，实测 `中文文件名.txt` 正常列出。结论：对 S3 判定无影响。

## 8. 回滚与核对结果

测试结束已执行：停自有 smbd/helper → 删除 `/userdisk/data/samba-s2` 与上传包 → 确认 1445 关闭、无 `samba-s2` 进程与文件。核对：

| 项目 | 测试前 | 结束后 |
| --- | --- | --- |
| `samba_multicall` MD5 | `5e422d34…03e8` | 同 |
| `/etc/config/samba` MD5 | `244eb53e…561a` | 同（mtime 未变） |
| 原厂监听 | 139/445/137/138 | 同 |
| 原厂 nmbd PID | 8469 | 8469 |
| 根分区 | 81% | 81% |
| S3 端口 1445 | 未占用 | 未占用 |

**事故记录（如实）**：测试中一次清理脚本用 `sbin/smbd -D` 作为匹配串，误匹配到原厂 `/usr/sbin/smbd -D`，导致原厂 smbd 主/子进程被结束并由设备监督进程自动重启（原 PID 集合 2117/7577/8471/13548/25469/28587 → 现 1448/1521/4675）。原厂二进制与配置未改、nmbd 未被触碰、139/445 已恢复监听。后续所有启停只匹配 `samba-s2/root/etc/s` 路径。

## 9. 产物

- 补丁：`recipes/samba/patches/samba-s3-mac-policy.patch`，SHA-256 `4aea3cefd6c6ea36db0b3b08f0a519c294dd0941bd2507dbea30d83ab6bbb772`。
- 部署包（已删）：`s3-root.tar.gz`，14,513,779 B，SHA-256 `121afa9550f8fba36d7cf25fdff8c0f4184b87ec4e8dea68a9484e619f601a28`。
- 本版 `smbd` MD5 `52e105576e190ab6b977be419b3144fe`，`libsmbd-base-private-samba.so` MD5 `8cb07989b7dc02660a27f3ecd3f7ad90`。

## 10. 下一步（未执行）

S4 及后续不在本轮范围。
