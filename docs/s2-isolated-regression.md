# S2 隔离回归（在设备上跑新实例，不碰原厂）

状态：隔离构建与本地冒烟已完成；设备侧部署未执行（属真实设备写操作，待授权）

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
| 设备侧部署 `/userdisk/data/samba-s2` | 属真实设备写操作，需用户授权后执行 |
| macOS Finder 挂载、中文文件名、重连、安全弹出 | 需设备侧实例与真机客户端 |
| Emby 目录/存在检查/拖动/完整播放 | 需设备侧实例与真机客户端 |
| 强制签名、强制加密与拒绝策略 | 本轮配置沿用原厂 `smb encrypt = no`，未做强制策略用例 |
| SMB1 是否保留的产品结论 | 仅证明服务端仍能接受 SMB1，未做客户端矩阵，见 D-S2-09 |
| 内核 2.6.36 下的锁、线程、sendfile、inotify | QEMU 使用宿主内核，属 S6 |
| 长稳、CPU/内存、I/O、日志增长 | 未开始 |

## 5. 设备侧待执行（需授权）

以下步骤会向设备写入文件并启动新进程，按项目约定需用户明确授权后执行：

1. `mkdir -p /userdisk/data/samba-s2/root` 及第 3 节列出的全部 `var/*` 目录。
2. 上传安装树（41 MiB）与 `etc/smb.conf`。
3. 以 `nohup` 启动 `smbd -F --no-process-group`，只监听 `192.168.3.2:1445`。
4. 用 macOS 与 Emby 跑 4.2 中未覆盖的客户端用例，并补并发、断线重连、重启用例。
5. 结束即按第 2 节回滚并核对原厂端口、二进制 MD5 与根分区用量。

## 6. 复现要素

- 构建容器：`miwifi-s1`（`ubuntu:24.04`），挂载 SDK 工具链为 `/toolchain`、构建工作树为 `/work`；本次构建树 `/work/s2/samba-4.25.1`，安装树 `/work/prefix-s2`。
- 构建脚本：`/work/s2-final.sh`（仓库外），日志 `/work/logs2/final-*.log`。
- 本机回归脚本：`/work/run-smbd-s2.sh`（仓库外），日志 `/work/s2/var/log/`。
- 以上脚本与安装树都在仓库外，仓库只保留本记录与散列。

