# TaskMonitor 共存研究与改造（S8）

日期：2026-11-08。设备：R2D / ROM 2.25.209，运行态原厂 SMB。所有结论标注来源；未验证的部分明确标为推断。

## 1. 三个进程的职责边界

| 进程 | 证据 | 职责 |
| --- | --- | --- |
| `taskmonitorDaemon -p /usr/sbin/taskmonitorServer -b /usr/sbin/taskmonitorServer`（PID 1092） | `/proc/1092/cmdline` | 只做一件事：监督 `taskmonitorServer` 本身。它不持有服务任务表，也不负责重启 smbd 等业务进程 |
| `taskmonitorServer`（PID 1090） | `/proc/1090/cmdline`；二进制字符串 `TaskMonitor[Server]`、`[5s check] task[%s] Abnormal exit`、`/proc/%s/cmdline` | 任务表与看护主体。持有 ubus 对象 `taskmonitor`，周期性（5 s）检查任务 PID，异常退出后重启；任务变更时把任务表写回 `/tmp/taskmonitor/taskmonitor.conf` |
| `pluginTaskmonitor`（PID 8616） | `/proc/8616/cmdline`；链接 `libuci`、`libconfig++`、`libubus`；启动方式 `/etc/init.d/plugintaskmonitor.init` + `supervisord` | 数据中心/共享插件。读 `/etc/config/samba`、`/etc/config/minidlna`、`/etc/config/misc` 等，做共享状态与云端/App 同步。它自己也被 TaskMonitor 看护（任务表内有条目，cgroup `/dev/cgroup/cpu/plugin/tasks`） |

关键区分：**重启原厂 smbd 的是 `taskmonitorServer` 的任务表，不是 `pluginTaskmonitor`**。05:05 那批 UCI 整文件重写与 `pluginTaskmonitor` 的共享同步路径一致，但发起方仍无法唯一证明（见 [05:05 取证](s6-config-change-forensics.md)）。

## 2. 任务表 `/tmp/taskmonitor/taskmonitor.conf`

- 格式：**二进制记录表，不是文本**。`strings` 可见每条记录的字段序列：完整命令行、用于匹配的命令行、别名、`none`×3（用户/组/工作目录占位）、PID 数字；部分记录多一个 cgroup 档案路径（如 `/dev/cgroup/cpu/plugin/tasks`）。记录变长，直接手工编辑不可行。当前 92 796 B（加入探针时增至 95 608 B，移除后回到 92 796 B）。
- 写入者：`taskmonitorServer`。任务 `start`/`stop` 成功后 mtime 立即变化（实测 15:21 增、15:22 还原），对应字符串 `taskmonitor recovery config over`。
- 持久性：`/tmp` 是 tmpfs（`mount` 证据），**重启后丢失**。开机由各服务 init 脚本通过 `supervisord start` → `taskmonitorTool start` 重新注册；`/etc/rc.d/S12taskmonitor` 先于 `S96samba`、`S97plugintaskmonitor`，顺序成立。共 40+ 个 init 脚本调用 `supervisord`。
- 监控对象：`eapd`、`nas`、`acsd`、`bcm_bsd`、`wps_monitor`、`fcgi-cgi`、`sysapihttpd`、`mald`、`tunnelserver`、`stunserver`、`fan_tmp`、`trafficd`、`indexservice`、`netapi`、`datacenter`、`himan`、`hiapk2`、`uaq-agent`、`pluginTaskmonitor`、`/usr/sbin/smbd -D`（两条）等。不是全部进程，是显式注册过的任务。

## 3. 拉起时延与停止语义

- 受监控任务被 `kill -9` 后 **3 s 拉起**（实测 `/bin/sleep 240`，5 s 检查周期内）。
- `taskmonitorTool -t stop`（完整参数）成功后：进程被杀、**条目从任务表移除**；随后手工启动同命令行进程，TaskMonitor 不再干预（实测存活 10 s 未被杀）。因此 stop 是“注销”，不是“杀一次等它回来”。
- 匹配依据是任务记录里的 PID/命令行，不是进程名通配；实测与既有任务同名不同路径的进程不会被误杀。

