# 阶段 4/5 证据索引（2026-11-09）

- 设备：MiWiFi R2D / 固件 2.25.209 / ARMv7 / uClibc 0.9.33.2 / Linux 2.6.36
- 窗口：2026-11-09 18:08–18:17 CST（装前快照 → 逐项部署 → 整机冷启动 → 收口互校）
- 计划：[R2D 软件升级总计划 §11](../../plans/r2d-software-upgrade-plan.md#11-阶段-45-最终状态2026-11-09)
- 决策：[decisions.md S10](../../decisions.md)
- 阶段 2/3 证据：[../2026-11-09-stage2-3/](../2026-11-09-stage2-3/)

## 1. 部署结果

| 项 | 结果 | 一句话证据 |
|---|---|---|
| B3 nmbd 4.25.1 | PASS | 137/138 归 `versions/1.0.7-r2d/root/sbin/nmbd`；`samba restart` 与冷启动后未被拉回原厂 |
| B2 curl 8.23.0 | PASS（部分） | 仅 `/etc/init.d/miDebug.sh` 切到私有 HTTP-only curl；同请求正文与退出码一致 |
| B1 Dropbear 2026.94 | BLOCKED | 密钥认证被祖先目录权限检查拒绝（`/` 属主 uid 1000）；22 未动，实例已清理 |
| B4 MiniDLNA 1.3.3 | BLOCKED | App `status=6` 关闭；`supervisord`/`killall` 集成路径不可激活验证；未改启动脚本 |
| A0 Samba 1.0.7 | PASS（冷启动） | 139/445、链、访客位次、cron 冷启动后保持 |
| A1 / B5 / B6 | 未触发 / 未部署 | 无上游新版本 / 无 DNS-DHCP 角色 / 前置未决 |

## 2. 文件索引（按检索关键词）

| 文件 | 内容 | 关键结论 |
|---|---|---|
| `pre-install-snapshot.txt` | 装前快照：`current`/`previous`、版本树、INPUT 六条、链 8 DROP、crontab、进程 pid、配置 md5、端口、容量、App 状态 | `previous=1.0.6-r2d` 可解析；1.0.6/1.0.7 树均在 |
| `pre-reboot-check.txt` | 重启前复核：nmbd 私有 exe、139/445、链、cron、回滚资产与备份文件 | 全部通过后才重启 |
| `post-reboot-check.txt` | 冷启动后逐条核对：22/80、139/445、137/138、链、cron、`previous`、无候选残留、名称注册、共享枚举、curl | 139/445 归 `samba-s5d`；nmbd 仍私有；`http80=200` |
| `b3-nmbd-deploy.txt` | nmbd 切换与验证：pid/exe、137/138、139/445、INPUT、链计数、cron、`diskacl-status`、`nmblookup -A`、`smbclient -L`、macOS `smbutil` | 名称 `XIAOMI_8041<00/03/20>`、`WORKGROUP<00/1e>`；共享可枚举 |
| `b1-dropbear-deploy.txt` | 候选 Dropbear 2222 启动、`/etc/dropbear` 与 `/tmp/dbkeys` 两种 key 目录、认证失败日志、清理 | `/etc` 775 组可写；`/` 属主 1000；无可用修法，BLOCKED |
| `b2-b4-deploy.txt` | `miDebug.sh` 切换后 md5 与 CURL 行、`mitvapp` 未切换、MiniDLNA App 状态与端口 | curl 仅覆盖显式 HTTP 调用方；MiniDLNA 未部署 |
| `cross-check.txt` | 发布包 md5/sha256、解包后 `MANIFEST.md5`/`SHA256SUMS`（11/11）、`state/*.md5`、设备二进制 md5、兼容层 `MANIFEST` 校验、`install.log`、nmbd 日志 | 载荷 `0f600101…`；`smbd 52e10557…`、`nmbd 2283bda9…`；设备 MANIFEST 4/4、发布包 11/11 OK |
| `samba.init.orig` / `samba.init.new` / `samba.init.diff` | 切换前后 `/etc/init.d/samba` 与差异 | 仅 nmbd 启停入口变化，私有优先、原厂兜底 |
| `miDebug.sh.new` | 安装后的 `miDebug.sh` | 增加 `CURL` 变量与 `-x` 兜底 |

## 3. 回滚资产与清理

- 设备回滚：`state/previous = 1.0.6-r2d`，`versions/1.0.6-r2d/root/sbin/smbd` 可执行；`versions/1.0.7-r2d` 保留。
- 启动脚本备份：`state/samba.init.pre-stage4.bak`、`state/miDebug.sh.pre-stage4.bak`、`state/mitvapp.pre-stage4.bak`（后者未使用，原厂文件未改）。
- 清理：2222/18083/18200/8200 无监听；无 `r2d-cand`、`lighttpd`、`minidlnad` 残留；临时 host key、`/tmp/dbkeys`、测试 docroot 已删。
- 边界：未接管 22；未改 `macfilter`/`sysapi`/`shareUpdate` 语义；未删除 1.0.6 回滚树。

## 4. 如何检索

```sh
# 八项最终状态
rg -n "阶段 4/5 最终状态|BLOCKED|PASS" docs/plans/r2d-software-upgrade-plan.md
# 本轮决策
rg -n "D-S10-" docs/decisions.md
# nmbd 冷启动后的端口归属
rg -n "137|138|nmbd" docs/evidence/2026-11-09-stage4/post-reboot-check.txt
# 互校哈希
rg -n "0f600101|52e10557|2283bda9|MANIFEST" docs/evidence/2026-11-09-stage4/cross-check.txt
```
