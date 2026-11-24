# R2D NAND 磨损实测与寿命估算（2026-11-19）

对应决策 D-S28-17；监控并入 `recipes/hdd-tune/smart-check.sh` 的 `nand` 子命令。

## 结论先行

- 主板 NAND 为 4 Gbit（512 MiB）SLC 级芯片：page 2 KiB / OOB 64 B / block 128 KiB，
  控制器 `brcmnand`，全片 UBI + UBIFS。
- 数据卷 ubi2（mtd10 `overlay`，承载 `/data`、`/userdisk`、`/etc`）当前
  **平均擦除 10,652 次、最大 11,561 次、最小 7,484 次**，坏块 1 个（0.05%）。
- 按 6.1–9.1 年的使用年限折算，磨损速率约 **3.2–5.2 次擦写/天/块**；
  若 P/E 为 SLC 常见的 60k，剩余寿命约 **25–38 年**；按 100k 则 47–69 年。
- 已消耗额度 12%–19%，**P/E 不是本机的故障风险**；真实风险排序为
  坏块增长 < 掉电写中断 < 长期不通电的电荷保持。
- 当前残余写入已降到噪声级：日志在 `/tmp`、Samba/webdav 运行时在 tmpfs，
  `/etc/config/messaging` 约每 1–1.5 分钟改写一次（约 1000 次/天），
  `syslog-ng.helper` 约每 3 天把 1 MB `/tmp/messages` 追回到 NAND 日志。

## 环境

- 设备：R2D @ 192.168.1.2，`Linux 2.6.36 #3 MiWiFi-R2D-2.25.209`（armv7l 双核）。
- 只读取证，未执行任何擦写；dmesg 已清空且该内核 UBI 无 debugfs，
  因此拿不到厂商芯片型号，只能按几何特征归类。

## 分区与 UBI 卷

| MTD | 名称 | 大小 | 说明 |
|---|---|---|---|
| mtd0–mtd4 | boot/nvram/board_data/crash/rsvd0 | 0.25–0.5 M | 启动与参数 |
| mtd5/6 | os0/os1 | 4 M | 双系统内核 |
| mtd7 | rsvd1 | 6 M | 预留 |
| mtd8/9 | rootfs0/rootfs1 | 128 M | 双系统根；当前只挂 rootfs0 |
| mtd10 | overlay | 240 M | UBI2：`/data`、`/userdisk`、`/etc` |

`ubinfo -a`：

- ubi1 ← mtd8：1024 PEB，LEB 126,976 B，`max_ec=183`，`bad=0`，只读根（UBIFS `ro`）。
- ubi2 ← mtd10：1919 PEB，`max_ec=11561`，`bad_peb_count=1`，预留 76 块；
  `/data` 使用 22.7 MB / 204 MB（11%）。

## 方法

UBI 把每个物理块的擦除计数写在块的 EC 头里（magic `UBI#`、version 后 8 字节
big-endian `ec`）。对 mtd10 的 1920 个块逐个读第 0 页前 16 字节，解析 `ec`：

```sh
for i in $(seq 0 1919); do
  printf '%s ' $i
  dd if=/dev/mtd10 bs=2048 skip=$((i*64)) count=1 2>/dev/null |
    dd bs=1 skip=8 count=8 2>/dev/null | hexdump -v -e '8/1 "%02x "'
  echo
done | awk '...'   # 统计 min/max/avg 与直方图
```

只读，无磨损；坏块读出的 `ec` 为全 `0xFF`，按 >1000000 过滤。结果与
`/sys/class/ubi/ubi2/max_ec`（11,561）一致，说明采样覆盖完整。

## 实测分布

样本 1919 个有效块（另有 1 个坏块）：

| 区间 | 块数 |
|---|---|
| 7,000–7,999 | 17 |
| 8,000–8,999 | 308 |
| 9,000–9,999 | 194 |
| 10,000–10,999 | 266 |
| 11,000–11,999 | 1,134 |

- 平均 10,652，最大 11,561，最小 7,484；最大/平均 = 1.085。
- 磨损在块间只差约 ±20%，说明 UBI 动态 + 静态磨损均衡正常，没有热点块。

## 派生量

- 累计擦除 ≈ 1919 × 10,652 ≈ **2,044 万次**。
- 按 LEB 126,976 B 折算 ≈ **2.36 TiB** 的逻辑块写入，
  相当于整卷（240 MB）被完整重写约 1.07 万次。
- 年龄取两个证据点：`/data` 目录时间戳 2020-10（6.1 年）、`/etc` 内最早文件
  2017-10（9.1 年）。对应最大块速率 5.2 / 3.5 次/天。

## 寿命估算（按最大块 EC = 11,561）

| P/E 额定 | 剩余次数 | 5.2 次/天 | 3.5 次/天 |
|---|---|---|---|
| 60,000 | 48,439 | 25.6 年 | 38.0 年 |
| 100,000 | 88,439 | 46.7 年 | 69.3 年 |

- 已用额度：19%（60k）或 12%（100k）。
- 写入量再翻 10 倍，仍有 2.5–4 年余量。
- 反证：芯片已扛过 11,561 次擦写仍无异常，可排除普通 MLC（典型 3k 次）。

## 处置

- 并入既有 `recipes/hdd-tune/smart-check.sh`：新增 `nand` 子命令，每月 1 日的
  `collect` 顺带调用（与 SMART 收集同一次转盘窗口，不新增 cron），把 ubi1/ubi2 的
  `max_ec`、坏块数、PEB 数、`/data` 占用追加到 `/userdisk/data/.yunshu/live/tools/
  smart.log`；`max_ec ≥ 30000` 或 `bad_peb_count ≥ 8` 时写 syslog 告警。
  独立的 `nand-check.sh` 与 `nand.log` 已撤销，避免两套 cron、两份日志。
- 基线记录（`smart-check.sh nand` 实测）：
  `=== 2026-11-19 01:30:19 nand / ubi1 max_ec=183 bad_peb=0 /
  ubi2 max_ec=11561 bad_peb=1 pebs=1919 / /data used=23212K (11%)`。
- 明确不做的改动：
  - 不改 `compr=none` 为压缩：剩余写入已是噪声级，收益不可测，却要改挂载参数。
  - 不把 `/etc/config` 迁到 HDD 或 tmpfs：会引入 HDD 依赖或掉配置风险，
    而 `/etc/config/messaging` 的周期写入约 1000 次/天，折算不到 0.01 次/天/块。
  - 不删除 `/data/usr/log` 历史日志：占用仅 5.7 MB（11% 使用率），保留掉电/崩溃
    排查能力更重要。
