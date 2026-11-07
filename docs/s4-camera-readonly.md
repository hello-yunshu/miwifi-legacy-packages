# S4：摄像机 readonly 适配

**状态（2026-11-08）**：已在 Samba 4.25.1 上复刻原厂 `readonly` VFS 行为，并用原厂二进制第二实例、新版隔离实例、SMB1/SMB2/SMB3.1.1 客户端完成对照。真实摄像机接入仍为 **BLOCKED**（无设备，且原厂固定占用 445）；macOS Finder/mount_smbfs 非 445 端口挂载继承 S3 的 BLOCKED。未进入 S5。

本轮只做 S4。约束与原阶段相同：运行根在 `/userdisk`，`lock/pid/private/state/cache` 全部隔离；不替换 `samba_multicall`、不改 `/etc/config/samba`、不停止/重启原厂 `smbd`/`nmbd`；测试实例只用独立端口（原厂二进制对照 1446，新版实例 1445）；所有停止操作按 PID 文件或精确目录，未使用通配式杀进程。

## 1. 原厂合同（反汇编）

对象：`samba_multicall`（MD5 `5e422d3463f40b4405ef8325ce3603e8`），符号/反汇编资产在 `research/device/`。

### 1.1 注册与接口

- 注册入口 `0x2275e4`：`smb_register_vfs(30, "readonly", fns)`，`fns` 表在 `0x42aab0`。
- `fns` 表只有一项非零：`+0x50` → `0x2273a0`，即 `create_file_fn`（4.0.21 `vfs_fn_pointers` 中 `create_file_fn` 为第 20 个指针，偏移 0x50）。
- `connect_fn` 为空。**原厂没有沿用上游“连接时把共享设为只读”的做法**，只挂 `create_file`。
- 函数内调试字符串：`readonly_create_file`（`0x3d5a1c`）、`check_if_time_in_range`（`0x3d5924`）。

### 1.2 `readonly_create_file`（0x2273a0）

1. 取参数列表：`lp_parm_string_list(SNUM(conn) 或 -1, handle->param ?: "readonly", "period", 默认值)`；默认值数组在 `0x42ac44`，指向 `"today 0:0:0"`（`0x3d5a00`）与 `"tomorrow 0:0:0"`（`0x3d5a0c`）。
2. `period == NULL || period[0] == NULL || period[1] == NULL` → 直接调用下层 `create_file`（`0x35f5b4`）。
3. `conn == NULL` → 下层。
4. `conn->read_only`（`connection_struct` 偏移 `0x32a`，由 `next/prev/sconn/tcon/cnum/params/...` 与 `VUID_CACHE_SIZE=32` 推算并与 4.0.21 头文件一致）为真 → 下层。注释：此时由核心的共享只读逻辑返回 `ACCESS_DENIED`。
5. `now = time(NULL)`；`begin = get_date(period[0], &now)`；`end = get_date(period[1], &now)`。
6. `begin <= now <= end`（**两端闭区间**）→ `DEBUG(1, "check_if_time_in_range: [true] start/end/current")`、`DEBUG(1, "create file failed caused by readonly timerange limit.")`，返回 `NT_STATUS_ACCESS_DENIED`（`0xc0000022`）。
7. 否则打印 `[false]`，调用下层。

`get_date` 解析失败返回 `-1`，代码没有错误分支：`begin=-1` 恒 ≤ now，`end=-1` 恒 < now，因此视为“不在区间”，放行。

### 1.3 由实现决定的行为集合

钩子在 `create_file`，**不检查 `access_mask` / `create_disposition` / 文件名**。因此窗口内：

| 操作 | 是否被原厂规则拦截 | 原因 |
|---|---|---|
| 新建文件、覆盖/追加/截断打开 | 是 | 都走 `create_file` |
| 只读打开已有文件 | 是 | 同上，纯读也被拒绝 |
| 列目录、打开目录 | 是 | 目录也经 `create_file` |
| 删除、重命名 | 是 | SMB 删除/重命名需要先 open 取得句柄 |
| 已打开句柄之后的 read/write | 否 | 判定只在 open 时发生，句柄不重新判定 |
| 服务端内部操作（不解协议） | 否 | 不经过该钩子 |

