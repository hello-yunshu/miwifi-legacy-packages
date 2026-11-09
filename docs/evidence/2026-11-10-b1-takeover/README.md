# B1 22 端口接管：验证记录（2026-11-10）

## 切换前（原厂）

```
17502
/usr/sbin/dropbear
/usr/sbin/dropbear -P /var/run/dropbear.1.pid -p 22
banner: SSH-2.0-dropbear_2011.54
/usr/sbin/dropbear            md5 c2cd6355107bfffb32c8d773c2c8ad25
/etc/init.d/dropbear         md5 b010c10c00d12dec35b8ab4d2e88e2bb
/etc/config/dropbear         md5 4ff9c827d4f95ca5082a5520c03e1419
/etc/dropbear/authorized_keys md5 2b25ef3311bbec3c3a16426834d1a38f
/etc/dropbear/dropbear_rsa_host_key md5 7b335b01de340c26de923e6e5770c13b
```

## 切换后（2026.94）

```
19515
/userdisk/data/dropbear-2026.94/sbin/dropbear
/userdisk/data/dropbear-2026.94/sbin/dropbear -P /var/run/dropbear.1.pid -D /etc/dropbear -p 22
banner: SSH-2.0-dropbear_2026.94
RSA host key 指纹 SHA256:pmNz57IrPJpHFwek6kt7ycibeMhkMWmaR+n4nYLvAus（与备份文件一致，22 实际提供同一 key）
/usr/sbin/dropbear            md5 c2cd6355107bfffb32c8d773c2c8ad25（未改）
/etc/init.d/dropbear         md5 504eeae6d9f171939b0f67786b25630e（wrapper）
/etc/config/dropbear         md5 4ff9c827d4f95ca5082a5520c03e1419（未改）
/etc/dropbear/authorized_keys md5 2b25ef3311bbec3c3a16426834d1a38f（未改）
```

说明：应急接管脚本 `takeover-22.sh` 显式传 `-r /etc/dropbear/dropbear_rsa_host_key`；init 路径未显式传 `-r`，由 dropbear 默认读取同一 RSA key，因此最终 cmdline 中只有 `-D /etc/dropbear`。DSS key 在设备上保留但 2026.94 不支持，未使用。

## 功能验证

| 检查 | 结果 |
|---|---|
| OpenSSH 客户端识别 banner | `remote software version dropbear_2026.94` |
| 公钥登录（沿用原 authorized_keys 中的既有 key） | PASS，连续 3 次登录均成功 |
| 会话稳定性 | PASS，登录后执行命令并保持 2 秒，无断连 |
| `/proc/<pid>/exe` | `/userdisk/data/dropbear-2026.94/sbin/dropbear` |
| 22 监听 | `0.0.0.0:22` 与 `:::22`，单实例 19515 |
| 认证方法（PasswordAuth=on） | `publickey,password`，与原厂一致 |
| `-s` 限制行为（隔离端口 2224） | `Permission denied (publickey)`，密码被禁用 |
| 对照：不带 `-s`（2223） | `Permission denied (publickey,password)` |
| 管理面 LuCI | `GET /cgi-bin/luci` = 200；80 仍由 `sysapihttpd` 持有 |
| SMB | 139/445 仍由 `samba-s5d`(15175) 持有，无变化 |
| 旧端口行为回归 | 原 22 的认证方式、端口、host key 指纹未变，无回归项 |
| authorized_keys | md5 与切换前一致（临时测试 key 已移除） |

## 自愈演练（隔离端口 2223）

- 成功路径：新实例起在 2223 → banner `dropbear_2026.94` → 回环公钥认证返回 `AUTH_OK` → 写成功标记；Mac 侧用既有 key 登录 2223 成功；authorized_keys md5 复原为 `2b25ef…`。
- 强制失败路径：实例起在 2223 但故意不写标记；`watchdog-22.sh` deadline=15s，到点后由 `drill-rollback-2223.sh` 杀掉新实例（pid 17300，exe 为新路径），2223 释放，22 仍为原厂 7152。
  日志：
  ```
  [01:39:18] watchdog armed deadline=15s pid=17302
  [01:39:33] watchdog deadline reached without marker -> rollback
  [01:39:34] drill rollback kill pid=17300 exe=/userdisk/data/dropbear-2026.94/sbin/dropbear
  [01:39:34] drill rollback OK: 22 still vendor pid=7152
  [01:39:34] watchdog rollback rc=0
  ```

## 22 端口正式接管

- 接管前先独立启动看护（deadline 90s），再启动接管脚本。
- 接管脚本依次：停原厂监听 → 等 22 释放 → 起新实例 → banner 校验 → 回环公钥实测 → 写 `run/takeover.ok`。
- 日志：
  ```
  [01:40:07] takeover start
  vendor pid=17502
  banner=SSH-2.0-dropbear_2026.94
  auth_out=... AUTH_OK
  [01:40:10] takeover SUCCESS
  ```
- 失败任一步即调用 `rollback-22.sh`；看护在没有标记时到点也会调用同一回退。

## 冷启动/回退链

- 原厂 `stop/start` 链实测：stop 后 22 释放，start 后 pid=17502 → `/usr/sbin/dropbear`，banner 2011.54。
- 新 init 选择逻辑实测：
  - 标记存在 → stop/start 后 pid=19344 → 新路径，banner 2026.94；
  - 标记移走 → pid=19295 → `/usr/sbin/dropbear`，banner 2011.54；
  - 标记恢复 → pid=19344 → 新路径，banner 2026.94。
- 完整回退脚本实测：`rollback-22.sh` rc=0，pid=19427 → `/usr/sbin/dropbear`，`/etc/init.d/dropbear` md5 回到 `b010c10c…`；随后重新接管，pid=19515 → 新路径，banner 2026.94。

## 未做

- 未执行整机重启。启动脚本选择逻辑用 stop/start + 标记开关等价演练；冷启动后 `/userdisk/data` 是否在 S50 前挂载未实测。
