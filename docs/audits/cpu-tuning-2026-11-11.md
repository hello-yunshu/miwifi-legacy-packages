# CPU 侧调优审计（R2D，2026-11-11）

结论：**保留 0 项**。这块板子在软件侧几乎没有 CPU 调优旋钮：没有 cpufreq、没有温控框架、没有 cpu cgroup；
存在的三个旋钮（IRQ/软中断亲和、nice/ionice、RPS）实测均未达到 8% 门槛。
本文与 [smb-tuning-2026-11-11.md](smb-tuning-2026-11-11.md) 同口径，机器不变、判据不变。

## 1. 探针：先确认旋钮到底存不存在

不按 MT7620A 型号推断，以下都是设备实测。

| 探针 | 结果 | 含义 |
| --- | --- | --- |
| `/sys/devices/system/cpu/cpu*/cpufreq/` | 不存在 | 无调频接口 |
| `cpu0/`、`cpu1/` 内容 | 只有 `online`、`topology` | 除上下线外无频率/策略节点 |
| `grep -c cpufreq\|thermal_zone\|devfreq /proc/kallsyms` | `0` | 内核里根本没有这些符号 |
| `/lib/modules/2.6.36/*cpufreq* thermal* devfreq*` | 无 | 也没编成模块 |
| `/sys/class/thermal/`、`/sys/class/hwmon/` | 都不存在 | 没有温度传感器节点 |
| `dmesg` 频率/温度相关 | 仅 `Calibrating local timer... 699.877MHz.`，无 cpufreq/thermal/throttle 报错 | 启动时定时器按 ~700 MHz 校准，此后无调频记录 |
| `/etc/init.d/` | 无任何 cpufreq 相关服务 | 没有用户态调频守护 |
| `/proc/cpuinfo` | 2 × ARMv7 (Cortex-A9, part 0xc09)，BogoMIPS 2798.38，无 `cpu MHz` 字段 | 核数 2、固定频率 |
| cpu cgroup | 只挂了 `memory`、`net_cls`；`mount -t cgroup -o cpu` 返回 ENOENT | **cpu 控制器未编译，权重旋钮不存在** |
| `/proc/sys/kernel/sched_*` | 只有 `child_runs_first`、`compat_yield`、`rt_period_us`、`rt_runtime_us` | 没有可调的 CFS 参数 |
| `/sys/class/net/eth0/queues/rx-0/rps_cpus` | 存在，值 `0` | RPS 已编译，默认关闭（可用） |
| 默认 IRQ 亲和 | 111(USB)=3、179(eth0)=3、175(ahci)=2 | 厂商已把 SATA 固定在 CPU1，网口与 USB 共享 CPU0 |

**结论**：governor / 频率档位 / 温度阈值 / 降频策略这些"旋钮"在这块板子上**不存在**——
不是没调对，是内核没编（kallsyms 与模块均为空，`/proc/config.gz` 也不提供），硬件侧也没有暴露 DVFS 或温度通道。
CPU 固定工作在启动时校准出的 ~700 MHz。

## 2. 基线（全部重测，未沿用上次数字）

机器空闲（load < 0.4，无他人压测）后重测，SMB 取 3 次中位数。

| 路径 | 小写 ms | 小读 ms | 列举 ms | 顺序写 MB/s | 顺序读 MB/s |
| --- | --- | --- | --- | --- | --- |
| 本地 sdb (tntfs) | 8.2 | 21.1 | 0.95 | 24.1 | 32.4 |
| 本地 sda (ext4) | 2.2 | 2.7 | 0.35 | 14.5 | 148.0 |
| SMB → 外接盘 | 69.1 | 44.3 | 6.87 | 24.6 | 31.6 |
| SMB → 本机储存 | 96.4 | 32.7 | 5.34 | 33.0 | 37.0 |

SMB 单步开销（外接盘，50 次均值）：CREATE 48.9 ms、WRITE 4K 5.7 ms、CLOSE 19.8 ms、STAT 6.1 ms、UNLINK 14.6 ms。
与上次一致：CREATE + CLOSE 占单文件总耗时 ~90%，这两步的主体在客户端与协议往返，不在服务端 CPU。

**漂移必须在同一次会话里对照**：本地 sdb 小文件写在没有任何改动的情况下从 8.2 ms 漂到 6.0 / 5.1 ms，
小读 21.1 → 25.3 / 20.2 ms。原因是 tntfs 元数据缓存预热。下面每一项都带同期对照或与基线中位数比较。

## 3. 逐项实验

判据：小文件写/读/列举任一改善 ≥8%，且其他项不退化 >8%；大文件只作"不能退化"约束。

