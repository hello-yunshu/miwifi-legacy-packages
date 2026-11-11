# R2D SMB / 外接盘调优决策审计（2026-11-11）

- 设备：MiWiFi R2D，MT7620A 2 核 / 254 MB RAM / 256 MB swap，内核 2.6.36
- 外接盘：WD Elements 25A2 1 TB，NTFS，USB 2.0 Hi-Speed，`usb-storage`（BOT，无 UAS）
- 服务端：Samba 4.25.1（自建树 `/userdisk/data/.yunshu/live/samba/current`），`server min protocol = NT1` / `max = SMB3`
- 客户端：macOS 经有线（实测链路 42 MB/s），协商 SMB3.11、无签名、无加密
- 全部实验为单变量、改前备份、测后回滚；备份在 `/userdisk/data/.yunshu/backups/smb-tune-20261111/<实验号>/`（含 `MANIFEST.txt`）

## 1. 结论摘要

**保留 0 项。** 九组候选（含补测的 `strict sync`）没有任何一项在 SMB 端达到「≥8% 改善且不拖累其他项 >8%」的门槛。

这不是"没调"，而是三条硬边界叠加的结果：

1. **USB 2.0 BOT**：顺序写 25 MB/s、顺序读 31 MB/s 即为设备上限，块层参数无法突破。
2. **tntfs 元数据路径**：同一份 200 个 4 KB 文件，ext4 本地 0.51 s，tntfs 本地 4.62 s，差 9 倍。
3. **macOS 客户端往返**：同样配置下设备本地 `smbclient` 上传 200 个文件 **20 ms/个**，Mac 客户端 **64 ms/个**，服务端只占约 31%。

因此在这台机器上继续调 Samba 参数，**上限是把 Mac 端的 64 ms 压到约 20 ms 的理论值，但没有任何一个配置项能做到**；能动的只有"换盘/换文件系统"和"换客户端"，两者都不在本次授权范围内。

## 2. 基线（最终复核，全部回滚后）

### 2.1 存储层（设备本地，不走网络）

| 指标 | sdb 外接 NTFS | sda 本机 ext4 |
|---|---|---|
| 顺序写 256 MB | 25.0 MB/s | 15.0 MB/s |
| 顺序读 256 MB | 31.4 MB/s | 171 MB/s |
| 200×4 KB 写 | 1.48 s | 0.55 s |
| 200×4 KB 读 | 3.52 s | 0.51 s |
| 200 项列举 | 0.17 s | 0.045 s |

### 2.2 SMB 层（Mac 客户端，外接盘）

| 指标 | 中位值 |
|---|---|
| 顺序写 256 MB | 25.0 MB/s |
| 顺序读 256 MB | 31.4 MB/s |
| 200×4 KB 写 | 64.3 ms/个 |
| 200×4 KB 读 | 46.8 ms/个 |
| 200 项列举 | 6.74 ms/项 |

### 2.3 小文件开销构成（Mac 客户端，50 次均值）

| 步骤 | 耗时 | 说明 |
|---|---|---|
| CREATE | 51 ms | 单次 SMB2 CREATE + lease 申请 |
| WRITE 4 KB | 5.8 ms | 客户端写缓冲，几乎不等待 |
| CLOSE | 19.7 ms | 关闭 + lease 释放 |
| STAT | 6.0 ms | QUERY_INFO |
| UNLINK | 15 ms | 删除 + 目录项更新 |

同一套操作在设备本地 `smbclient` 上是 **20 ms/个**（create+write+close 合计），说明 CREATE 的 51 ms 里有约 45 ms 花在 macOS 客户端与网络栈，而不是 Samba。

## 3. 逐项结果

判定口径：以 200×4 KB 读写、200 项列举为主判据；大文件只作「不得退化」约束；门槛为改善 ≥8% 且其他项退化 <8%。

| # | 变量 | 改动 | SMB 小写 | SMB 小读 | SMB 列举 | SMB 顺序读 | 判定 |
|---|---|---|---|---|---|---|---|
| E1a | sdb 调度 | cfq → noop | 64.0 | 46.8 | 6.19 | 30.5 | 放弃 |
| E1b | sdb 调度 | cfq → deadline | 68.7 | 44.4 | 8.31 | 32.7 | 放弃 |
| E2b | sdb 预读 | 1024 → 512 KB | 72.7 | 45.1 | 6.92 | 27.3 | 放弃 |
| E3 | sdb 单次请求 | 512 → 720 KB | 68.0 | 42.5 | 6.38 | 31.6 | 放弃 |
| E4 | Samba | `strict allocate` yes | 67.2 | 45.2 | 6.62 | 20.1 | 放弃 |
| E5 | Samba | `use sendfile` no | 69.1 | 45.2 | 6.83 | 28.9 | 放弃 |
| E6 | Samba | `vfs objects = aio_pthread` + `aio max threads = 4` | 64.3 | 46.3 | 7.99 | 30.5 | 放弃 |
| E7 | IRQ | USB 111 → CPU1 | 61.7 | 43.9 | 6.84 | 30.7 | 放弃 |
| E8 | Samba | `smb2 max *` 1 MB → 256 KB | 66.0 | 45.8 | 7.15 | 30.5 | 放弃 |
| E9 | Samba | `strict sync` Yes → no | 64.8 | 44.8 | 7.24 | 31.4 | 放弃 |

（单位：小写/小读 ms/个，列举 ms/项，顺序读 MB/s）

### 逐项机制

