# WebDAV 调优：受控对照实验计划（2026-11-11）

目标：在 R2D（254 MB RAM / 2 核 / lighttpd 1.4.85）上，用「一次只改一个变量」的对照实验决定
哪些配置值得保留。每组测完先回滚到基线，再测下一组。

## 基线 B0（2026-11-11 03:20–03:40，系统安静）

设备：`load 0.04`、`MemFree 142 MB`、`SwapFree 239 MB`、lighttpd RSS 0.3–1.0 MB，
无 `mdworker` 索引、无残留脚本、无 SMB 挂载。

| 指标 | 基线值（两次实测） |
|---|---|
| 64 MB 顺序写 | 14.9 / 16.3 MB/s |
| 64 MB 顺序读 | 9.3 / 9.5 MB/s |
| 200 × 4 KB 写 | 0.99 s / 1.07 s（187–202 个/s） |
| 200 × 4 KB 读 | 0.83 s / 0.84 s（约 238 个/s） |
| 200 项 PROPFIND Depth 1 | 0.035 s |

## 构建能力（实测）

- `lighttpd -V`：`+ linux-sendfile`、`+ writev`、`+ write`、`+ mmap support`；事件 `poll` / `epoll`
- 支持 `server.stat-cache-engine`：`disable` / `simple` / `inotify`
- 支持 `server.stream-request-body`、`server.stream-response-body`、`server.upload-temp-file-size`
- 设备**没有 `ethtool`**，内核 2.6.36 也没有 `/sys/class/net/*/features`，TSO/GSO 无法切换与验证

## 变量矩阵（按执行顺序）

| 编号 | 变量 | 改动 | 预期受益指标 | 内存风险 |
|---|---|---|---|---|
| V1 | `server.stream-request-body` | `0`（默认）→ `2` | 64 MB 写、200 小文件写（避免先写 `state/tmp` 再拷贝） | 低（流式，不落临时文件） |
| V2 | `server.stream-response-body` | `0` → `1` | 64 MB 读、大文件读延迟 | 低 |
| V3 | `server.network-backend` | `writev` → `linux-sendfile` | 64 MB 读（零拷贝） | 低 |
| V4 | `server.stat-cache-engine` | `simple` → `inotify`（若不可用则试 `disable`） | 200 项 PROPFIND、小文件读写 | 低 |
| V5 | `mod_deflate` | 新增，仅 `text/*`、`application/xml`，最小 1 KB | PROPFIND 响应体积/耗时 | 中（压缩吃 CPU） |
| V6 | `server.max-connections` | 默认 → `64` | 常驻内存 | 低 |
| V7 | `server.max-request-size` | 默认 → 显式值 | 大 PUT 上限与缓冲 | 中 |
| V8 | 网卡 TSO/GSO | 无 `ethtool`，不可切换 | — | — |
| V9（可选） | `server.max-worker` | `1` → `2` | 并发读（两路同时 GET） | 中（每 worker 独立内存） |

执行顺序：V1 → V2 → V3 → V4 → V5 → V6 → V7；V9 只在 V1–V3 之后仍有明显并发瓶颈时再做。

## 每组流程

1. `cp conf/lighttpd.conf conf/lighttpd.conf.bak-b0`（仅第一次），之后每组都从 `bak-b0` 复制
2. 只追加一组改动，`lighttpd -f ... -t` 校验
3. `run.sh restart`（约 1–2 秒不可用）
4. 预热 2 个请求，再跑 3 轮指标（取中位数）
5. 记录 `load average`、`MemFree`、`SwapFree`、lighttpd RSS、`state/tmp` 大小
6. 恢复 `bak-b0` 并 `restart`，确认回到基线数字后再进入下一组

## 判定规则

保留需同时满足：

- 目标指标中位数改善 ≥ 10%
- 其他指标不回退 > 5%
- `MemFree` 全程 > 80 MB，`SwapFree` 不下降超过 5 MB，无 OOM 记录
- 功能不变：两个根可读、`PROPFIND 207`、`PUT/GET/DELETE` 正常、`外接盘` 根仍只读

否则回滚并记录原因。

## 客户端侧对照

设备上无 `rclone`/`aria2`，用三种客户端取同一组文件，区分服务端与客户端开销：

- Python `http.client` 单连接 keep-alive（当前基准，最接近服务端能力）
- `curl` 每文件一个进程（模拟脚本/低效客户端）
- `curl --parallel 8`（并发，检验服务端连接处理）

## 产物

- 逐变量前后对照表 + 保留/放弃理由
- 最终配置落回仓库 `recipes/webdav/lighttpd.conf`，README 增补「调优」一节
- 原始输出与结论写入本目录 `README.md`
- 全程不改 Samba 配置；不放常驻保活；测试夹具只在 `__bench-*` 临时目录，测完删除
