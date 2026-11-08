# 按设备磁盘访问拦截（`s8-diskacl`）

实现"App 里关掉某台设备的全盘访问 → 该设备的 SMB/NetBIOS 被拒；打开 → 恢复放行"。
真机验证时间线与证据见 [release-readiness-2026-11-08.md](release-readiness-2026-11-08.md) §7，
决策记录见 [decisions.md](decisions.md) D-S9-01…10。

## 1. 数据源与语义

数据源是 `/etc/config/macfilter`（只读，不回写）：

```
config mode 'mode'
        option lan 'blacklist'      # 只有 blacklist 会被执行
config mac
        option mac 'aa:bb:cc:dd:ee:ff'
        option lan 'yes' | 'no'     # no = 该设备不得访问 SMB
```

* 仅当 `mode.lan='blacklist'` 时施加。
* 只对 `lan='no'` 的条目生成 `-m mac --mac-source <MAC> -j DROP`。
* 链尾固定 `-j RETURN`；`yes`/字段缺失/未知值一律不产生 DROP（名单外默认放行）。
* `pridisk` 不再是数据源；`pridisk-apply/clear/status` 仅为 deprecated alias，
  内部转发到 `diskacl-*`，不读取任何 `option pridisk`。

## 2. 链与跳转位置

```
iptables -N s8-diskacl
iptables -A s8-diskacl -m mac --mac-source <no 的 MAC> -j DROP   # 0..N 条
iptables -A s8-diskacl -j RETURN
iptables -I INPUT 1 -i br-lan -p tcp -m multiport --dports 139,445 -j s8-diskacl
iptables -I INPUT 2 -i br-lan -p udp -m multiport --dports 137,138 -j s8-diskacl
```

* 只拥有这一条链和两条 INPUT 跳转，从不 flush/重建 INPUT 的其余部分；厂商
  multiport ACCEPT 永远排在跳转之后。
* 旧链 `s8-pridisk`（历史版本的无条件 DROP 链）在每条 apply/clear 路径**最先**删除：
  先删其 INPUT 跳转，再 `-F`/`-X`；顺序反了会留下悬挂跳转继续丢包。该链永不重建。
  这一步在 `refused`/`unavailable` 时也会执行——纯减损动作，只会缩小误伤面。

## 3. 访客网（无条件拒绝）

访客网默认**不能**访问 SMB，这条规则独立于 `macfilter` 名单：

```
iptables -I INPUT <原厂 ACCEPT 之前的行号> \
  -i br-guest -p tcp -m multiport --dports 139,445 -j DROP
```

* 必须是接口限定的单条 `DROP`，并排在原厂那条**不限接口**的
  `-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT` 之前。插到它后面等于没拦。
* 不复用 `s8-diskacl`：该链尾是 `-j RETURN`，访客流量会落回上面那条 ACCEPT。
* 为什么不用名单：访客设备使用随机化 MAC（iOS/Android 私有 Wi-Fi 地址），
  `macfilter` 里永远不会有它们，按名单判定结构性失效，因此访客走无条件拒绝。
* 访客 UDP 137/138 已被原厂 `zone_guest` 拒绝，无需重复规则。
* `br-guest` 不存在时不施加、不报错；存在时在每条 apply 路径（含 `refused`/`unavailable`）
  都会施加。`diskacl-clear` 会删除它。
* 行号按 `iptables -S INPUT` 的 `-A INPUT` 行计数，跳过 `-P INPUT ACCEPT` 头部；
  按 `NR` 计数会固定偏移 1，把规则插到 ACCEPT 之后。设备 dry-run 已实测验证。

## 4. 拒绝条件（宁可不施加，也不猜）

| 条件 | 退出码 | 状态 | 动作 |
| --- | --- | --- | --- |
| `mode.lan=blacklist` 且解析成功 | 0 | `applied` | 重建链并确保两条跳转 |
| `mode.lan` 缺失 / 非 `blacklist` / 取值异常 | 8 | `refused` | 不建链、不动 INPUT |
| `macfilter` 不存在 / 不可读 / 解析出 0 段 | 2 | `unavailable` | 不建链、不动 INPUT |

任何异常的最坏结果是"名单内设备被拦"，不存在"全员 DROP"。状态写入
`$ROOT/var/state/diskacl.state`（`mode / decision / allowed / denied / entries / unset / bad / updated`），
日志写入 `$ROOT/var/log/adapter.log`。

## 5. cron 兜底与 md5 缓存

`lan no→yes` 不会触发 samba 重启，因此需要独立同步：

* `/userdisk/data/s8compat/versions/v1/diskacl-sync.sh`，由
  `/etc/crontabs/root` 每分钟执行一次；**无常驻守护进程**，不注册 TaskMonitor。
* `current` 必须是 `versions/v1` 才动作；`macfilter` 不存在/不可读不再整体退出，
  访客规则仍需独立检查（按设备链则保持不动作）。
* `md5sum` 与 `state/macfilter.md5` 比对：变了才调 `diskacl-apply`；未变时只做只读
  `iptables -S` 健康检查（链、两条跳转、legacy 链是否复现，以及访客规则是否恰好一条
  且位于原厂 ACCEPT 之前），异常才重建。
* 缓存策略：`rc=0`（施加）与 `rc=8`（确定性拒绝）都写缓存，避免拒绝态每分钟刷日志；
  `rc=1/2`（unavailable）不写，文件恢复后自动补上。
* **禁止对 crond 发 `SIGHUP`**（该固件 busybox crond 会直接退出）。改 crontab 后必须
  `/etc/init.d/cron restart`；`compat/install.sh` 在追加 cron 行后已自动执行这一步。

实测延迟：`yes→no` 随厂商重启约 10 秒（02:41:27→02:41:37）；`no→yes` 靠 cron，
本次 22 秒（02:44:40→02:45:02），上限 60 秒。

## 6. 回滚

设备侧备份与完整回滚命令见
[evidence/2026-11-09-diskacl/rollback-and-incident.txt](evidence/2026-11-09-diskacl/rollback-and-incident.txt)。要点：

* 只退版本：`sh install-release.sh rollback`（`previous` 指向 `1.0.4-r2d`）。
* 完整回到装机前：先 `diskacl-clear`，再 rollback，然后恢复备份中的
  `s7root/xiaomi-smb-adapter.sh`、`s8compat/versions/v1`、两个 init 脚本、
  `/etc/crontabs/root`，最后 `/etc/init.d/cron restart`。

## 7. 已知边界

* **按 MAC 匹配，与 IP 无关**：DHCP 重新分配地址、租约变化不影响判定。
* **访客网单独处理**：`s8-diskacl` 只覆盖 `br-lan`；访客的 TCP 139/445 由第 3 节
  那条无条件 `DROP` 拦截，UDP 137/138 由原厂 `zone_guest` 拦截。
* **MAC 可被伪造**：能挡住普通用户误用，挡不住有意伪装源 MAC 的人。
* **设备级而非共享级**：语义是"这台设备能不能连上 SMB"，不是"能不能读某个共享目录"；
  账号认证仍按原样生效。共享目录级权限如需另做。
