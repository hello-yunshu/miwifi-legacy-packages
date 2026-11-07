# S2 隔离回归（在设备上跑新实例，不碰原厂）

状态：隔离构建、本地冒烟、实机一次性验证均已完成；实机验证后已按回滚步骤删除运行根并核对原厂状态（见第 5、6 节）。未覆盖项列在第 7 节，未提升为通过。

约束回顾：

- 运行根放在 `/userdisk` 或外挂盘；根分区只读，`lock/state/cache/private` 全部落在新根下。
- 不替换 `/usr/sbin/samba_multicall`，不改 `/etc/config/samba`，不停止/重启原厂 `smbd`/`nmbd`。
- 新实例使用独立配置与独立端口，避开原厂占用的 139/445/137/138。
- 任何一步失败都能把 `/userdisk` 上的新根完整删除，设备回到测试前状态。

## 1. 测试前原厂基线（只读采集，2026-11-07 23:53 CST）

采集方式：只读 SSH 命令（`ps`/`netstat`/`df`/`mount`/`cat`/`md5sum`），未写入任何路径。

### 1.1 系统

```
Linux XiaoQiang 2.6.36 #3 MiWiFi-R2D-2.25.209 SMP PREEMPT Tue Oct 16 11:45:02 UTC 2018 armv7l GNU/Linux
up 3 days, 17:33, load average: 0.03, 0.03, 0.04
```

### 1.2 原厂进程

```
 2117 root      7620 S    /usr/sbin/smbd -D
 7577 root      7920 S    /usr/sbin/smbd -D
 8469 root      5760 S    /usr/sbin/nmbd -D
 8471 root      7172 S    /usr/sbin/smbd -D
22286 root      7256 S    /usr/sbin/smbd -D
```

与 S0 采集相比多了一个 `22286`（S0 记录为 2117/7577/8471/18624）。原厂 `smbd` 会按连接派生/回收子进程，PID 集合本身不稳定；回滚核对采用“进程数与监听归属”而不是固定 PID 清单。

### 1.3 端口占用

```
tcp  192.168.3.2:139  LISTEN  8471/smbd
tcp  192.168.3.2:445  LISTEN  8471/smbd
udp  192.168.3.255:137        8469/nmbd
udp  192.168.3.2:137          8469/nmbd
udp  0.0.0.0:137              8469/nmbd
udp  192.168.3.255:138        8469/nmbd
udp  192.168.3.2:138          8469/nmbd
udp  0.0.0.0:138              8469/nmbd
```

139/445 只监听 `192.168.3.2`（br-lan），137/138 同时在 `0.0.0.0` 与 br-lan 广播地址上。新实例避让 139/445/137/138。

### 1.4 文件系统与空间

```
rootfs       107.9M  87.7M  20.1M  81%  /            (ubifs, ro)
/dev/ubi2_0  204.1M  61.9M 137.4M  31%  /data        (ubifs, rw)  -> 同时挂在 /userdisk、/etc
/dev/sda1    931.2G 484.8G 446.5G  52%  /userdisk/data (ext4, rw)
```

`/opt` 存在但只读：

```
$ touch /opt/.wtest
touch: /opt/.wtest: Read-only file system
```

结论：S1 产物的 `RPATH=/opt/samba-next/lib` 与 `MODULESDIR=/opt/samba-next/lib/samba` 在设备上无法成立，必须改前缀重建（见 decisions D-S2-02）。

### 1.5 原厂 Samba 二进制与配置

```
-rwxr-xr-x 1 root root 4325084 Oct 16 2018 /usr/sbin/samba_multicall
MD5: 5e422d3463f40b4405ef8325ce3603e8
/usr/lib/samba: 不存在（原厂为单体多调用二进制，模块内建）
/etc/config/samba: 名称 XiaoMi_8041，WORKGROUP，homes=1
  共享: XiaoMi(/userdisk/data), XiaoMi-usb0(/extdisks/sdb1), 下载/共享/图片/文档,
        摄像机监控视频$(/userdisk/data/摄像机监控视频/%U, preexec mkdir -p)
  全部 guest_ok=yes / force_user=root / 0777 或 0666
```

