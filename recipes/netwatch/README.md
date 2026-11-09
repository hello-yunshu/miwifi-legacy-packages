# netwatch — 网络状态取证看门狗

只读采集，不写配置、不 reload 任何服务。用途是复现“开机约 90 秒掉网”时留下断网瞬间的现场；根因结论见 `docs/decisions.md` S15（D-S15-06、D-S15-07）。

## 文件

| 文件 | 设备位置 | 作用 |
|---|---|---|
| `netwatch.env` | `/userdisk/data/.dev/live/netwatch/netwatch.env` | 开关与参数（`ENABLED`/`INTERVAL`/`KEEP`/`MINKB`），每周期重读 |
| `netwatch.sh` | `/userdisk/data/.dev/live/netwatch/netwatch.sh` | 采样循环；每份快照含 `ip addr`、`brctl show`、`ip route`、`iptables-save` |
| `run.sh` | `/userdisk/data/.dev/live/netwatch/run.sh` | `start`/`stop`/`status`/`uninstall`，负责等数据盘挂载、pidfile |
| `netwatch.init` | `/etc/init.d/netwatch` | `START=98`、`STOP=10`，开机在数据盘就位后拉起 |

快照写到 `/userdisk/data/.dev/evidence/netwatch/<epoch>.snap`，约 20.7 KB/份，环形保留 200 份（约 4 MB），按 **mtime** 裁剪——开机时钟回跳 2018 会让 epoch 文件名排序失效，不要改成按文件名排序。

## 安装与停用

```sh
# 安装（文件已就位后）
/etc/init.d/netwatch enable
/etc/init.d/netwatch start

# 停用：改开关，下一周期自动退出（推荐）
sed -i 's/^NETWATCH_ENABLED=1/NETWATCH_ENABLED=0/' /userdisk/data/.dev/live/netwatch/netwatch.env

# 彻底卸载：删 rc.d 链接与 init，保留历史快照
/userdisk/data/.dev/live/netwatch/run.sh uninstall
```

## 注意

- 数据盘不可写（`df -k` 低于 `NETWATCH_MINKB`）时跳过本轮，不阻塞。
- 快照是滚动窗口，只有最近 200 份；需要长期留证时把目录整体拷走。