- **E1a noop**：本地小文件写 +8.8%，但本地小文件读 −9.9%（cfq 的合并对元数据读更友好），SMB 端三项均在噪声内。收益来自块层合并不再发生，方向互斥。
- **E1b deadline**：没有任何并行度收益，反而打乱 tntfs 元数据局部性，SMB 列举 −30%。
- **E2b 预读 512 KB**：顺序读 −13.6%，预取窗口低于 USB2 单命令粒度；本地小读的「改善」方向与其他所有指标相反，判噪声。
- **E3 720 KB**：只改单条 SCSI 命令上限，tntfs 小 IO 完整性检查窗口变大，本地读写各 −18%。
- **E4 strict allocate**：首次写入按全长预分配，tntfs 零填充新簇；4 KB 文件无变化，256 MB 顺序读 −36%（碎片化）。
- **E5 sendfile**：4.25.1 中只作用于 SMB1 readraw，Mac 走 SMB2 read，**结构性不经过该路径**，属"测不到"而非"没改善"。
- **E6 aio_pthread**：补了 4 路并发对照（4×50 文件），两边中位都是 10.60 s。tntfs + USB BOT 在块层单队列串行，线程池只是换个线程排队。
- **E7 IRQ 拆核**：亲和性生效（111 号 CPU1 计数 0 → 67528），但单线程小文件路径上 USB 中断本就稀疏，两核都未饱和；对照组复测 62.9 ms，与实验组 61.7 ms 无差异。
- **E8 smb2 max 256 KB**：4 KB 文件远低于任一上限，参数对小文件天然无效。
- **E9 strict sync**：SMB2 客户端不发 write-through 标志，该参数在实际写入路径上不被触发；关闭后无变化，且关闭会牺牲断电持久性，不划算。

### 方法论披露

E0 到收尾，同一基线的小文件写从 68.1 ms 漂移到 62.9–64.3 ms（约 6%），属于 tntfs 元数据缓存预热带来的机器级漂移。为此对 E1a/E1b/E7 补了同期对照，E6 补了并发对照；其余各项的「持平」结论在漂移幅度内，方向不变。**E7 的 +9.4% 正是在对照复测后被判定为漂移的**，不作为收益。

## 4. 放弃项的回滚（均已执行，留存备查）

| # | 回滚命令 |
|---|---|
| E1a/E1b/E2b/E3 | `echo cfq > /sys/block/sdb/queue/scheduler`；`echo 1024 > .../read_ahead_kb`；`echo 512 > .../max_sectors_kb` |
| E4/E5/E6/E8/E9 | `cp <备份>/smb.conf.before <root>/etc/smb.conf && <root>/bin/smbcontrol smbd reload-config` |
| E7 | `echo 3 > /proc/irq/111/smp_affinity` |

收尾核对：smb.conf 与基线逐字节一致（`diff -q` = SAME），`scheduler=[cfq]`、`read_ahead_kb=1024`、`max_sectors_kb=512`、`irq111=3`，测试目录 `/extdisks/sdb1/.smbtest`、`/userdisk/data/.smbtest`、`/userdisk/data/共享/.smbtest` 已删除，swap 归零。

## 5. 若后续要落地某项，落点在哪

本次没有保留项，以下为将来的确切落点，避免改动只留在设备上：

| 改动类型 | 仓库位置 | 运行时位置 | 说明 |
|---|---|---|---|
| Samba 参数 | `recipes/samba/xiaomi-smb-adapter.sh` 的 `[global]` 渲染段 | 由适配器 `generate` 生成 | 手改 `etc/smb.conf` 会在下次 `generate`/`reload` 被覆盖 |
| UCI 新键（如 `misc.samba.tune_profile`） | 适配器读取 + `recipes/` 内 UCI 片段 | `/etc/config/misc` | 改完须采纳一次：`S5_ACCEPT_CONFIG=1 <adapter> generate` |
| 块队列 / 预读 | 新增 `recipes/.../hotplug/block/41-smb-tune` | `/etc/hotplug.d/block/41-smb-tune` | 必须排在厂商 `40-mount` 之后，否则重挂覆盖 |
| IRQ 亲和性 | 新增 `recipes/.../init.d/smb-irq` | `/etc/init.d/smb-irq` | `start` 写 `2`，`stop` 恢复 `3` |

### `config_guard` 的采纳方式

适配器把 `/etc/config/samba` 与 `/etc/config/misc` 的 md5/size/mtime/inode 记录在 `<root>/var/state/config-baseline`。任何 UCI 改动都会让下次 `generate` 返回 **exit 7**（配置源漂移，拒绝渲染）。采纳步骤：

1. 人工确认 UCI 改动内容；
2. `S5_ACCEPT_CONFIG=1 <adapter> generate` —— 重写 baseline，并复制 `samba.accepted` / `misc.accepted`；
3. `<adapter> check` 确认隔离与端口；
4. 记录到 `docs/decisions.md`。

## 6. 不建议改的既有项

- `fail_safe`（tntfs 挂载）：关闭能提速，但增加断电损坏风险，盘上是唯一一份数据，**不动**。
- 换 ntfs3：该驱动 Linux 5.15 才合入，本机内核 2.6.36 不存在，移植不可行。
- 换 ext4：需搬 400 GB，USB2 上约 9–10 小时且全程单份数据，**不迁**；若将来做，用第二块盘冷拷贝后在 PC 上格式化。
- `deadtime = 30`：空闲 30 分钟断连，下次访问要重连；但 254 MB 内存下保留它可回收 smbd 内存，**不动**。
- `vfs objects = fruit`：会生成 `._*` 伴生文件污染 Windows/电视端视图，macOS 走 SMB3 不启用也能正常读写，**不启用**。