原厂未使用 UCI 之外的 `/etc/samba/smb.conf`，也没有 `/var/lib/samba`、`/var/cache/samba`（原厂 TDB 在 `/var/state` 与 `/var/lock` 下，回滚核对时用时间戳比对，不动其内容）。

## 2. 回滚步骤（任何阶段失败都执行）

新根固定为 `/userdisk/data/samba-s2`，除此之外设备上不落任何文件。

1. 停止新实例（只杀新根下记录的 PID，模式匹配限定为 `/userdisk/data/samba-s2/`）：
   ```sh
   for p in $(cat /userdisk/data/samba-s2/run/smbd.pid 2>/dev/null); do kill $p; done
   ps w | grep '/userdisk/data/samba-s2' | grep -v grep
   ```
2. 删除新根：
   ```sh
   rm -rf /userdisk/data/samba-s2
   ```
3. 核对原厂状态未变：
   ```sh
   ps w | grep -E 'samba_multicall|/usr/sbin/smbd|/usr/sbin/nmbd' | grep -v grep
   netstat -ltnp | grep -E ':139|:445'      # 仍应只有原厂 smbd
   netstat -lunp | grep -E ':137|:138'      # 仍应只有原厂 nmbd
   md5sum /usr/sbin/samba_multicall          # 5e422d3463f40b4405ef8325ce3603e8
   df -h /                                   # 仍为 81%，ro
   ```
4. 若第 3 步任一项不符，说明新实例越界，立即 `kill` 全部 `/userdisk/data/samba-s2` 相关进程并重新核对；原厂二进制与配置本次不会被动到（不写 `/`、不写 `/etc/config/samba`），因此不需要恢复动作。

## 3. 部署布局

| 项 | 路径 |
| --- | --- |
| 安装前缀 | `/userdisk/data/samba-s2/root`（`sbin/smbd`、`lib/`、`lib/private/`、`lib/samba/` 模块） |
| 配置文件 | `/userdisk/data/samba-s2/root/etc/smb.conf`（编译期 `CONFIGFILE`，即默认读取路径） |
| lock | `/userdisk/data/samba-s2/root/var/lock` |
| state | `/userdisk/data/samba-s2/root/var/locks` |
| cache | `/userdisk/data/samba-s2/root/var/cache` |
| private | `/userdisk/data/samba-s2/root/var/private` |
| 日志 | `/userdisk/data/samba-s2/root/var/log`（`-l` 指定，默认 `LOGFILEBASE` 是 `var/`） |
| ncalrpc 管道目录 | `/userdisk/data/samba-s2/root/var/run/ncalrpc`（编译期默认位置，必须预先存在） |
| 端口 | TCP 1445（仅 `192.168.3.2`），不启 nmbd |

部署前必须预建 `var/lock`、`var/locks`、`var/cache`、`var/private`、`var/log`、`var/run/ncalrpc`。目录缺失时 smbd 启动会直接失败（`Failed to create pipe directory ... - No such file or directory`），不是可忽略告警。详见 D-S2-10。

## 4. 结果

### 4.1 隔离重建（决策 D-S2-02）

以设备路径为前缀重新做一次干净构建，源码 tar 散列、5 个补丁与 configure 选项均与 S1 相同，只改 `--prefix`/`--libdir` 与 `-rpath`。

| 阶段 | 结果 |
| --- | --- |
| configure | `rc=0`，3m26s |
| build | `rc=0`，5m40s，3456 个任务 |
| install | `rc=0`，3m36s，`DESTDIR` 安装树 41 MiB（53 个公共 `.so` + 125 个私有库 + 模块） |

首次 configure 真实失败与处置：

