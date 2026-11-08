# S7 切换与回滚演练

目标：给出可执行的安装/升级/卸载/回滚工具，并用真机演练证明失败可恢复。安装/回滚工具与本轮前半段的 1445 演练不动原厂；真实 139/445 切换在用户授权后单独执行，执行记录见“真实 139/445 切换”一节，原厂二进制与 `/etc/config/samba` 始终未被修改。

## 约束与范围

- 演练实例固定用 `192.168.3.2:1445`，运行根 `/userdisk/data/s7root`，与 `/etc/config`、`/var/etc`、原厂 TDB/锁/PID 隔离。
- 不执行 `init.d/samba`、`shareUpdate`、`updateconfig`、`killall`、`pkill`；停止只按 PID 文件加 `/proc/<pid>/exe` 校验。
- 版本目录、状态目录、安装器都在 `/userdisk/data`；演练结束整体删除。
- 本轮 v1/v2 使用**同一份 payload**，演练的是安装布局、切换、回滚与故障路径，不是“两个不同二进制版本”的兼容性；这一点不冒充。

## 交付物

### `recipes/samba/xiaomi-smb-install.sh`

| 命令 | 行为 | 退出码 |
| --- | --- | --- |
| `install <tar> [name]` | 校验 `sbin/smbd`、`bin/testparm`、`smbd -b` 的 `SBINDIR`，解包到 `versions/<name>/root`，记录 payload md5 与厂商基线 | 0/2/3 |
| `activate <name>` | 把 `smbd` 编译时写死的 SBINDIR 前缀重指到新版本；要求同名 payload 不重复安装、运行中不允许切换 | 0/1/3/4/6 |
| `rollback` | 按 `state/previous` 切回上一版本 | 0/1/6 |
| `uninstall` | 按 PID 文件停实例、移除前缀符号链接与版本/状态目录 | 0/1 |
| `verify` | 对照 `state/vendor.md5` 检查原厂文件是否被固件升级覆盖；检查前缀指向 | 0/3/5 |
| `status` | 当前版本、上一版本、适配器运行状态 | 适配器退出码 |

设计要点：

1. **激活不修改二进制**：`smbd -b` 报的 `SBINDIR` 是构建时写死的 `/userdisk/data/samba-s2/root`，安装器把该路径做成符号链接，`activate` 只重指链接；`readlink -f` 后与版本树一致才继续，避免“能启动但模块找不到”。
2. **状态机最小化**：`current` 符号链接 + `state/previous` + `state/<name>.md5` + `state/vendor.md5`，全部是文本，掉电最多丢“上一次版本”记录，不产生半安装（解包在 `.tmp` 目录完成后再 `mv` 发布）。
3. **厂商覆盖检测**：`install` 首次运行时记录 `/usr/sbin/samba_multicall` 与 `/etc/config/samba` 的 md5；`verify` 发现漂移返回 5，供固件升级后先重新评估再接管。

### 适配器修正（`recipes/samba/xiaomi-smb-adapter.sh`）

S5 的 `pid_is_ours` 只比较未解析的 `$ROOT/sbin/`。S7 通过符号链接激活版本后，`/proc/<pid>/exe` 是解析后的真实路径，导致自己的进程被判为“外来 PID”：启动循环超时、`stop` 拒绝、留下孤儿进程。修正为同时比较 `readlink -f "$ROOT"` 与真实路径，仍只使用 PID 文件 + exe 前缀，不做进程名匹配。

## 真机演练记录

设备：192.168.3.2，2.6.36 armv7l，1445 实例。