### C1 IRQ 亲和：eth0 (179) CPU0 → CPU1

- 机制层：中断/软中断分布（不是块层、不是 VFS）。
- 依据：传输中 cpu0 约 39% 忙、cpu1 约 9% 忙（6 s jiffies 采样），eth0 与 USB 都在 CPU0。
- 结果（外接盘 SMB，3 次）：小写 69.2 / 71.1 / 60.5（中位 **69.2**，0%）；小读 46.6 / 44.3 / 47.3（中位 **46.6**，−5.2%）；
  列举 6.91 / 7.86 / 6.92（中位 **6.91**，−0.6%）；顺序写 24.9 / 21.4 / 25.7；顺序读 32.8 / 32.6 / 31.1。
- 本地 sdb 同期看似变好（小写 6.5、小读 16.3），但回滚后的对照是 6.0/25.3 与 5.1/20.2 —— 是漂移，不是效果。
- 判定：**放弃**。CPU 利用率只有 ~24%（两核平均），中断搬家换不来吞吐；磁盘仍是限速点（17–24 MB/s）。

### C2a nice：`samba-s5d` 全部进程 renice -10

- 机制层：CPU 调度器（CFS 权重）。
- 结果（外接盘，3 次）：小写 63.5 / 69.1 / 73.2（中位 **69.1**，0%）；小读 46.3 / 43.2 / 46.5（中位 **46.3**，−4.5%）；
  列举 7.27 / 7.24 / 6.92（中位 **7.24**，−5.4%）；顺序写 23.8 / 21.2 / 21.0（中位 21.2，−13.8%）；顺序读 30.4 / 31.7 / 31.6。
- 判定：**放弃**。系统 93–95% 空闲，没有 CPU 竞争可抢；提高优先级只改变排队顺序，不改变 I/O 等待。

### C2b ionice：`samba-s5d` 设 realtime / prio 0

- 机制层：块层 I/O 调度（cfq ioprio）。
- 结果（外接盘，3 次）：小写 76.2 / 74.7 / 63.4（中位 **74.7**，−8.1%）；小读 46.7 / 46.0 / 48.0（中位 **46.7**，−5.4%）；
  列举 6.72 / 7.06 / 7.14（中位 **7.06**，−2.8%）；顺序写 24.4 / 25.9 / 25.3（中位 25.3，+3%）；顺序读 30.0 / 31.9 / 30.9。
- 判定：**放弃**。外接盘只有一个消费者，cfq 队列里没有竞争者；RT 类只是把本就空的队列排得更靠前。

### C3 RPS：eth0 `rx-0/rps_cpus` 0 → 2（软中断收到 CPU1）

- 机制层：网络协议栈软中断分布（介于中断层与 SMB 层之间）。
- 结果：r1 小写 65.7 / 小读 46.4 / 列举 7.46；**r2 客户端报 `OSError: [Errno 22]`**；r3 小写 91.1 / 小读 71.7 / 列举 11.02。
  回滚后重挂载的对照：61.1 / 62.9（小写）、43.3 / 44.7（小读）、6.91 / 6.80（列举）。
- 判定：**放弃**。没有稳定收益，且出现一次传输失败和一次明显退化；2.6.36 上这个组合不值得冒险。

### C4 关掉无用服务释放 CPU

- 实测占用（累计 CPU 时间 / 开机 9h43m）：`taskmonitorServer` 3:29（≈0.6%）、`trafficd` 0:25、`taskmonitorDaemon` 0:11，
  其余可关服务均在 0:1x 以下；空闲时整机 93–95% idle。
- 判定：**不采纳**。可回收的总 CPU 不足 1%，离 8% 门槛差一个数量级；而这些是厂商管理面组件，关掉影响状态上报与远程管理。

### C5 flow offload 对 SMB 的影响

- 事实：`ctf` 已加载，mangle `PREROUTING` 里只有 `SKIPCTF` 与 `miqos_fw`，dmesg 显示阈值 3 MB、mark 0x200000→0x400000。
- 机制：硬件转发卸载只走 **FORWARD** 路径；SMB 是本机 `INPUT` → smbd 进程 → 本地磁盘，从不经过转发。
- 判定：**无影响**，不开不关。改动只会影响路由/ NAT 转发流量，与 SMB 无关。

### C6 温度与热降频

- 探针：无 thermal zone、无 hwmon、无 thermal 驱动、无 throttling 报错（见第 1 节）。
- 间接验证：两个核各跑满负载，用固定次数的 shell 循环计时（150k 次迭代）：
  空闲 3.19 / 3.21 s；满载 20 s 时 6.48 s；满载 80 s 时 4.34 s；满载 140 s 时 6.41 s。
  若发生热降频，耗时应单调变长；实测没有单调趋势，140 s 与 20 s 持平。
