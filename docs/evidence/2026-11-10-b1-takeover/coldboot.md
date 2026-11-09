# B1 冷启动验证（2026-11-10 01:45–01:47）

设备：MiWiFi R2D，固件 2.25.209。重启方式：设备上执行 `sync; reboot`，非软重启。

## 连接恢复

- 重启发起：01:45:25（主机时间）
- 轮询结果（每次间隔 10 s，ConnectTimeout=5）：
  - 01:45:35 `Connection refused`
  - 01:45:46 `Operation timed out`
  - 01:46:01 `Operation timed out`
  - 01:46:16 `Connection refused`
  - 01:46:26 成功，设备 `/proc/uptime` = 38.95 s
- 结论：约 50 s 后恢复；第 4 次尝试被拒、第 5 次成功，未见需要人工干预。

## 启动顺序证据

| 事件 | 证据 | 相对启动时刻 |
|---|---|---|
| sda1 识别 | `dmesg`: `[    6.230000] sda: sda1` | 6.23 s |
| `/userdisk` ubifs 挂载 | `dmesg`: `[   15.700000] UBI: attached mtd10 to ubi2`；`/proc/mounts`: `/dev/ubi2_0 /userdisk ubifs rw` | 15.70 s |
| `/userdisk/data` ext4 挂载 | `dmesg`: `[   16.660000] EXT4-fs (sda1): mounted filesystem`；`/proc/mounts`: `/dev/sda1 /userdisk/data ext4 rw` | **16.66 s** |
| dropbear 监听进程启动 | `awk '{print $22}' /proc/6137/stat` = 3729 ticks；实测 100 ticks/s（self=6257 vs uptime 62.58 s） | **37.29 s** |
| samba-s5d 启动 | `/proc/10207/stat` = 5043 ticks | 50.43 s |
| nmbd 启动 | `/proc/11680/stat` = 5184 ticks | 51.84 s |

结论：`/userdisk/data` 在 16.66 s 已可读，dropbear 在 37.29 s 才启动，挂载先于 S50dropbear 约 20.6 s。因此候选二进制与 `run/takeover.ok` 在 init 选择时均可见。

## 22 端口最终归属

```
pid=6137
/userdisk/data/dropbear-2026.94/sbin/dropbear
/userdisk/data/dropbear-2026.94/sbin/dropbear -P /var/run/dropbear.1.pid -D /etc/dropbear -p 22
banner: SSH-2.0-dropbear_2026.94
host key: SHA256:pmNz57IrPJpHFwek6kt7ycibeMhkMWmaR+n4nYLvAus（与重启前一致）
```

- 未回退为原厂 2011.54；`/etc/init.d/dropbear` md5 仍为 `504eeae6…`（wrapper）。
- `run/takeover.ok` 时间戳仍为 `Tue Nov 10 01:40:10 CST 2026`（重启前的标记，落在持久分区）。
- 公钥登录：01:46:54 新建会话成功，返回 `COLD_BOOT_LOGIN_OK`，会话内再次确认 pid/exe/banner。
- 监听：仅 6137 一个实例，`0.0.0.0:22` 与 `:::22`。

## 其他组件回归

| 检查 | 结果 |
|---|---|
| `state/s7root/current` | `versions/1.0.7-r2d/root` |
| `state/previous` | `1.0.6-r2d` |
| `samba-s5d` | pid 10207（及子进程 10216/10217/11218），exe 指向 `versions/1.0.7-r2d/root/sbin/samba-s5d` |
| 私有 `nmbd` | pid 11680，exe 指向 `versions/1.0.7-r2d/root/sbin/nmbd` |
| 139/445 | 归 `samba-s5d`(10207) |
| 137/138 | 归私有 `nmbd`(11680)，未被拉回原厂 |
| `diskacl-sync` cron | 存在：`* * * * * /userdisk/data/s8compat/versions/v1/diskacl-sync.sh … # s8-diskacl` |
| `s8-diskacl` 链 | 8 条 MAC DROP + `RETURN` |
| INPUT 跳转 | 第 2/3 条为 TCP/UDP 跳 `s8-diskacl`；第 4 条为 `br-guest` 139/445 DROP |
| `diskacl-status` | `chain=present jumps=2 legacy_chain=absent guest=enforced` |
| LuCI | `GET /cgi-bin/luci` = 200 |
| 22 / 80 | 22 归 2026.94；80 归 `sysapihttpd` |

## 与重启前的差异

- 系统时钟在启动后回落为 `Tue Oct 16 19:45:5x CST 2018`，重启前为 2026-11-10。设备无有效 RTC，启动后由厂商 cron `*/3 * * * * /usr/sbin/ntpsetclock rand once` 做一次性校时；01:56 复查时已回到 `Tue Nov 10 01:56:29 CST 2026`，`ntpd` 未常驻。影响仅限于开机后几分钟内依赖本地时间的日志与证书判断，属厂商既有行为，未做修改。
- 22 PID 由 19515 变为 6137；exe、banner、host key、认证方式不变。

## 判定

冷启动后 22 端口仍由 2026.94 持有，启动顺序满足依赖，未触发自动回退；Samba/nmbd/ACL/cron/LuCI 无退化。B1 唯一遗留的冷启动项已补齐。
