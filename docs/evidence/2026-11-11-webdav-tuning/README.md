# WebDAV 调优实测：六个变量全部无收益，配置保持原样（2026-11-11）

计划与判定规则见同目录 [plan.md](plan.md)。本文件是执行结果与结论。

## 结论先行

- 在 Wi-Fi 客户端上，`stream-request-body`、`stream-response-body`、`linux-sendfile`、
  `stat-cache-engine=inotify`、`mod_deflate`、`max-connections=64` 六组改动**全部落在基线噪声内**，
  没有任何一组达到「目标指标改善 ≥ 10%」的门槛。
- 原因是瓶颈不在 lighttpd：设备本机 loopback 上 PUT 29.9 MB/s、GET 35 MB/s，
  4 路并发 GET 聚合 37.1 MB/s；而同一台机器经 Wi-Fi 的单流只有 9–16 MB/s。
  lighttpd 的请求体/响应体复制、stat、压缩都不构成限制。
- **最终不改任何配置**，`recipes/webdav/lighttpd.conf` 与设备上的 `conf/lighttpd.conf`
  均保持 B0 原样。设备上只多留一个 `conf/lighttpd.conf.bak-b0` 备份，可直接删除。
- 客户端侧差异远大于服务端变量：同样 200 个 4 KB 文件，keep-alive 约 1.0 s，
  每文件一个 `curl` 进程 5.80 s，`xargs -P 8` 2.39 s；SMB 为 26.1 s。

## 环境与方法

- 设备：R2D，Linux 2.6.36，254 MB RAM / 2 核；lighttpd 1.4.85（uClibc/armv7，无 PCRE）。
- 目标：`本机储存`（`/dev/sda1` ext4），排除外接盘与 SMB 变量。
- 客户端：Mac 经 Wi-Fi；`/tmp/wdtune.py` 单连接 keep-alive、预置 Basic，
  一轮内按 `MKCOL → 200×4 KB PUT/GET → PROPFIND Depth 1 → 64 MB PUT/GET → DELETE` 顺序执行，
  共 3 轮取中位数。每轮前后记录 `load average`、`MemFree`、`SwapFree`、lighttpd RSS、`state/tmp`。
- 前置检查：测试窗口内无 `mdworker`/Spotlight 索引、无 SMB 挂载、无残留脚本
  （按 `/proc/*/cmdline` 逐个匹配确认，不使用会截断命令行的 busybox `ps`）。
- 每组流程：从 `conf/lighttpd.conf.bak-b0` 还原 → 追加唯一改动 → `lighttpd -t` 校验 →
  `run.sh restart` → 预热 → 3 轮 → 记录资源水位 → 恢复 `bak-b0` 并 `restart`，
  用 `diff` 确认与备份一致后才进入下一组。
- 测量窗口内 `load 0.04–0.92`、`MemFree 142–180 MB`、`SwapFree 240968 kB` 未下降，
  无 OOM 记录，`state/tmp` 始终 4 KB（请求体未落临时文件）。

## 基线与逐变量对照（3 轮中位数）

| 变量 | 200×4 KB 写 | 200×4 KB 读 | PROPFIND D1 | 64 MB 写 | 64 MB 读 | 结论 |
|---|---|---|---|---|---|---|
| **B0 基线** | 0.99 s | 0.90 s | 0.025 s | 15.8 MB/s | 9.3 MB/s | — |
| V1 `stream-request-body = 2` | 1.04 s | 0.96 s | 0.026 s | 14.9 MB/s | 9.4 MB/s | 放弃 |
| V2 `stream-response-body = 1` | 1.07 s | 0.91 s | 0.024 s | 14.5 MB/s | 9.0 MB/s | 放弃 |
| V3 `network-backend = linux-sendfile` | 1.00 s | 0.89 s | 0.026 s | 13.8 MB/s | 9.5 MB/s | 放弃 |
| V4 `stat-cache-engine = inotify` | 1.08 s | 0.86 s | 0.024 s | 13.7 MB/s | 9.2 MB/s | 放弃 |
| V5 `mod_deflate`（text/xml，≥1 KB） | 1.10 s | 0.85 s | 0.026 s | 13.6 MB/s | 8.9 MB/s | 放弃 |
| V6 `max-connections = 64` | 1.01 s | 0.85 s | 0.025 s | 14.9 MB/s | 9.3 MB/s | 放弃 |

### V1 `server.stream-request-body = 2`

预期把 PUT 请求体直接流给目标文件、省掉 `state/tmp` 中转。实测 `state/tmp` 在整个测试中始终为
4 KB（64 MB PUT 未落盘到临时目录，默认行为已经是流式），因此没有可省的开销，数字与基线重合。

### V2 `server.stream-response-body = 1`

预期降低大文件 GET 的首字节延迟。64 MB 读 9.0 MB/s 与基线 9.3 的差异小于轮间波动
（基线自身两轮为 9.3 / 9.5），无收益。

### V3 `server.network-backend = "linux-sendfile"`

构建确实带 `+ linux-sendfile`，但 64 MB 读 9.5 MB/s 与基线持平。原因是单流已被 Wi-Fi 限速在
10 MB/s 左右，零拷贝省下的 CPU/拷贝在内核 socket 发送端，不是当前瓶颈。**注意**该构建同时支持
`writev`，默认值本身已足够。