## 4. 合法接口

ubus 对象 `taskmonitor` 的 schema（`ubus -v list taskmonitor`）：

```
start:  id, taskcmd, monitorname, monlogname, extlibpath, workdir, cgroup,
        monitornumber, monitorflag, oomflag, rssflag, vmzflag, vmzData,
        debugflag, RebootFlag, CheckBinPath, delayFlag
stop:   id, taskcmd, monitorname
status: id, taskcmd, monitorname
list:   id, taskcmd, monitorname
debug:  id, debugflag
```

- `ubus call taskmonitor debug '{"debugflag":false}'` → `Success`。直连可用。
- `ubus call taskmonitor status ...` → `Invalid command`（带/不带 `id` 均如此），**status 方法实际不可用**。
- 官方 CLI 是 `/usr/sbin/taskmonitorTool`；`supervisord` 是它的 shell 封装，调用参数固定为：

```
taskmonitorTool -p "$PROCLINE" -b "$PROCFLAG" -i "$MONNAME" [-n N] -t <start|stop> \
  -C 0 -M 1 -r -1 -L none -D none -g none -d off -v -1 \
  --vmzdata -1 --fastreboot 0 --delay 0
```

### `taskmonitorTool` 段错误（139）最小复现

- 复现 1（缺 `-p`）：`/usr/sbin/taskmonitorTool -t stop -b tmprobe_nonexistent` → **rc 139**，kernel 记录 `taskmonitorTool/6880: potentially unexpected fatal signal 11`。
- 复现 2（缺完整可选项）：`/usr/sbin/taskmonitorTool -t start -p "/bin/sleep 90" -b tmprobe_sleep` → **rc 139**。
- 同一命令补 `-p` 后 `-t stop` 返回 rc 1（不再崩）；按 `supervisord` 完整参数调用 `-t start`/`-t stop` 均 **rc 0**。

结论：**不是所有子命令都不可用**。`-t list` 可用（rc 0，无输出）；`start`/`stop` 在按 `supervisord` 完整参数集调用时可用；`status` 经 ubus 不可用、经工具也无独立输出。此前“`-t stop -b smbd` 段错误”属于**参数不全**，不是接口失效。

## 5. 三问结论

### (a) 能否把新版 smbd 作为独立条目注册，而不影响原厂条目

**可以，且已用无害进程验证机制。** 用 `-i <独立别名>`、`-p/-b <新版自己的命令行>` 注册后，任务表新增独立记录，原厂 `/usr/sbin/smbd -D` 两条记录不变；stop 只注销自己的记录。新版进程名 `samba-s5d`、路径在 `/userdisk/data/...`，与原厂 `/usr/sbin/smbd` 不同，TaskMonitor 按 PID/命令行匹配，不会误杀。

但**注册本身不解决 445 竞争**：原厂条目仍在，任何一次 `/etc/init.d/samba start`（App 开关、管理面自愈、开机）都会重新拉起原厂 smbd 抢 445。

### (b) 整文件重写 UCI 的触发条件能否规避或隔离

- **不能阻止写入者**。重写来自原厂管理栈（`pluginTaskmonitor` 共享同步 + App/云端动作 + 同秒的 `wrsst`/`ustackd` 幂等 stop 重放），不是定时任务、不是开机、不是 OTA；时间不规则（11-06 04:26、11-07 03:58、11-08 03:10、11-08 05:05）。让它不写就只能停管理功能，违反约束。
- **可以隔离消费端**。新版配置生成已加配置源守卫：`/etc/config/samba`、`misc` 的 `md5+size+mtime+inode` 与基线不一致时 `generate/check/start` 返回 7，拒绝用漂移源重渲染，`S5_ACCEPT_CONFIG=1` 显式接受。运行中的新版实例不会被后台改写直接换配置；`smb.conf`、PID、锁、状态目录全部在新版树内，与原厂 `/var/etc`、`/etc/config` 不共享。
- 剩余风险：若原厂在重写后**又**触发 `/etc/init.d/samba restart`，原厂 smbd 会来抢 445。这属于 (a) 的端口仲裁问题，不是配置内容问题。

