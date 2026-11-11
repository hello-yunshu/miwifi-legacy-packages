# 外接盘首访问延迟：诊断与 SMB/WebDAV 对比（2026-11-11）

- 设备：`root@192.168.3.2`（R2D，固件 2.25.209，Linux 2.6.36，254 MB RAM / 2 核）
- 客户端：macOS，Wi-Fi，同一网段；`curl 7.x`、`python3 http.client`
- 服务：lighttpd 1.4.85 `192.168.3.2:5005`（WebDAV），Samba 4.25.1 `139/445`（`XiaoMi` = `/userdisk/data`，`XiaoMi-usb0` = `/extdisks/sdb1`）
- 全部命令只读；写操作只在 `__bench-*` / `__bench-smb` 临时目录，测完删除

## 一、结论

1. **外接盘本身不慢，也不会休眠。** 空闲 900 秒后第一次读它（未缓存的 4 KB 块、全新偏移）是 **20 ms**，与紧接着的第二次一致；`/sys/block/sdb/device/state` 始终 `running`，`rotational=1`，没有 USB autosuspend 节点，`dmesg` 自开机起没有任何 USB 重新枚举或超时。所以「让盘不休眠」「开 stat 缓存」这类改动没有依据，本次**没有**加常驻保活。
2. **系统空闲时，两个根的首访问和后续访问都是 7–12 ms，二者无差别。**
3. **真正能把首访问拖到 100–700 ms 的是这台机器的资源争抢**，实测到两次，且都能在移除干扰后立刻恢复：
   - 设备上残留的自检进程：一个 `sh /tmp/webdav-stageA2.sh` 长期占 94% CPU（262 分钟 CPU 时间）+ 两个 `grep -rn` 卡在 `D` 状态扫数据盘与外接盘，`load average` 4.15。此时 `HEAD /外接盘/` 169–179 ms、偶发 391/716 ms，裸读 140–250 ms；杀掉后 `load` 0.09，同样请求 7–12 ms，裸读 10–20 ms。
   - Mac 侧把 SMB 共享挂到 Finder 后，Spotlight 的 `mdworker_shared` 立刻开始索引这块盘：设备侧 `smbd` 持有 100+ 个 `/extdisks/sdb1/工作备份/...` 文件句柄、常驻 145 MB、处于 `D` 状态，swap 用到 108 MB，`load` 3.0–3.5。此时 WebDAV 的「间隔 3 秒后的第一条」请求 100–400 ms。改成 `mount_smbfs -o nobrowse` 后 `smbd` 只有 4 个句柄、`S` 状态、`load` 0.13，同样请求 9–14 ms。
4. **只剩一个一次性成本**：系统长时间无请求后的第一条可达 ~280 ms（lighttpd/内核代码与数据换入），之后稳定 8–12 ms。这条与 USB 无关，两个根都会出现。

## 二、冷/热端到端计时

客户端 `curl -w '%{http_code} dns=%{time_namelookup} conn=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}'`，每个根依次 `OPTIONS` → `HEAD` → `PROPFIND Depth 0` → `Depth 1` → `GET 目录页`。

### 2.1 热态（连续请求）

```
## hot /本机储存/ 02:55:14
OPTIONS     200 conn=0.006149 ttfb=0.009252 total=0.009258
HEAD        200 conn=0.004432 ttfb=0.008700 total=0.008807
PROPFIND d0 207 conn=0.003755 ttfb=0.006685 total=0.006732
PROPFIND d1 207 conn=0.003631 ttfb=0.007467 total=0.007521
GET dirlist 200 conn=0.003614 ttfb=0.007467 total=0.007509
## hot /外接盘/ 02:55:14
OPTIONS     200 conn=0.004071 ttfb=0.007079 total=0.007085
HEAD        200 conn=0.003751 ttfb=0.007569 total=0.007675
PROPFIND d0 207 conn=0.003776 ttfb=0.008865 total=0.008905
PROPFIND d1 207 conn=0.003729 ttfb=0.008359 total=0.011126
GET dirlist 200 conn=0.003869 ttfb=0.008065 total=0.008118
```

### 2.2 空闲 120 秒后的第一条