- 判定：**不存在可观测的热降频**，也没有可调阈值；只能记录"无此机制"。

### 不做的候选及原因

| 候选 | 不做的原因 |
| --- | --- |
| governor / 频率档位 | 旋钮不存在（无 cpufreq 驱动、无 kallsyms 符号、无模块） |
| cpu cgroup 权重 | cpu 控制器未挂载且不可挂载（`mount -o cpu` ENOENT） |
| `taskset` 绑核 | 只有 2 核；把 smbd 绑到单核会牺牲多连接并行，机制上必然退化 |
| `chrt` 实时优先级 | 会让 smbd 抢占厂商管理面与 USB 内核线程，风险大于收益，且 C2a 已证明无 CPU 竞争 |
| CPU1 下线 | 是降级不是调优 |

## 4. Mac 端能拿到的天花板

上一轮已确认：单文件 4 KB 创建在 Mac 侧约 64 ms，其中服务端只占 ~31%。本轮所有 CPU 侧手段都作用在服务端，
即使把服务端耗时压到 0，Mac 端也只能从 69 ms 降到约 48 ms（−30%）。而实测没有任何一项产生 ≥8% 的 SMB 端改善，
C1/C2a/C2b 的小读、列举还各退化 3–5%。**结论：CPU 侧不存在能让 Mac 端手感变好的开关。**

## 5. 最终状态与回滚核对

| 项 | 实验值 | 现在 | 核对方式 |
| --- | --- | --- | --- |
| irq179 (eth0) | 2 | **3** | `cat /proc/irq/179/smp_affinity` |
| irq111 (USB) | 未动 | **3** | `cat /proc/irq/111/smp_affinity` |
| irq175 (ahci) | 未动 | **2**（厂商默认） | `cat /proc/irq/175/smp_affinity` |
| eth0 rps_cpus | 2 | **0** | `cat /sys/class/net/eth0/queues/rx-0/rps_cpus` |
| samba nice | −10 | **0**（全部 PID） | `awk '{print $19}' /proc/<pid>/stat` |
| samba ioprio | realtime:0 | **none:0** | `ionice -p <pid>` |
| sdb 调度 | 未动 | **[cfq]** | `/sys/block/sdb/queue/scheduler` |
| sdb 预读/单次请求 | 未动 | **1024 / 512** | `read_ahead_kb`、`max_sectors_kb` |
| smb.conf | 未动 | **与基线逐字节一致** | `diff -q` → `CONF_BASELINE` |
| swap | — | **0 KB 使用** | `free` |
| 测试目录 | — | 已删（`/extdisks/sdb1/.smbtest`、`/userdisk/data/.smbtest`） | `ls` 报 No such file |

备份：`/userdisk/data/.yunshu/backups/cpu-tune-20261111/{C1,C2a,C2b,C3}/MANIFEST.txt`（含 purpose / before / after / rollback）。

## 6. 落点

本次保留 0 项，**仓库不需要任何改动**：
`recipes/samba/xiaomi-smb-adapter.sh`、hotplug hook、`init.d`、UCI 键均保持原样，`config_guard` 不触发。

若将来要重新评估（不建议）：IRQ 亲和需要一个 `init.d` 脚本在启动后写 `smp_affinity` 并在 stop 时恢复 `3`；
nice/ionice 需要在启动 samba-s5d 的包装器里设置并由子进程继承；RPS 需要 hotplug 在 `eth0` up 后写 `rps_cpus`。
三者的实测数据都在第 3 节，届时可直接复用，不必重跑。

## 7. 方法论披露

1. 基线全部重测，未复用 [smb-tuning-2026-11-11.md](smb-tuning-2026-11-11.md) 的旧数字；
   旧基线小文件写 68.1 ms，本轮 69.1 ms，量级一致但不可混用。
2. 顺序写存在"首次慢"现象（同一配置下 5.6 / 5.7 MB/s 与 21–25 MB/s 交替出现），与 tntfs 分配区状态有关；
   该项只作"不能退化"参考，不参与判据。
3. 小文件写本身有 ±10% 抖动（基线 61.8–74.7 ms），因此每项取 3 次中位数，并优先看 CREATE/CLOSE 分步值。
4. 本地 sdb 的小文件数字在无改动时也会漂（8.2 → 5.1 ms），所以涉及本地的结论一律配同期对照，不跨时段比较。
