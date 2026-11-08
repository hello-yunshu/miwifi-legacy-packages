# 按设备磁盘访问拦截（`s8-diskacl`）

实现"App 里关掉某台设备的全盘访问 → 该设备的 SMB/NetBIOS 被拒；打开 → 恢复放行"。
真机验证时间线与证据见 [release-readiness-2026-11-08.md](release-readiness-2026-11-08.md) §7，
决策记录见 [decisions.md](decisions.md) D-S9-01…07。

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

## 3. 拒绝条件（宁可不施加，也不猜）

| 条件 | 退出码 | 状态 | 动作 |
| --- | --- | --- | --- |
| `mode.lan=blacklist` 且解析成功 | 0 | `applied` | 重建链并确保两条跳转 |
| `mode.lan` 缺失 / 非 `blacklist` / 取值异常 | 8 | `refused` | 不建链、不动 INPUT |
| `macfilter` 不存在 / 不可读 / 解析出 0 段 | 2 | `unavailable` | 不建链、不动 INPUT |

任何异常的最坏结果是"名单内设备被拦"，不存在"全员 DROP"。状态写入
`$ROOT/var/state/diskacl.state`（`mode / decision / allowed / denied / entries / unset / bad / updated`），
日志写入 `$ROOT/var/log/adapter.log`。

## 4. cron 兜底与 md5 缓存

`lan no→yes` 不会触发 samba 重启，因此需要独立同步：

* `/userdisk/data/s8compat/versions/v1/diskacl-sync.sh`，由
  `/etc/crontabs/root` 每分钟执行一次；**无常驻守护进程**，不注册 TaskMonitor。
* `current` 必须是 `versions/v1` 才动作；`macfilter` 不存在/不可读直接退出。
* `md5sum` 与 `state/macfilter.md5` 比对：变了才调 `diskacl-apply`；未变时只做 3 次
  只读 `iptables -S` 健康检查（链、两条跳转、legacy 链是否复现），异常才重建。
* 缓存策略：`rc=0`（施加）与 `rc=8`（确定性拒绝）都写缓存，避免拒绝态每分钟刷日志；
  `rc=1/2`（unavailable）不写，文件恢复后自动补上。
* **禁止对 crond 发 `SIGHUP`**（该固件 busybox crond 会直接退出）。改 crontab 后必须
  `/etc/init.d/cron restart`；`compat/install.sh` 在追加 cron 行后已自动执行这一步。

实测延迟：`yes→no` 随厂商重启约 10 秒（02:41:27→02:41:37）；`no→yes` 靠 cron，
本次 22 秒（02:44:40→02:45:02），上限 60 秒。

## 5. 回滚

设备侧备份与完整回滚命令见
[evidence/2026-11-09-diskacl/rollback-and-incident.txt](evidence/2026-11-09-diskacl/rollback-and-incident.txt)。要点：

* 只退版本：`sh install-release.sh rollback`（`previous` 指向 `1.0.4-r2d`）。
* 完整回到装机前：先 `diskacl-clear`，再 rollback，然后恢复备份中的
  `s7root/xiaomi-smb-adapter.sh`、`s8compat/versions/v1`、两个 init 脚本、
  `/etc/crontabs/root`，最后 `/etc/init.d/cron restart`。

## 6. 已知边界

* **按 MAC 匹配，与 IP 无关**：DHCP 重新分配地址、租约变化不影响判定。
* **只覆盖 `br-lan`**：其他接口（含访客网）不在这条链的匹配范围内；访客网启用后的
  场景尚未评估。
* **MAC 可被伪造**：能挡住普通用户误用，挡不住有意伪装源 MAC 的人。
* **设备级而非共享级**：语义是"这台设备能不能连上 SMB"，不是"能不能读某个共享目录"；
  账号认证仍按原样生效。共享目录级权限如需另做。