```
## cold120 /外接盘/ 02:57:19
OPTIONS     200 conn=0.006354 ttfb=0.010119
HEAD        200 conn=0.003801 ttfb=0.007766
PROPFIND d0 207 conn=0.004150 ttfb=0.007484
PROPFIND d1 207 conn=0.004849 ttfb=0.009630
GET dirlist 200 conn=0.003762 ttfb=0.007541
## cold120 /本机储存/ 02:59:19
OPTIONS     200 conn=0.003720 ttfb=0.007487
HEAD        200 conn=0.005540 ttfb=0.010241
PROPFIND d0 207 conn=0.004452 ttfb=0.008368
PROPFIND d1 207 conn=0.005572 ttfb=0.009900
GET dirlist 200 conn=0.003816 ttfb=0.009947
```

结论：空闲不会让外接盘变慢；`conn` 稳定 3.5–6 ms（Wi-Fi RTT ≈3 ms），没有建连惩罚。

### 2.3 设备本地（排除网络）

在设备上 `curl http://192.168.3.2:5005`（目标地址是 `local 192.168.3.2 dev lo`，不经过网卡）：

```
== 1st HEAD after 5s idle x5, usb ==
  usb   conn=0.034 ttfb=0.336
  usb   conn=0.001 ttfb=0.157
  usb   conn=0.056 ttfb=0.210
  usb   conn=0.001 ttfb=0.415
  usb   conn=0.026 ttfb=0.347
== back-to-back x5 ==
  usb   conn=0.007 ttfb=0.008
  usb   conn=0.003 ttfb=0.005
  usb   conn=0.001 ttfb=0.002
```

这一段是在干扰仍在时采的，正好证明延迟发生在设备内部而不是链路：`conn` 与 `ttfb` 同时变慢，退化成 `select()`/调度与内存换页，不是磁盘。

### 2.4 空闲 900 秒后的裸读（无保活）

```
start 02:59:35
after 900s idle 03:14:35
state: running
raw 4K fresh offset : 20 ms
raw 4K fresh offset2: 20 ms
stat usb root       : 0 ms
ls -l usb root      : 0 ms
stat usb subdir     : 10 ms
```

同一时期按 0/15/30/60/120/300 秒梯度探测全新偏移，结果均为 10–20 ms：

```
idle=0s 20 ms | 15s 10 ms | 30s 20 ms | 60s 20 ms | 120s 0 ms | 300s 20 ms
```

## 三、磁盘与挂载取证

```
/dev/sdb1 /extdisks/sdb1 tntfs rw,noatime,uid=0,gid=0,umask=00,nls=utf8,
  min_prealloc_size=64k,max_prealloc_size=976727036,readahead=1M,
  user_xattr,case_sensitive,fail_safe,hidden=show,dotfile=show,
  errors=continue,mft_zone_multiplier=1
rotational=1   state=running   scheduler=cfq   read_ahead_kb=1024
```

- `dmesg` 里只有开机那次：`sd 2:0:0:0: [sdb] Spinning up disk...`（耗时 3 s），之后到 `tntfs` 挂载（开机 93 s）再没有任何 USB/scsi 事件。
- 目录规模很小，不存在 stat 风暴：外接盘根 **11–13 项**，最大子目录 `备份 杂` 18 项。
- `hdparm -C/-S` 在这块 USB 桥（WD Elements 25A2）上不可用（`SG_IO: bad/missing sense data`），因此判断「是否停转」只依赖裸读延迟与 `device/state`，不用 hdparm 的结论。
- `/sys/bus/usb/devices/1-2/` 下没有 `power/` 目录（2.6.36 内核对这个设备没有 runtime PM 节点），不存在 USB 自动挂起。

## 四、lighttpd 侧

- 配置里没有 `server.stat-cache-engine`，即 1.4 的默认 `simple`（1 秒内复用 stat 结果）。实测设备侧一次 `stat` 0 ms、`ls -l` 10–20 ms，且根目录只有十几项，缓存不是瓶颈。
- 判定「不在文件系统、不在 dir-listing、不在 webdav」的关键实验：干扰期间**不带任何文件系统操作**的 `OPTIONS /` 同样 119–487 ms，静态别名资源 `/__ui/app.css` 同样 147–376 ms，而 `PROPFIND Depth 1` 在系统安静时只要 7–12 ms。这说明慢的是连接与调度，不是某一个模块。
- 根路径的 `GET /` 由静态单页承接，`dir-listing` 只服务深层目录，没有对「外接盘」做深度遍历。