### (c) 都不行时的最小侵入替代

1. **首选（零争用）**：新版只监听 1445，原厂保留 139/445，TaskMonitor 完全不动。共存成立、回归路径最短；代价是 Emby/摄像机等固定 445 的客户端不覆盖。
2. **需要 445 时**：用 TaskMonitor 合法接口**注销**原厂条目（`-t stop -p "/usr/sbin/smbd -D" -b "/usr/sbin/smbd -D" -i smbd`，完整参数），确认原厂 PID 消失且 445 释放，再以 `-P` 启动新版；回滚时停新版并 `/etc/init.d/samba start`（会重新注册原厂条目）。这是“与原厂监督栈协作”而不是杀进程绕过。
3. **不采用**：手改 `taskmonitor.conf`、kill `taskmonitorServer`、停 `pluginTaskmonitor`。前者格式未公开且会破坏恢复；后两者会连带影响其它被看护服务。

## 6. 会受影响的其它服务与观察点

| 服务 | 观察点 | 当前状态（15:2x） |
| --- | --- | --- |
| `wrsst` | 是否在 TaskMonitor 任务表、`/etc/config/ustack`、漫游日志 | 未运行；`ustack.settings.enabled=0`；05:05 只收到 `not find the task` 的幂等重放 |
| `ustackd` | 同上，命令行 `/usr/sbin/ustackd br-lan` | 未运行；同上 |
| OTA 预下载 | `/tmp/ota_predownload_pid`、cron `49 3,4,5`、`otapred` 日志 | 当前无进程；05:49 才启动，与 05:05 无关 |
| MiniDLNA | `minidlna` 进程、`/etc/config/minidlna`、1900/8200 监听 | 未运行；配置 mtime 仍是 2018 |
| 电视通知 | `messagingagent`（PID 6943）、`/etc/config/messaging*` | 运行中，与 SMB 无共享路径 |
| 管理界面 | `sysapihttpd` 主/备两组（6702、13108）、80/8xxx 监听、`pluginTaskmonitor` 8616 | 运行中；03:00 cron 会 restart sysapihttpd |
| 其它被看护进程 | `datacenter` 7594、`netapi` 7523、`indexservice` 7495、`trafficd` 7402、`tunnelserver` 7254、`stunserver` 7282 | 全部运行；任何 TaskMonitor 侧改造前须记录 PID 与监听，改造后逐项复核 |

## 7. 改造方案（有回滚路径才实施）

- 适配器新增：`tm-register`（启动成功后按独立别名注册新版实例）、`tm-unregister`（停止前先注销，避免 TaskMonitor 把它拉回来）、`tm-vendor-stop` / `tm-vendor-start`（仅用于授权切换/回滚，调用前后校验 `/proc/<pid>/cmdline` 与 `/proc/<pid>/exe`）。
- 不修改 `taskmonitor.conf`，不重启/停止 TaskMonitor 与 `pluginTaskmonitor`，不触碰 wrsst/ustackd。
- 备份：`taskmonitor.conf`、`/etc/config/{samba,misc}`、`/etc/crontabs/root`，以及其它服务 PID/监听快照。
- 复测项：原厂 smbd 仍可被 TaskMonitor 管理；其它服务 PID/监听不变；新版可起停；注销后不被拉回；UCI 重写后守卫返回 7。

## 8. 仍未验证 / BLOCKED

- TaskMonitor 任务表 03:00 的整表重写来源（今天 mtime 03:00，15:21 又因探针变化）；只知“变更即写 + 至少一次日级重写”，未证明触发者。
- 原厂 smbd 被 API 注销后，App 侧“SMB 开关/共享修改”是否会自动重新注册并抢 445——需要真实 App 操作，当前标 BLOCKED。
- 设备重启后的注册顺序与 445 归属，需要重启验证，当前标 BLOCKED（不在本轮授权范围）。

## 9. 改造实施与复测（2026-11-08 15:2x–15:3x）

### 9.1 适配器新增命令（`recipes/samba/xiaomi-smb-adapter.sh`）

