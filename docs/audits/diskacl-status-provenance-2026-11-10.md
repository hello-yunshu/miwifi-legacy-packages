# `diskacl-status` 来源核查：它不是独立命令，也没有丢失

- 设备：MiWiFi R2D / 192.168.3.2
- 触发：2026-11-10 清理轮次里，我用裸命令 `diskacl-status` 与 `sh /userdisk/data/s8compat/versions/v1/diskacl-status` 两次调用失败，据此向用户说“该命令现在不存在”。**这个说法是错的**，本文给出核实结果。
- 结论：`diskacl-status` 一直是 `xiaomi-smb-adapter.sh` 的**子命令**，从未作为独立命令安装过；不存在“曾经有、后来被覆盖”的退化，也没有需要补的 wrapper。错在我的调用方式与表述。

## 1. 它从哪里来

它是 [recipes/samba/xiaomi-smb-adapter.sh](../../recipes/samba/xiaomi-smb-adapter.sh) 的 case 分支：

```
diskacl-status) diskacl_status ;;
```

设备上的实际文件与仓库版本一致：

| 项目 | 实际值 |
|---|---|
| 安装位置 | `/userdisk/data/s7root/xiaomi-smb-adapter.sh`（44 433 B，`-rwxr-xr-x`） |
| md5 | `00ca962470ad328081dc98fd0219f5af` |
| 仓库 `recipes/samba/xiaomi-smb-adapter.sh` md5 | `00ca962470ad328081dc98fd0219f5af`（一致） |
| 版本树内副本 | `/userdisk/data/s8compat/versions/v1/xiaomi-smb-adapter.sh`，`MANIFEST` 记录同一 md5 |
| 独立命令 | **不存在**：`command -v diskacl-status` 无输出；`/usr/sbin/diskacl*`、`/usr/bin/diskacl*` 均无；`PATH=/usr/sbin:/usr/bin:/sbin:/bin` |
| `s8compat/versions/v1/` 内容 | `MANIFEST`、`diskacl-sync.sh`、`hook.sh`、`hotplug.md5`、`samba.init.wrapper`、`xiaomi-smb-adapter.sh`，**没有** `diskacl-status` 文件 |

正确调用（本次实测，rc=0）：

```sh
sh /userdisk/data/s7root/xiaomi-smb-adapter.sh -r /userdisk/data/s7root/current diskacl-status
```

实际输出（14 行 key=value，原文）：

```
diskacl_chain=present
diskacl_jumps=2
diskacl_legacy_chain=absent
diskacl_legacy_jumps=0
diskacl_guest=enforced
diskacl_guest_iface=br-guest
diskacl_mode=blacklist
diskacl_decision=applied
diskacl_mode_source=explicit
diskacl_allowed=32
diskacl_denied=8
diskacl_entries=40
diskacl_unset=0
diskacl_iface=br-lan
diskacl_chain=s8-diskacl
diskacl_macfilter=/etc/config/macfilter
diskacl_updated=1794246444
```

（`diskacl_chain` 出现两次：第一次是“链是否存在”的 present/absent，第二次来自 state 文件的链名 `s8-diskacl`。）

## 2. 曾经存在后来消失，还是一直只是临时调用

**一直只是子命令调用。** 判定依据：

- 根分区只读（`/dev/ubi1_0 on / type ubifs (ro,…)`），`/usr/sbin`、`/usr/bin` 不可写；把独立命令装到 `/usr/sbin` 在这台设备上从一开始就不可能。
- 历史原始证据里记录的都是子命令输出：`docs/evidence/2026-11-09-stage4/b3-nmbd-deploy.txt`、`2026-11-09-diskacl/*.txt`、`2026-11-09-stage0-rollback/*.txt`、`2026-11-10-b1-takeover/coldboot-post.txt` 第 67 行起，全部是上面的 `diskacl_*=` 多行格式，不是一行 `chain=present jumps=2 …`。
- 仓库里也没有任何安装独立命令的代码：`grep -rn "diskacl-status"` 全部命中适配器的用法说明与 case 分支，没有安装到 `/usr/sbin` 的逻辑。

所以清理轮次的两次失败分别是：①裸名调用 → shell 找不到命令；②`sh .../s8compat/versions/v1/diskacl-status` → 该文件本来不存在。**这不是设备退化，是我的调用错误。**

## 3. 是否需要补 wrapper

不需要。适配器是唯一实现，`--help` 里也把 `diskacl-status` 列为其子命令；再加一层同名 wrapper 只会多一个可能与版本树脱节的入口。

如果确实想要短命令，最小改动是加一个只做转发的文件（**本轮未创建，供你决定**）：

```sh
# /userdisk/data/s7root/diskacl-status
#!/bin/sh
exec sh /userdisk/data/s7root/xiaomi-smb-adapter.sh \
  -r /userdisk/data/s7root/current diskacl-status
```

- 风险：极低（只读查询）；回退：删除该文件即可。
- 不建议放在 `/userdisk/data/s8compat/versions/v1/` 下，那是发布树，下次安装会被覆盖。

## 4. 之前那些输出里，哪些是实测、哪些是推断

| 字段 | 来源 | 实测还是派生 |
|---|---|---|
| `chain=present/absent` | `iptables -S` 里查 `s8-diskacl` 链是否存在 | 实测 |
| `jumps=2` | `iptables -S INPUT \| grep -c -- "-j s8-diskacl"` | 实测（本次同时被 `iptables -S INPUT` 的两条跳转佐证） |
| `legacy_chain=absent` / `legacy_jumps=0` | 查旧链 `s8-diskacl-legacy` 及其跳转 | 实测 |
| `guest=enforced` | `guest_rule_ok`：先数 `br-guest` 的 139/445 DROP 规则条数必须为 1，再比较该 DROP 与 `mixbox-firewall` ACCEPT 的规则序号，DROP 必须在前面 | **实测（基于 iptables 规则计数与位次）**，不是读配置文件推断 |
| `mode=blacklist` / `mode_source=explicit` | 解析 `/etc/config/macfilter` | 配置派生 |
| `allowed=32` / `denied=8` / `entries=40` / `unset=0` | 读取 `$ROOT/var/state/diskacl.state`，该文件由 `diskacl-sync.sh` 记账写入 | **同步任务的记账值**，不是每次实时数规则 |
| `updated=…` | state 文件时间戳 | 记账 |
| 我在散文里写的 `chain=present jumps=2 legacy_chain=absent guest=enforced` | 把上面 4 个实测字段压成一行摘要 | **是概括，不是原样输出**；原始多行输出在同一批证据文件里 |

因此：**结论本身有实测支撑**（链、跳转数、访客规则位次都是当场读 iptables），但“一行式”的写法是我的摘要，容易被误读成命令原样输出。已在 `coldboot.md` 该行加注原文位置。

## 5. 复核命令

```sh
command -v diskacl-status                                    # 无输出
ls -l /usr/sbin/diskacl* /usr/bin/diskacl*                   # 无文件
sh /userdisk/data/s7root/xiaomi-smb-adapter.sh -r /userdisk/data/s7root/current diskacl-status
iptables -S s8-diskacl | tail -2                             # 8 条 DROP + RETURN
iptables -S INPUT | head -5                                  # 两条跳转 + br-guest DROP
```