```text
FileNotFoundError: [Errno 2] No such file or directory:
  '/work/s2/samba-4.25.1/bin/c4che/build.config.py'
```

根因是全新解压树没有 waf 输出目录，`configure` 在 store 阶段写入 `bin/c4che` 时不会自建该目录；`mkdir -p bin/c4che` 后同一参数 `rc=0`。处置与理由见 D-S2-07。

关键散列（SHA-256）：

| 文件 | SHA-256 |
| --- | --- |
| `sbin/smbd` | `2580dac4f5af06cc4089bfe696dd08f7659a7f824facb61c4ed97768d18a5e6d` |
| `sbin/nmbd` | `fed9fd102260df44eeeb38312058a99414bd19e0196e9852588c75e733eabf9e` |
| `bin/testparm` | `33b4e70e7b2de0fbd39f88c0c3776f1a0de60ffff67d768f65eaf2eba54fbe8a` |
| `bin/smbclient` | `35b4312befccd71612800c1463e3a3f69ac31eb6ae63b10e4b65a5a5aa0df615` |

4 个主程序 `RPATH` 均为 `/userdisk/data/samba-s2/root/lib`（与 S1 的 `/opt/samba-next/lib` 不同，符合重建目的）。编译期路径：

```text
SBINDIR     /userdisk/data/samba-s2/root/sbin
LIBDIR      /userdisk/data/samba-s2/root/lib
MODULESDIR  /userdisk/data/samba-s2/root/lib
CONFIGFILE  /userdisk/data/samba-s2/root/etc/smb.conf
LOCKDIR     /userdisk/data/samba-s2/root/var/lock
STATEDIR    /userdisk/data/samba-s2/root/var/locks
CACHEDIR    /userdisk/data/samba-s2/root/var/cache
PIDDIR      /userdisk/data/samba-s2/root/var/run
```

随包第三方库沿用 S1 产物（散列一致）：`libgnutls.so.30.42.0` `c7e3630c…`、`libnettle.so.8.11` `f1ff96b5…`、`libhogweed.so.6.11` `c9e4e550…`、`libgmp.so.10.5.0` `2f43ab02…`。

### 4.2 本地运行回归（QEMU + 设备 libc sysroot，非实机结论）

运行方式与决策见 D-S2-08：`qemu-arm-static -L <SDK sysroot>`，前缀是设备路径，因此在容器内用 `/userdisk -> /work/prefix-s2/userdisk` 的临时符号链接补齐编译期绝对路径；该链接只用于本机验证，设备上 `/userdisk` 本身存在。

| 用例 | 结果 |
| --- | --- |
| `smbd --version` | `Version 4.25.1` |
| `testparm -s <prefix>/etc/smb.conf` | `Loaded services file OK.`，`Server role: ROLE_STANDALONE`，`rc=0` |
| 监听 | 仅 `127.0.0.1:1445` LISTEN，无 139/445 绑定 |
| 访客访问可写共享（`guest ok=yes`） | `ls` 成功；`get marker.txt` 20 字节 |
| 文件完整性 | 下载副本与源文件 MD5 均为 `9dae41acfcf9e885a243a587fc8f5908` |
| 访客访问拒绝共享（`guest ok=no`） | `tree connect failed: NT_STATUS_ACCESS_DENIED` |
| 只读共享写入 | `NT_STATUS_ACCESS_DENIED opening remote file \up2.txt` |
| 可写共享写入 | `put up.txt` 落盘 3 字节，重新 `ls` 可见 |
| 写回读校验 | 上传与取回副本 MD5 均为 `67839e1bba5029447aa47d2e4b280b37` |
| 并发 | 4 个并行 `get` 全部 `rc=0`，4 份副本散列唯一值为 1 |
| 协议协商 | SMB3 `rc=0`、SMB2 `rc=0`；SMB1（客户端下限临时降到 NT1）`rc=0` |