### V4 `server.stat-cache-engine = "inotify"`

默认 `simple` 已缓存 stat；200 项 PROPFIND 0.024 s 未变。本机储存根目录只有十几个条目，
不存在 stat 风暴（与 `2026-11-11-usb-first-access` 的结论一致）。`inotify` 在该内核上工作正常、
未报错，但没有收益，而且会多占内核 watch 资源，不值得引入。

### V5 `mod_deflate`

只对 `text/*` 与 `application/xml` 生效、最小 1 KB，避免碰二进制大文件。实测 200 项
`PROPFIND` 响应仍为 52429 B（未压缩）、0.034 s；64 MB 写读与基线持平。原因是
`mod_webdav` 的 207 响应走自己的输出路径，未被 deflate 过滤器接管；XML 体积也不足以抵消
压缩开销。**不要为了"看起来更快"引入压缩，它没有作用面。**

### V6 `server.max-connections = 64`

默认上限不是当前的约束（单客户端 keep-alive 只占 1 条连接，并发测试也只到 8 条）。
RSS 2088 kB、`MemFree` 未显著变化，数字与基线重合。调大连接上限只会增加内存上限，
在 254 MB 机器上没有收益。

### V7 `server.max-request-size`：不设，保持默认

该选项单位是 **KB**，默认 `0`（不限制）。显式设成 128 会把所有大于 128 KB 的 PUT 直接拒掉，
64 MB 写测试本身就会失败。因此没有可"调优"的余地，**按不设处理**，不写入配置。

### V8 网卡 TSO/GSO：无法测量

设备没有 `ethtool`，内核 2.6.36 也没有 `/sys/class/net/*/features`，既不能查询也不能切换
TSO/GSO。该变量记为**不可测**，没有据此做任何改动。

### V9 `server.max-worker = 2`：不做

单流受 Wi-Fi 限制（9–16 MB/s），而 4 路并发 GET 已经能把聚合推到 37.1 MB/s，
说明现有单 worker 的 `epoll` 并未成为并发瓶颈。改成 2 个 worker 会让每 worker 各持一份
缓冲区与状态，在这台 254 MB 的机器上属于"为不存在的瓶颈付内存"，不做。

## 瓶颈在哪：设备 loopback 与并发上限

在设备本地对同一文件做请求（绕开 Wi-Fi）：

| 场景 | 结果 |
|---|---|
| 单流 PUT 64 MB | 29.9 MB/s（2.24 s） |
| 单流 GET 64 MB | 35 MB/s（1.91 s） |
| 同一文件二次 GET（页缓存命中） | 92 MB/s |
| 4 路并发 GET，各自 | ~10 MB/s |
| 4 路并发 GET，聚合 | 37.1 MB/s（wall 6.89 s） |
| Mac 经 Wi-Fi 单流再次复测 | 13.1 MB/s |

服务端在 loopback 上能跑 30–35 MB/s、聚合 37 MB/s，而 Wi-Fi 单流只有 9–16 MB/s。
**差距在无线链路与客户端，不在 lighttpd 的 I/O 路径。** 这也是 V1–V6 全部无收益的统一解释，
而不是六个变量各自"恰好无效"。

## 客户端侧对照（同一批 200 个 4 KB 文件）

| 客户端 | 耗时 | 吞吐 |
|---|---|---|
| Python `http.client`，单连接 keep-alive | 0.99 s | 202 个/s |
| `curl` 每个文件一个进程 | 5.80 s | 34 个/s |
| `curl` 经 `xargs -P 8` 并发 | 2.39 s | 84 个/s |
| SMB（`2026-11-11-usb-first-access` 同口径） | 26.1 s | 7.6 个/s |

结论：同一份服务端，客户端实现方式的差异（0.99 s vs 5.80 s）**远大于**任何服务端变量
（全部在 ±10% 噪声内）。要提速小文件，优先换客户端/加并发，而不是调 lighttpd。

## 落仓库的方式

- **配置不变**：`recipes/webdav/lighttpd.conf` 保持 B0 原样，不引入任何新指令。
  设备上 `conf/lighttpd.conf` 与 `conf/lighttpd.conf.bak-b0` 经 `diff` 确认一致。
- **文档记录**：在 [`recipes/webdav/README.md`](../../../recipes/webdav/README.md) 增加
  「调优实测」一节，写明六个变量均无收益、瓶颈是 Wi-Fi，以及"不要引入 mod_deflate /
  inotify stat cache / 更大连接数"的理由，避免以后重复试错。
- **证据**：本目录 `plan.md` + 本文件；索引在 [`docs/evidence/README.md`](../README.md)。
- **回滚路径**：设备上删除 `conf/lighttpd.conf.bak-b0` 即可回到"无任何调优痕迹"的状态；
  该备份只是 B0 的副本，不影响运行。

## 限制

- 客户端只有一台 Mac + Wi-Fi，没有有线对照；若日后接千兆有线，单流上限可能抬高，
  届时 `linux-sendfile` 等零拷贝选项才可能有可测收益，需重新实验。
- 每组 3 轮取中位数，能分辨 ≥ 10% 的差异；更小的差异（例如 2–3%）落在噪声内，
  未做更大样本的统计检验。
- V8（TSO/GSO）完全不可测；V7 与 V9 按"不设/不做"处理并给了理由，没有产生实测数字。
