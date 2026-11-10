# samba-homes-fix — `[homes]` 隐藏的持久化

`recipe` 只在设备侧，不改 Samba payload、不递增包版本。背景与实测见 `docs/decisions.md` S15（D-S15-01..05）。

## 为什么要它

冷启动时厂商 `datacenter`（START=80）会把 `/etc/config/samba` 重写回 `homes=1`，**且重写是异步的**——init 返回之后才落盘。只设一次 UCI 不持久，所以需要 `START=97` 的 init 加有界复检。

## 文件

| 文件 | 设备位置 |
|---|---|
| `samba-homes-fix.init` | `/etc/init.d/samba-homes-fix`（与设备字节一致，md5 `ed9f963a…`） |

## 行为

- 幂等：`homes` 已是 0 时只记 `no-op`，不写配置、不 reload。
- 写入路径：`uci set homes=0` + `uci commit` + reload；reload 后校验 smbd，被带停则 `stop`+`start` 自愈。
- 后台有界复检 +15/+30/+45/+60/+90 秒，被改回 1 就再压一次，顺带确认 smbd 存活。
- 日志：`/userdisk/data/.yunshu/live/samba-homes-fix.log`，每行带 `[uptime N]`。

## 安装与回退

```sh
cp samba-homes-fix.init /etc/init.d/samba-homes-fix
chmod 755 /etc/init.d/samba-homes-fix
/etc/init.d/samba-homes-fix enable        # 生成 S97 / K10
/etc/init.d/samba-homes-fix dryrun         # 只看计划，不写
/etc/init.d/samba-homes-fix check          # 手工复检一次

# 回退：homes=1 + reload
/etc/init.d/samba-homes-fix restore
# 或彻底移除
rm -f /etc/rc.d/S97samba-homes-fix /etc/rc.d/K10samba-homes-fix /etc/init.d/samba-homes-fix
```

改动前的配置副本：`/userdisk/data/.yunshu/backups/homes-persist-20261110/`。