运行期观察到的两条告警：

1. `db_open_ex: mutexes requested but not available` 在启动与每次连接时重复出现在 level 0。原因是 uClibc/GCC 4.8 组合下 TDB 的 robust mutex 能力未被启用，回落到 fcntl 锁。功能未失败，但会污染日志并在高并发下有语义差异，列为 S2 未关闭风险（D-S2-11），需在实机并发用例中复核。
2. `cache '/etc/ld.so.cache' is corrupt` 是 QEMU `-L` sysroot 下动态加载器的宿主侧噪声，与产物无关；设备上不会出现。

### 4.3 未验证项（不提升为通过）

| 项 | 原因 |
| --- | --- |
| 设备侧部署 `/userdisk/data/samba-s2` | 已完成一次性实机验证，验证后运行根已删除（见第 5 节） |
| macOS Finder 挂载、中文文件名、重连、安全弹出 | 需真机客户端，本轮未做 |
| Emby 目录/存在检查/拖动/完整播放 | 需设备侧实例与真机客户端 |
| 强制签名、强制加密与拒绝策略 | 本轮配置沿用原厂 `smb encrypt = no`，未做强制策略用例 |
| SMB1 是否保留的产品结论 | 仅证明服务端仍能接受 SMB1，未做客户端矩阵，见 D-S2-09 |
| 内核 2.6.36 下的锁、线程、sendfile、inotify | QEMU 使用宿主内核，属 S6 |
| 长稳、CPU/内存、I/O、日志增长 | 未开始 |

## 5. 设备侧实机验证（已完成，现场已清理）

### 5.1 部署

| 项 | 值 |
| --- | --- |
| 运行根 | `/userdisk/data/samba-s2`（安装树 `root/` 40.6 MiB，配置 `etc/smb.conf`，运行目录 `var/{lock,state,cache,private,log}`、`run/`） |
| 分发包 | `samba-s2-root.tar.gz` 14,396,362 B，SHA-256 `0e2dc5b6a5291b9a12afb29349cbe908de043a6f61fc20f69bcc6cd100624ab1` |
| 传输校验 | 设备侧 MD5 `e71870432fb302ca75f368bfa9c2bed6`，与宿主一致；解包后 4 个主程序 MD5 与构建机逐一相同 |
| 启动方式 | `nohup ./run-smbd.sh &`，脚本内 `LD_LIBRARY_PATH=<root>/lib:<root>/lib/private`，`smbd -F -s etc/smb.conf` |
| 监听 | `192.168.3.2:1445`（PID 10406，另起 `smbd-notifyd`/`smbd-cleanupd`） |
| 原厂并存 | 139/445 仍由原厂 8471 持有，137/138 仍由原厂 8469 持有，未被抢占 |

`LD_LIBRARY_PATH` 必须同时包含 `lib` 与 `lib/private`，实测缺一不可：

```text
仅默认：       can't load library 'libsecrets3-private-samba.so'
仅加 lib/private：can't load library 'libhogweed.so.6'
两者都加：      testparm 正常
```

说明 uClibc 0.9.33.2 不会用主程序 `DT_RPATH` 去解析“依赖库的依赖”，因此部署脚本固定导出这两个目录（D-S2-12）。

### 5.2 设备原生 libc 结论（对应约束 5）

`/proc/10406/maps` 中来自系统目录的只有 6 个文件，其余 211 条映射全部指向新根：

```text
/lib/ld-uClibc-0.9.33.2.so
/lib/libuClibc-0.9.33.2.so      <- MD5 e2164dfc067f356af2dec37acf36e9e6（设备定制版）
/lib/libpthread-0.9.33.2.so
/lib/libdl-0.9.33.2.so
/lib/libcrypt-0.9.33.2.so
/lib/libubacktrace-0.9.33.2.so
```