这与“共享只读”不同：窗口内该共享**完全不可访问**，而不是“可读不可写”。默认窗口 `"today 0:0:0","tomorrow 0:0:0"` 覆盖当天 00:00–24:00，等于全天拒绝。

## 2. 原厂二进制实测（隔离第二实例，1446）

方法：用原厂 `/usr/sbin/smbd`（即 `samba_multicall`）加载合成配置，`lock/pid/private/state/cache/ncalrpc` 全部指向 `/userdisk/data/s4vendor*/`，`smb ports = 1446`，不动 `/etc/config/samba`，不碰原厂的 139/445。测试共享设为 `browseable = no`，以便 macOS 测试机（在 `nonLoginMac.cfg` 中）通过原厂 MAC 策略。客户端为 macOS `smbprotocol`（SMB 3.1.1）。

| 共享 | 配置 | list | read | create |
|---|---|---|---|---|
| `rw` | 无 vfs | OK | OK | OK |
| `ro_syn` | period `today 00:00:00` → `tomorrow 00:00:00`（当前在窗口内） | `0xc0000022` | `0xc0000022` | `0xc0000022` |
| `ro_out` | period `today 03:00:00` → `today 04:00:00`（当前 02:1x，窗口外） | OK | OK | OK |
| `ro_bad` | `"garbage","garbage2"` | OK | OK | OK |
| `ro_one` | 只有 `"today 00:00:00"` | OK | OK | OK |
| `ro_default` | 未配置 `period` | `0xc0000022` | `0xc0000022` | `0xc0000022` |
| `ro_share_ro` | `read only = yes` + 活动窗口 | OK | OK | `0xc0000022`（核心只读，钩子被 `conn->read_only` 跳过） |

结论与原厂二进制反汇编一致，并确认“纯读也被拒绝”不是推断误差。

隔离核对：测试前后 `/tmp/lock/locking.tdb` 的 mtime 都是 `1794075614`（未变化），实例自己的 `lock/` 下生成了 `locking.tdb`、`brlock.tdb`、`serverid.tdb` 等；`/tmp/run/smbd.pid` 内容仍为原厂 `1448`、mtime 01:16，未被改写。

## 3. 新版实现（Samba 4.25.1）

- 补丁：`recipes/samba/patches/samba-s4-readonly-timewindow.patch`，SHA-256 `bab423a08d9e301553ca4325fc93a81bcb084de78c7ebcf9aeb7358f22df21a8`。
- 应用顺序：先 `apply-samba-patches.sh` 的 5 个基线补丁，再 `samba-s3-mac-policy.patch`，再本补丁（对 4.25.1 原树 `patch -p1 --dry-run` 通过，无 fuzz）。
- 修改 `source3/modules/vfs_readonly.c`：模块名、`period` 参数语法、默认值、日志文本均保持原厂一致；`period` 仍用 `getdate.c`（`get_date`）解析，支持 `date(1)` 语法。
- VFS 接口：只注册 `create_file_fn`，与 4.0.21 的接口位置对应。**删除上游的 `readonly_connect`**：上游会在窗口内把 `conn->read_only` 置真，导致已有文件也无法写入，与原厂二进制行为不符（原厂 `connect_fn` 为空）。
- 判定顺序、`conn->read_only` 跳过、闭区间、`get_date` 失败放行、`NT_STATUS_ACCESS_DENIED` 均按第 1 节实现。
- 仅测试用时间钩子：环境变量 `XIAOMI_READONLY_NOW=<epoch 秒>` 存在时用它代替 `time(NULL)`；未设置时走真实时钟。该变量不进入产品配置，仅用于本轮边界矩阵。

产物：`lib/vfs/readonly.so`，构建后 MD5 `83e70d255b8a8e7fd8dc57dda93d10c2`（30702 字节）。