| 命令 | 行为 | 安全边界 |
| --- | --- | --- |
| `tm-register` | 实例运行且端口在听时，用独立别名 `samba-s5d` 与完整参数集注册给 TaskMonitor | 已存在同一 `procline` 时幂等返回；不改任务表 |
| `tm-unregister` | 注销本实例条目；未注册时返回 0 | 只操作本实例的 `procline`/别名 |
| `vendor-stop` | 用 `-t stop -p "/usr/sbin/smbd -D" -b "/usr/sbin/smbd -D" -i smbd` 注销原厂条目，并等待 139/445 释放（最长 15 s） | 不按进程名通配；失败即返回 1，不做二次强杀 |
| `vendor-start` | 调 `/etc/init.d/samba start` 恢复原厂（shareUpdate/updateconfig/supervisord/nmbd 全链路） | 不停止新版；调用方须先 `stop` |
| `stop` | 若任务表里有本实例条目，**先自动注销再按 PID 文件停止** | 避免 5 s 看护把进程拉回 |

### 9.2 复测记录

1. **注册与自愈**：新版以 1445 启动后 `tm-register` rc 0，任务表由 92 796 B 增至 95 608 B；`kill -9` 后 **1 s 内**（5 s 检查窗口内）被拉起，新 PID 正常监听 1445，证明 `-D <root>` 与 `-L <root>/lib:<root>/lib/private` 足以让任务以正确工作目录和私有库重启。
2. **注销与停止**：`tm-unregister` rc 0，任务表回到 92 796 B；随后 `stop` rc 0，等待 8 s 未被拉回，1445 无监听，原厂 139/445 仍在（PID 2282）。
3. **445 协作接管**：`vendor-stop` 注销原厂条目并确认 139/445 释放 → `start -P -p "139 445"` rc 0，新版 PID 25276 独占 139/445，原厂 smbd 与子进程消失，nmbd 8469 保留。macOS `smbutil view -N //guest@192.168.3.2` 枚举到 XiaoMi、XiaoMi-usb0，`mount_smbfs` 挂载成功并可列目录/卸载。
4. **回滚**：`stop`（自动注销）→ `vendor-start` rc 0；原厂 smbd 以新 PID 25767 恢复 139/445，nmbd 仍 8469，UDP 137/138 正常；macOS 再次枚举到 2 个共享。
5. **哈希与其它服务**：`samba_multicall` `5e422d34…`、`/etc/config/samba` `8556a19b…`、`misc` `731ebec…`、`/var/etc/smb.conf` `bcad8b90…` 全部未变；`taskmonitorServer/Daemon`、`pluginTaskmonitor`、`sysapihttpd` 两组、`messagingagent`、`datacenter`、`netapi`、`indexservice`、`trafficd`、`tunnelserver`、`stunserver` PID 与切换前一致；根分区可用 20 588 KB 不变。
6. **UCI 漂移守卫**：影子目录模拟 `uci set samba.@sambashare[0].read_only=yes` 后 `generate` 返回 **7**，`smb.conf` md5 保持 `607053…`；清理后对真实源显式接受（`S5_ACCEPT_CONFIG=1`）rc 0，`check` 显示 `config_drift=no`、`isolation=OK`。
7. **新证据**：`vendor-start` 会让 `/etc/config/samba` 与 `/var/etc/smb.conf` 发生 **mtime 变化、md5 不变**的幂等回写（`shareUpdate -s`），`misc`/`crontabs` 不动；守卫因此返回 7，属于预期 fail-closed，已显式接受并记录。

### 9.3 结论

“新版 SMB 与 TaskMonitor 共存而不打架”在**两个层面**都成立：

- **1445 模式**：零冲突，注册后由原厂监督栈自愈，原厂 139/445 完全不动。
- **445 模式**：通过注销原厂条目（而不是杀进程）取得端口，回滚走原厂 init 全链路；全过程可逆、哈希不变、其它服务无异常。

不采用手改任务表、kill `taskmonitorServer`、停 `pluginTaskmonitor` 或停 `wrsst`/`ustackd` 的方案。