## 五、干扰源与前后对比

### 5.1 残留自检进程

| | 处置前 | 处置后 |
|---|---|---|
| `load average`（1 分钟） | 4.15 | 0.09 |
| 异常进程 | `sh /tmp/webdav-stageA2.sh` 94% CPU / 262 min；两个 `grep -rn` 处于 `D` | 无 |
| `HEAD /外接盘/` | 169–179 ms，偶发 391 / 716 ms | 7–12 ms |
| 裸读 `/dev/sdb` 4 KB | 140–250 ms | 10–20 ms |

### 5.2 Mac 挂 SMB 后 Spotlight 索引

| | 默认 `mount_smbfs` | `-o nobrowse` |
|---|---|---|
| 设备侧 `smbd` | 100+ 个 `/extdisks/sdb1/工作备份/...` 句柄，RES 145 MB，`D` 状态 | 4 个句柄，`S` 状态 |
| `load average` | 3.0–3.5 | 0.13 |
| swap 使用 | 108 MB | 0 |
| `HEAD /外接盘/`（间隔 3 秒） | 100–400 ms | 9–14 ms |

`mdworker_shared` 在挂载的同一分钟启动，卸载后 `smbd` 退出、`MemFree` 从 18 MB 回到 159 MB、swap 从 108 MB 回到 0。这是「用 Finder 打开过外接盘之后，WebDAV 也跟着变慢」的机制：254 MB 内存的机器被 `smbd` 的索引扫描拖进换页。

## 六、处置

1. 杀掉设备上残留的自检进程与保活循环（`/tmp/webdav-stageA2.sh`、两个 `grep -rn`、`while :; do dd if=/dev/sdb ...`），删除临时夹具目录与测试用的 bind mount。
2. **不改 lighttpd、不加常驻保活**：数据不支持。盘不休眠，保活只会增加无谓的读写与磨损。
3. Mac 侧建议：挂 SMB 时用 `-o nobrowse`（或在「聚焦 → 隐私」里排除该卷），避免 Spotlight 索引路由器上的盘。用 WebDAV 浏览不受此影响。
4. 遗留的一次性冷启动（~280 ms）不做处理：它只出现在长时间无请求后的第一条，属于代码/数据换入。

## 七、SMB 与 WebDAV 实测对比

环境：Mac Wi-Fi；两端写同一块盘、同一批文件（`本机储存` = ext4 `/dev/sda1`，`外接盘` = tNFS `/dev/sdb1`）；WebDAV 用单连接 + keep-alive，SMB 用 `mount_smbfs`（guest）。

### 7.1 本机储存（ext4）

| 项目 | WebDAV | SMB |
|---|---|---|
| 64 MB 写 | 14.9 / 16.3 MB/s | 24.3 / 38.8 MB/s |
| 64 MB 读 | 9.3 / 9.5 MB/s | 12.2 / 25.3 MB/s |
| 200 × 4 KB 写 | 0.99 s / 1.07 s（187–202 个/s） | 26.10 s / 26.65 s（7.5–7.7 个/s） |
| 200 × 4 KB 读 | 0.83 s / 0.84 s（238 个/s） | 6.82 s / 6.87 s（29 个/s） |
| 200 项目录列举 | `PROPFIND Depth 1` 0.035 s | `ls -l` 1.16 / 1.21 s |
| 单文件元数据 | — | 建空文件 47 ms/个，`stat` 13 ms/个 |

### 7.2 外接盘（tntfs）

| 项目 | WebDAV | SMB |
|---|---|---|
| 32 MB 写 | 9.4 MB/s | 15.3 / 5.1 MB/s |
| 32 MB 读 | 10.2 MB/s | 20.1 / 4.4 MB/s |
| 100 × 4 KB 写 | 1.57 s（63.8 个/s） | 9.38 s / 38.74 s（10.7 / 2.6 个/s） |
| 100 × 4 KB 读 | 0.43 s（233 个/s） | 3.86 s / 14.81 s |
| 100 项目录列举 | `PROPFIND Depth 1` 0.014 s | `ls -l` 0.52 / 2.25 s |