| # | 场景 | 操作 | 结果 |
| --- | --- | --- | --- |
| 1 | 首次安装 | `install s7-root.tar.gz v1` | rc=0；`smbd` md5 `52e10557…`；识别编译前缀 `/userdisk/data/samba-s2/root` |
| 2 | 激活 | `activate v1` | 前缀 → `versions/v1/root`，`verify` 三项 ok |
| 3 | 启动 | 适配器 `-r <前缀> -p 1445 start` | `running pid=… port=1445`，`/proc/<pid>/exe` 指向 v1 版本树 |
| 4 | 重复安装 | 同 payload 再 `install v1` | `already-installed v1`，rc=0，不产生第二份树 |
| 5 | 运行中切换保护 | 运行中 `activate v2` | rc=1，明确要求先停实例；运行中的 v1 未受影响 |
| 6 | 升级 | `stop` → `install v2` → `activate v2` → `start` | 前缀与 exe 均切到 `versions/v2/root`，端口保持 1445 |
| 7 | 回滚 | `stop` → `rollback` → `start` | 前缀与 exe 回到 v1，`previous=v2`，可再次切换 |
| 8 | 启动失败（端口占用） | 用 `nc -l -p 1445` 占端口后 `start` | rc=5，拒绝启动；无孤儿进程，释放端口后恢复 |
| 9 | 配置损坏 | 把共享 `read_only` 改成 `maybe` 后 `generate` | rc=3（testparm 拒绝）；`smb.conf` md5 `22093305…` 保持不变，上一份有效配置保留 |
| 10 | 共享目录暂时缺失 | 删除合成共享根目录后客户端 `ls` | `NT_STATUS_BAD_NETWORK_NAME`；目录恢复后同一客户端立即可读 |
| 11 | 卸载 | `uninstall` | 按 PID 文件停止实例，前缀链接与版本/状态目录被移除 |
| 12 | 厂商覆盖检测 | `verify`；再用伪造基线跑一次 | 正常 rc=0；伪造基线 rc=5，能报出漂移文件 |
| 13 | 设备重启 | — | **BLOCKED**：重启生产路由器会中断联网与管理，未执行 |
| 14 | 真实 139/445 切换 | 见“真实 139/445 切换”一节 | 已执行：第一次尝试因 macOS 共享枚举挂起立即回滚；修复多通道协商后第二次通过，验证完成即回滚原厂 |
| 15 | 真实不同版本升级 | — | **BLOCKED**：没有第二份可用的 4.x 构建；v1/v2 只验证布局与切换 |
| 16 | 真实 USB/磁盘拔出 | — | **BLOCKED**：内部盘是 `sda1`，`/extdisks` 为生产盘；用“共享根不存在”模拟，不等价于热插拔 |
| 17 | 固件升级真实覆盖 | — | **BLOCKED**：无可用 OTA；只验证检测逻辑（伪造基线触发 rc=5） |

## 真实 139/445 切换（2026-11-08，用户授权）

做法：停原厂只按 `/var/run/smbd.pid` 加 `/proc/<pid>/exe`（`/usr/sbin/samba_multicall`）与 cmdline（`/usr/sbin/smbd -D`）逐个校验，先 TERM 已验证的子进程再 TERM 主进程；端口释放后同一脚本内立即 `start -p "139 445" -P`，不做 12 秒等待；验证完立刻停新版并重启原厂。原厂二进制、`/etc/config/samba`、`/var/etc/smb.conf` 全程只读。

### 第一次尝试（15:00 之前）：异常并立即回滚

- 接管本身成功：新版 PID 22144，`/proc/<pid>/exe` 指向版本树 `sbin/samba-s5d`，139/445 均由新版监听，12 秒后未被 TaskMonitor 抢回。
- **客户端验证失败**：macOS `smbutil view //guest@192.168.3.2` 挂起；服务端 `smbstatus` 能看到来自 192.168.3.176/63 的 SMB3_11 会话，设备侧 `smbclient -m SMB3 -L 127.0.0.1` 正常列出 7 个共享。按“异常立即回滚”处理。
- 回滚：适配器 `stop`（PID 文件 + exe）→ 端口释放 → `/usr/sbin/smbd -D` 拉起原厂，PID 23832，139/445 恢复；macOS `smbutil view` 恢复 2 个共享，`mount_smbfs` 可读。

### 根因定位：SMB3 多通道协商

在 1445 上用 `smbutil view -N //guest@192.168.3.2:1445` 可稳定复现挂起（客户端 18 秒内不发 TREE_CONNECT，只发 LOGOFF；服务端日志显示 SESSION_SETUP 已成功、AuthZ 为 `nobody`）。逐项排除：

| 变量 | 结果 |
| --- | --- |
| `server max protocol = SMB3_02` | 仍挂起 |
| `server signing = disabled` | 仍挂起 |
| `server max protocol = SMB2_10` / `SMB2_02` | **正常**，2 个共享 |
| 认证用户（新建 `nobody` 口令）代替访客 | SMB3_02 下仍挂起 |
| `server multi channel support = no`，协议上限恢复默认（SMB3_11） | **正常**，枚举与 `mount_smbfs` 均通过 |

结论：Samba 4.25.1 默认广播 SMB3 multi-channel，macOS 客户端在本机单网卡/2.6.36 环境下协商后卡在会话建立完成到 TREE_CONNECT 之间；关闭多通道即恢复，SMB3 本身可用。适配器渲染配置已加入 `server multi channel support = no` 并附注释，1445 上复测 `smbutil view` 与 `mount_smbfs` 均通过。

### 第二次尝试（15:08:34–15:08:51）：通过