## 4. 设备隔离实例测试（1445）

实例：4.25.1 `smbd`，`-s $ROOT/etc/smb.conf.s4`，`smb ports = 1445`，`TZ=CST-8`，`XIAOMI_MAC_FILTER=0`（把 S3 的 MAC 策略与本轮 readonly 语义解耦；S3 已单独验证 MAC 策略），`server min protocol = NT1`。共享：`win`（06:00→次日 02:00）、`out`（03:00–04:00）、`bad`、`one`、`def`（无 period）、`share_ro`（`read only = yes`）、`rw`（对照）。

### 4.1 假时钟矩阵（`XIAOMI_READONLY_NOW`）

| 时刻（CST） | 期望 | 实测 |
|---|---|---|
| 12:00 | `win` 拒绝，`out/bad/one/rw` 放行，`def` 拒绝 | 一致 |
| 01:30（次日） | `win` 放行（过零点后 `today 06:00` 重新指向当天未来；实际拒绝段是 06:00–24:00，放行段 00:00–06:00） | 一致 |
| 23:00 | `win` 拒绝 | 一致 |
| 06:00:00 | `win` 拒绝（起始端点闭区间） | 一致 |
| 05:59:59 | `win` 放行 | 一致 |
| 03:00:00 | `out` 拒绝（起始端点） | 一致 |
| 04:00:00 | `out` 拒绝（结束端点） | 一致 |
| 04:00:01 | `out` 放行 | 一致 |

12:00 一轮的完整操作矩阵：

| 共享 | ls | get | put | del | rename |
|---|---|---|---|---|---|
| `win` | `ACCESS_DENIED` | `ACCESS_DENIED` | `ACCESS_DENIED` | `ACCESS_DENIED` | `ACCESS_DENIED` |
| `out` / `bad` / `one` / `rw` | OK | OK | OK | OK（`rw`） | OK（`rw`） |
| `def` | `ACCESS_DENIED` | `ACCESS_DENIED` | `ACCESS_DENIED` | — | — |
| `share_ro` | OK | OK | `ACCESS_DENIED`（核心只读） | — | — |

### 4.2 客户端覆盖

- SMB1（`smbclient -m NT1 --option="client min protocol=NT1"`）：`win` 的 `ls`/`put` 均为 `ACCESS_DENIED`，`out` 均成功。
- SMB2：上表全部由 `-m SMB2` 得到。
- SMB3.1.1（macOS `smbprotocol`，dialect 0x311）：`win` 的 list/read/create 全部 `0xc0000022`；`out` 全部 OK；`rw` list/create OK（read 因测试期间改名导致文件不存在，与模块无关）。
- 真实时钟（不设 `XIAOMI_READONLY_NOW`，设备时间 02:25:46 CST）：`win` 放行、`out` 放行、`def` 拒绝；日志记录实际 epoch，例如 `[false] start: 1794078000, end: 1794081600, current: 1794075954`（`out`）、`[true] start: 1794067200, end: 1794153600, current: 1794075959`（`def`）。

### 4.3 兼容性观察（真实客户端，非 testparm）

- 中文名 `测试文件.txt` 在 `out` 创建成功，落盘文件名正确；在 `win` 同一操作返回 `ACCESS_DENIED`（拒绝发生在名称解析之前，与字符集无关）。
- 200 字节文件名创建成功；260 字节文件名返回 `NT_STATUS_OBJECT_NAME_INVALID`。
- `smbclient get casetest.txt`（远端实际为 `CaseTest.txt`）返回成功，属于客户端大小写不敏感匹配；服务端大小写语义未单独深究，不作为 S4 通过依据。
- 设备 `dos charset` 未配置 CP850，SMB1 客户端提示 `dos charset 'CP850' unavailable - using ASCII`（S2 已记录的已知现象，不影响本次判定）。

## 5. 与原厂的差异

