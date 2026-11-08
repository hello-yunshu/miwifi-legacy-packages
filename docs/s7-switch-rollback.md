# S7 切换与回滚演练

目标：给出可执行的安装/升级/卸载/回滚工具，并用真机演练证明失败可恢复。**本轮不切 139/445**，原厂 4.0.21 的二进制、配置、端口归属全程未动。

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
| 14 | 真实 139/445 切换 | — | **BLOCKED**：需停原厂 smbd 并改端口归属，须用户单独授权 |
| 15 | 真实不同版本升级 | — | **BLOCKED**：没有第二份可用的 4.x 构建；v1/v2 只验证布局与切换 |
| 16 | 真实 USB/磁盘拔出 | — | **BLOCKED**：内部盘是 `sda1`，`/extdisks` 为生产盘；用“共享根不存在”模拟，不等价于热插拔 |
| 17 | 固件升级真实覆盖 | — | **BLOCKED**：无可用 OTA；只验证检测逻辑（伪造基线触发 rc=5） |

### 演练中发现并修复的缺陷

| 缺陷 | 表现 | 修复 |
| --- | --- | --- |
| 适配器 PID 归属判断不解析符号链接 | 启动循环超时却留下运行中的实例，随后 `status` 返回 4、`stop` 拒绝 | `pid_is_ours` 同时比较解析后的真实路径 |
| 安装器用 `mv` 替换“指向目录的符号链接” | busybox `mv` 把新链接移进旧版本树，前缀仍指向旧版本 | 改为 `ln -sfn` 原地替换，并断言 `readlink -f` 一致 |
| 安装器用 `sha256sum` | 设备无该 applet，摘要为空，重复安装被误判为“payload 不同” | 改用设备已有的 `md5sum` |
| 版本切换与运行中实例 | PID 文件在版本树内，切换后新树找不到旧实例 | 切换前强制停实例（返回 1 并给出停止命令） |

## 切换原厂端口的操作清单（待授权，未执行）

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
| `/var/etc/smb.conf` | `bcad8b90869688b7982a50aaa891cf99` |
| `/etc/samba/smb.conf.template` | `95ad7d4146de73a50fb33e823d495b94` |
| 139/445 | 1448/smbd |
| 137/138 | 8469/nmbd |
| 1445 | 无监听 |
| 测试残留 | `/userdisk/data/s7root`、`/userdisk/data/samba-s2` 均不存在，无 `samba-s5d` 进程 |
| 根分区可用 | 20588 KB（与动手前一致） |

`/etc/config/samba` 的 mtime 仍是 05:05，本轮未写入；该变更的来源见 [05:05 变更取证](s6-config-change-forensics.md)。