SDK sysroot 里的同版本 libc 是 `0c15e93496faa913c695ee9e09e0e384`，与设备上的 `e2164dfc…` 不同；实机运行使用的是设备自带那份。在“符号与会话层”“文件语义层”都跑通：TDB 打开与 passdb 转换、guest 会话建立、SMB2/SMB3 读写往返、NT ACL 查询、`getpwnam`/组解析都成功。没有出现因 libc 定制而崩溃或符号缺失的问题。

已知差异与风险（未关闭）：

- `db_open_ex: mutexes requested but not available` 在实机同样出现（level 0），与 QEMU 结论一致，见 D-S2-11。
- `dos charset 'CP850' unavailable - using ASCII`：设备侧无 CP850 转换模块表，客户端侧提示后回落 ASCII。中文文件名本轮未测，不能据此判断 UTF-8 名称可用。

### 5.3 用例结果

| 用例 | 命令要点 | 结果 |
| --- | --- | --- |
| 配置解析 | `testparm -s etc/smb.conf`（设备原生 libc） | `Loaded services file OK.`，`ROLE_STANDALONE` |
| 访客列目录 | `smbclient //192.168.3.2/iso -p 1445 -N -m SMB3 -c ls` | 成功 |
| 上传/下载往返 | `put` 后 `get` 到本地 | 内容逐字节一致（`hello-from-s2`，14 B） |
| 错误密码 | `-U baduser%wrongpass` | 按 `map to guest = Bad User` 回落访客，会话建立成功 |
| 只读共享写入 | 追加 `[roshare] read only = yes` 后 `put` | `NT_STATUS_ACCESS_DENIED opening remote file \denied.txt` |
| NT ACL 查询 | `smbcacls -N //127.0.0.1/iso local.txt`（环回实例） | 返回 `OWNER:S2ACL\root`、`ACL:Unix Group\root:ALLOWED/0x0/R` |
| 外部域 SID 写入 | `smbcacls -a "ACL:S-1-5-21-1111…-1001:ALLOWED/0x0/R"` | `NT_STATUS_ACCESS_DENIED`（访客无权限，未进入 idmap 探测） |

### 5.4 `libidmap-private-samba.so` 两个未解析符号的结论（对应约束 4）

结论：**在 `--without-winbind` 的 smbd/nmbd 用例里调用不到**，属于“库被单独构建但没有使用者”的悬空引用，不是 idmap 路径会踩到的坑。依据分三层：

1. 引用点与定义点
   - 引用：`source3/winbindd/idmap.c:304` 的 `idmap_is_offline()` → `get_global_winbindd_state_offline()`；`source3/winbindd/idmap_tdb.c:86` 的 `convert_fn()` → `find_domain_from_name()`（老版 `winbindd_idmap.tdb` 升级路径）。
   - 定义：`source3/winbindd/winbindd_cache.c` 与 `source3/winbindd/winbindd_util.c`，只在 winbindd 程序里；本次构建未产出 winbindd。
2. 依赖关系
   - 全树只有 5 个 `lib/idmap/*.so` 和 `libidmap` 自身 NEEDED `libidmap-private-samba.so`；`sbin/smbd`、`sbin/nmbd`、全部 `bin/*` 与公共库都不 NEEDED 它；smbd 也未导出这两个符号（`readelf --dyn-syms` 无匹配）。
   - 调用 idmap 模块探测的唯一入口在 `idmap.c:399` 的 `smb_probe_module("idmap", …)`，而这段代码本身就在 libidmap 内，形成“先加载 libidmap 才能加载 idmap 模块”的闭环；smbd 没有加载 libidmap 的路径。
3. 实机行为
   - 普通文件 I/O 与 NT ACL 查询期间，`/proc/<pid>/maps` 中既无 `libidmap-private-samba.so` 也无 `lib/idmap/*.so`。
   - 配置 `idmap config * : backend = rid` + `range = 100000-199999`，在 `log level = 10` 下查询 ACL：日志只出现 `source3/lib/idmap_cache.c`（gencache 层的 SID/uid 缓存），没有任何 `probe_module("idmap")`、`Failed to load module` 或 `undefined symbol` 记录；SID 解析走的是 passdb 本地 SAM 域（`lookup_global_sam_rid`）。