SMB 在这块盘上的方差明显更大（`smbd` 的同步写与 NTFS 分配叠加，FTP 侧同样的数据当前也受索引影响），所以取两次实测的区间，不取单次最大值。

### 7.3 结论

- **局域网日常读写**：大文件走 SMB 更快（本机盘写 24–39 vs 15–16 MB/s，读 12–25 vs 9.4 MB/s），Finder 集成也更好；但**大量小文件必须避开 SMB**——200 个 4 KB 文件 SMB 26 s、WebDAV 1 s，差 25 倍，原因是 SMB 每个文件都要建、写、关、带 xattr 多轮往返（建空文件 47 ms、`stat` 13 ms），而 WebDAV 一个 keep-alive 连接里每文件一个请求。
- **手机与浏览器**：只能选 WebDAV。浏览器和 iOS/Android 文件管理器都不挂 SMB；`http://192.168.3.2:5005/` 直接可看可下，中文界面与深层目录都能用。
- **大文件**：SMB 更快；WebDAV 受 lighttpd 单线程与无 TLS 影响，稳定在 9–16 MB/s。
- **大量小文件**：WebDAV 完胜。WebDAV 逐文件一个请求，SMB 每个文件十几次往返，在 3–5 ms RTT 的 Wi-Fi 上被放大成每文件 ~130 ms。
- **大目录列举**：WebDAV 的 `PROPFIND Depth 1` 是一次批量响应（200 项 35 ms），SMB 的 `ls -l` 要逐项 stat（200 项 1.2 s），差 30 倍以上。
- **断线重连**：SMB 是挂载，Wi-Fi 切换/休眠唤醒后常要重挂，句柄失效；WebDAV 只是 HTTP，浏览器/客户端重连即可，`Finder ⌘K` 失败后重试代价也小。
- **跨网访问**：SMB 的 139/445 在多数网络与移动网络被封，且枚举依赖 NetBIOS/广播；WebDAV 是单端口 HTTP，过 NAT/反代更容易。但本机 WebDAV **没有 TLS**，只应在内网或经 VPN 使用，不要直接映射到公网。

## 八、复现命令

```sh
# 客户端分段计时（两个根各一轮）
B=http://192.168.3.2:5005; U=<user>; P=<pass>
BODY='<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>'
FMT='%{http_code} dns=%{time_namelookup} conn=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n'
curl -s -o /dev/null -u "$U:$P" -X OPTIONS -w "OPTIONS $FMT" "$B/外接盘/"
curl -s -o /dev/null -u "$U:$P" -I -w "HEAD $FMT" "$B/外接盘/"
curl -s -o /dev/null -u "$U:$P" -X PROPFIND -H 'Depth: 1' -H 'Content-Type: application/xml' \
     --data-binary "$BODY" -w "PF1 $FMT" "$B/外接盘/"

# 设备侧：未缓存块读（全新偏移），空闲 900 秒后再测
nowms() { awk '{printf "%.0f", $1*1000}' /proc/uptime; }
s=$(nowms); dd if=/dev/sdb of=/dev/null bs=4096 count=1 skip=800021 2>/dev/null; e=$(nowms)
echo $((e-s)) ms

# 检查是否有东西在扫盘
for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null); case "$c" in *sdb*|*extdisks*) echo "${p#/proc/}: $c";; esac; done
cat /proc/loadavg
```

## 九、未验证 / 限制

- 只测了 macOS 客户端；Windows 的 SMB 客户端与 `robocopy` 小文件表现未测。
- SMB 的两次大文件读数差异较大（12–39 MB/s），受 Wi-Fi 与 `smbd` 同步写影响，未做长时间多轮取中位数。
- Spotlight 只在「首次挂载该卷」时观察到完整索引；`nobrowse` 对比是在索引已完成之后做的，因此表格里的 100–400 ms 是索引进行中的实测，不是每次挂载都能重现。
- 没有做断电/重启后的整机冷启动首访问测试（会中断服务），只做了 900 秒空闲与 `drop_caches` 两种冷态。