| 阶段 | 观测 |
| --- | --- |
| 切换前 | `/usr/sbin/samba_multicall` `5e422d34…`、`/etc/config/samba` `8556a19b…`、`/etc/config/misc` `731ebecdf…`、`/var/etc/smb.conf` `bcad8b90…`；139/445 由 PID 23832 持有，137/138 由 8469/nmbd 持有 |
| 停原厂 | PID 23832 exe/cmdline 校验通过后 TERM；子进程按同样校验处理；139/445 在 1 秒内释放 |
| 启新版 | 版本树 pidfile 写入新 PID，exe 为版本树 `sbin/samba-s5d`，139/445 均由新版监听，`start_rc=0` |
| 客户端 | macOS `smbutil view -N //guest@192.168.3.2` 列出 homes/XiaoMi/XiaoMi-usb0 三个共享；`mount_smbfs` 挂载 `XiaoMi` 成功并读到文件 |
| 回滚 | 15:08:47 适配器 `stop`（PID 文件 + exe）→ 端口 0 秒释放 → 原厂 `/usr/sbin/smbd -D`；PID 2282，139/445 恢复；137/138 未受影响 |
| 哈希复核 | 四个原厂文件 md5 与切换前完全一致（二进制、`samba`、`misc`、`/var/etc/smb.conf`） |
| 停机窗口 | 原厂 TERM 15:08:36 → 新版停止 15:08:47，约 **11 秒**；原厂 15:08:51 前恢复监听 |

回滚步骤（可复用于下次）：停新版 → 等 139/445 释放（最多 8 秒）→ `/usr/sbin/smbd -D` → 复核 PID 文件、`/proc/<pid>/exe`、端口、四个 md5、客户端枚举与挂载。TaskMonitor 可能在停原厂后约 14 秒尝试拉起原厂；本次窗口 11 秒，未发生抢占；若发生，以上述端口归属与 exe 校验为准，不按进程名杀。

### 演练中发现并修复的缺陷

| 缺陷 | 表现 | 修复 |
| --- | --- | --- |
| 适配器 PID 归属判断不解析符号链接 | 启动循环超时却留下运行中的实例，随后 `status` 返回 4、`stop` 拒绝 | `pid_is_ours` 同时比较解析后的真实路径 |
| 安装器用 `mv` 替换“指向目录的符号链接” | busybox `mv` 把新链接移进旧版本树，前缀仍指向旧版本 | 改为 `ln -sfn` 原地替换，并断言 `readlink -f` 一致 |
| 安装器用 `sha256sum` | 设备无该 applet，摘要为空，重复安装被误判为“payload 不同” | 改用设备已有的 `md5sum` |
| 版本切换与运行中实例 | PID 文件在版本树内，切换后新树找不到旧实例 | 切换前强制停实例（返回 1 并给出停止命令） |

## 切换原厂端口的操作清单（2026-11-08 已执行，清单保留）

1. `verify` 通过，记录原厂四个 md5、`ss`/`netstat` 端口归属、`df`。
2. 停原厂：只按 PID 文件 + `/proc/<pid>/exe`（`samba_multicall`/`smbd`）逐进程验证后停止；确认 139/445/137/138 释放。
3. `install` → `activate` → 适配器以 `-p 445`（或按最终方案）启动，`testparm` 与 `verify` 通过后再放行客户端。
4. 健康检查：本机与远端各一条读写、一个只读共享拒绝、一个相机时间窗拒绝；失败立即按清单第 5 步回滚。
5. 回滚：停新实例（PID 文件 + exe）→ `rollback` 或重装原厂树 → 用原厂 `init.d`/`shareUpdate` 恢复原厂配置与服务 → 复核四个 md5 与端口归属。

## 恢复核对（本轮结束）

清理只按 PID 文件与精确路径，未使用 `pidof`/`pkill`/通配匹配。

| 项 | 值 |
| --- | --- |
| `/usr/sbin/samba_multicall` | `5e422d3463f40b4405ef8325ce3603e8` |
| `/etc/config/samba` | `8556a19b6d81d49bfd5ab738e0132b51` |
| `/etc/config/misc` | `731ebecdfb56528599cdc4b09bf0f0f0` |
| `/var/etc/smb.conf` | `bcad8b90869688b7982a50aaa891cf99` |
| `/etc/samba/smb.conf.template` | `95ad7d4146de73a50fb33e823d495b94` |
| 139/445 | 2282/smbd，`/proc/2282/exe` = `/usr/sbin/samba_multicall` |
| 137/138 | 8469/nmbd |
| 1445 | 无监听 |
| 测试残留 | `/userdisk/data/s7root`（45 384 KB）、`/userdisk/data/s7-root.tar.gz`（14 180 KB）、`/userdisk/data/samba-s2` 保留作为已安装测试树；无 `samba-s5d`/`samba-dcerpcd` 进程；`/tmp` 下的接管脚本与 `uci-test` 已删除 |
| 根分区可用 | 20588 KB（与动手前一致，未写入根分区） |

`/etc/config/samba` 的 mtime 仍是 05:05，本轮未写入；该变更的来源见 [05:05 变更取证](s6-config-change-forensics.md)。