未能单列证明的部分（如实标注）：用独立 `dlopen(RTLD_NOW)` 探针单独加载 `libidmap` 时，会先因缺少 smbd 提供的调试符号（`dbghdrclass`、`smb_panic` 等）失败，因此无法用“单独 dlopen”直接观察这两个符号的解析结果；上结论基于依赖关系、实际映射与 level 10 日志三条证据。若将来启用 winbindd 或让其它进程 `dlopen` `lib/idmap/*.so`（`lib/util/modules.c:41` 使用 `RTLD_NOW`），这两个符号会成为加载阻塞点，届时必须同时构建 winbindd。

### 5.5 清理与回滚核对

清理动作：`kill 10406 12331`（主实例与环回 ACL 实例）→ `rm -rf /userdisk/data/samba-s2`。

| 核对项 | 清理后实测 |
| --- | --- |
| 新根 | `ls /userdisk/data/samba-s2` → `No such file or directory` |
| 新实例进程 | 无 `samba-s2`/`smbd -F` 进程 |
| TCP 139/445 | 仍为原厂 `8471/smbd` |
| UDP 137/138 | 仍为原厂 `8469/nmbd` |
| 原厂二进制 | `md5sum /usr/sbin/samba_multicall` = `5e422d3463f40b4405ef8325ce3603e8`（测试前后一致） |
| 原厂配置 | `/etc/config/samba` 内容与 mtime（Oct 16 2018）不变，MD5 `244eb53e5019b95a408aebe49602561a` |
| 根分区 | `rootfs 107.9M / 87.7M / 81%`，仍为只读 |
| 外挂盘 | `/userdisk/data` 使用量回到 484.8G / 52% |

新根内的 TDB 全部落在 `var/lock`、`var/state`、`var/private` 下（`smbXsrv_*.tdb`、`passdb.tdb`、`secrets.tdb`、`registry.tdb` 等 13 个），原厂 `/var/lock` 下 TDB 的时间戳未被改动。

## 6. 复现要素与遗留现场

- 构建容器 `miwifi-s1`（`ubuntu:24.04`），工具链 `/toolchain/arm-xiaomi-linux-uclibcgnueabi`。
- 实机验证所用的构建树为 `/work/s2me/samba-4.25.1`，脚本 `/work/s2me/env.sh`、日志 `/work/s2me/{configure,build,install}.log`，安装树 `/work/prefix-s2`（均在仓库外）。
- 与 4.1 的 `/work/s2` 构建等价：同一 tar、同一 5 个补丁、同一 configure 选项，仅工作目录不同；两次独立构建的 `smbd` MD5 均为 `514708cb32e6a4ea4ea440e74f2d2d09`，可复现。
- 实机验证所用 4 个主程序（设备侧与构建机一致）：`smbd` 81,546 B / SHA-256 `2580dac4f5af06cc4089bfe696dd08f7659a7f824facb61c4ed97768d18a5e6d`，`nmbd` 253,126 B / `fed9fd102260df44eeeb38312058a99414bd19e0196e9852588c75e733eabf9e`，`smbclient` 140,459 B / `35b4312befccd71612800c1463e3a3f69ac31eb6ae63b10e4b65a5a5aa0df615`，`testparm` 43,299 B / `33b4e70e7b2de0fbd39f88c0c3776f1a0de60ffff67d768f65eaf2eba54fbe8a`。
- 设备侧日志已取回宿主 `/tmp/s2-evidence/{log.smbd,log.s2acl}`（不在仓库内），设备上的运行根已随之删除，下一阶段需重新上传后才能复跑。
- 设备当前无本项目任何残留文件或进程。