| 项 | 原厂 4.0.21 | 新版 4.25.1 | 结论 |
|---|---|---|---|
| 钩子 | `create_file_fn`（唯一） | 同 | 一致 |
| 参数/默认值/语法 | `readonly:period`，`today 0:0:0`/`tomorrow 0:0:0` | 同 | 一致 |
| 端点/跨午夜/畸形 | 闭区间；`get_date` 失败放行；缺项放行 | 同 | 一致 |
| `conn->read_only` | 跳过钩子 | 同 | 一致 |
| 时间来源 | `time(NULL)` + `get_date` | 同（另加测试用 env 覆盖） | 一致，env 默认不启用 |
| 上游 connect 行为 | 无 | 已删除 | 有意差异，见 D-S4-01 |

## 6. 未达成与阻塞

- **真实摄像机接入：BLOCKED**。现场没有摄像机；摄像机通常固定连 445，而 445 被原厂 `smbd` 占用，约束不允许停原厂；本轮的“真实客户端”是 SMB1/SMB2/SMB3.1.1 文件客户端，不能替代摄像机固件行为（认证方式、路径拼接、重试策略）。摄像机兼容保持“未验证”。
- **Finder / mount_smbfs 走非 445：BLOCKED（继承 S3）**。macOS 挂载不支持自定义端口，S4 的 create 语义已用 `smbprotocol` 在 1445 验证，但 Finder 路径无法验证；本轮不依赖该路径。
- **原厂撤销实机对照：不适用于 S4**。readonly 模块没有“撤销/踢连接”逻辑（S3 的 MAC 策略才有），本轮未把 S3 的该项挂到 S4。
- **IPv6 与 SMB1 RAP：本轮不依赖**。判定发生在协议无关的 VFS `create_file`；SMB1 文件操作已实测（NT1），RAP 浏览不经过 `create_file`，不改变读写结论；IPv6 未启用（实例仅绑定 IPv4）。
- **系统时间跳变/长连接跨边界：未实测**。判定只在每次 open 时发生；设备是生产路由器，不能改系统时钟做跳跃测试。结论来自代码路径，不冒充实测。
- **原厂摄像机共享的写入对照：未做**。直接写生产共享会产生真实文件，改为用原厂二进制第二实例（1446）+ 合成共享完成对照；真实共享只做了只读观察。
- **生产配置是否真的写入 `vfs object = readonly` / `period`：S5 范围**。`/var/etc/smb.conf` 当前确有这两项，但生成链路（shareUpdate/模板）未在本轮审计。

## 7. 复现与清理

启动（设备）：

```sh
cd /userdisk/data/samba-s2/root
LD_LIBRARY_PATH=$PWD/lib:$PWD/lib/private TZ=CST-8 \
  XIAOMI_MAC_FILTER=0 XIAOMI_READONLY_NOW=1794110400 \
  ./sbin/smbd -D -s $PWD/etc/smb.conf.s4
```

停止：只 `kill $(cat var/run/smbd.pid)`，不使用任何通配匹配。

清理后核对（2026-11-08 02:26 CST）：

- `/usr/sbin/samba_multicall` MD5 `5e422d3463f40b4405ef8325ce3603e8`（未变）
- `/etc/config/samba` MD5 `244eb53e5019b95a408aebe49602561a`（未变）
- 原厂监听：TCP 139/445（`smbd` 1448）、UDP 137/138（`nmbd` 8469），136/1445/1446 无残留
- `/tmp/run/smbd.pid` 内容 `1448`，mtime 01:16（早于本轮）
- 根分区 `ubifs ro`，占用 81%
- `/userdisk/data/samba-s2`、`/userdisk/data/s4vendor*`、`/userdisk/data/s3-root.tar.gz` 均已删除

日志摘录（新版实例，12:00 假时钟）：

```
check_if_time_in_range: [true] start: ..., end: ..., current: ...
create file failed caused by readonly timerange limit.
smbd_smb2_request_error_ex: idx[1] status[NT_STATUS_ACCESS_DENIED] || at ../../source3/smbd/smb2_create.c:393
```
