# WebDAV（lighttpd 1.4.85 + mod_webdav）

R2D 上的 WebDAV 文件服务，与 Samba 共用同一批目录，但**不共享 Samba 的免密口径**。

## 端口与地址

- 监听：`192.168.3.2:5005`（br-lan 地址，与 Samba `interfaces=br-lan` 一致）
- 与现役服务无冲突：dropbear 22、samba-s5d 139/445、nmbd 137/138
- 不做 WAN 端口转发；仅内网可达
- 无 TLS（构建未启用 OpenSSL），因此只在局域网内使用；认证方式见下

## 认证与权限

- Basic 认证，`realm=r2d-webdav`，用户文件 `conf/users.basic`（`user:password`，0600 nobody）
- 为什么不用 Digest：macOS 访达的 `WebDAVLib/1.3` 只发一次 `OPTIONS`，收到 Digest 挑战后
  不重试直接放弃（2026-11-10 用访问日志实测）；只有 Basic 能让 `⌘K` 正常挂载
- lighttpd 绑定端口后降权到 `nobody:nogroup`，**不以 root 运行**
- `umask 000` 启动，新建文件 0666、目录 0777，与 Samba 的 `create mask`/`directory mask` 一致，两边可互相改写
- 只暴露两个根，与 SMB 的 `XiaoMi` / `XiaoMi-usb0` 对应：
  - `本机储存` → `/userdisk/data` 下所有可见顶层目录（`下载`、`共享`、`图片`、`文档`、
    `摄像机监控视频`、`数学`、`文件`、`照片视频` …），逐个 `mount --bind` 进来
  - `外接盘` → `/extdisks/` 下第一个已挂载分区（当前 `sdb1`），热插拔后由看护重新绑定
- 两个根在根这一层只读，但机制不同：
  - `本机储存` 是 webroot 下的普通目录，`chmod 555`（属主 root）生效，根上
    `PUT`/`MKCOL` 被拒（`PUT` 返回 500、`MKCOL` 403），子目录是独立 bind mount，
    权限仍是 0777/0666，可正常读写
  - `外接盘` 本身是 bind mount，根权限来自 U 盘文件系统（vfat 恒为 777），挂载后的
    `chmod 555` 不生效。改由配置里的 `webdav.is-readonly` 只封集合本身
    （`$HTTP["url"] == "/%E5%A4%96%E6%8E%A5%E7%9B%98/"`），`PUT` 根返回 400；
    子路径仍可正常上传/改名/删除。这样避免一次误 `DELETE /外接盘/` 递归清空整块盘
- `.yunshu` 与顶层兼容链接 **从不挂进 webroot**：点开头条目、符号链接
  和 `lost+found` 在 `sync_local()` 里直接跳过，因此它们既不可访问也不会出现在列表里
  （原先的 `r2d-cand` 链接已于 2026-11-10 消除，`samba-s2` 也在 Samba 重编后删除）
- 根目录网页改为中文界面（见下节「界面」）：浏览器 `GET /` 返回静态页
  `ui/index.html`，不再直接看到 lighttpd 自带的英文列表页
- `dir-listing.encoding = "utf-8"`：同时给 HTML 加 `<meta charset>` 和
  `Content-Type: text/html; charset=utf-8`；不设时浏览器把 UTF-8 中文显示成乱码

## 设备布局

```
/userdisk/data/.yunshu/live/webdav/
  current -> versions/1.0.0-r2d/root   二进制 + mod_webdav + 私有 lib
  lib -> current/lib                   DT_RPATH 补丁的落点（见下）
  sbin -> current/sbin                 lighttpd-angel 默认路径的落点
  conf/lighttpd.conf                   配置
  conf/users.basic                     凭据（user:password，0600 nobody）
  ui/                                  中文界面（index.html / app.css / app.js / listing-shim.js）
  state/                               pid、error.log、上传临时目录、webdav.db
  state/usb.src                        当前绑定的外接盘路径（热插拔比对用）
  webroot/本机储存/                    数据盘可见顶层目录的 bind mount 点
  webroot/外接盘/                      外接盘分区的 bind mount 点
  run.sh                               start|stop|restart|status|watch|heal
  patch-rpath.sh                       改写 ELF 的 DT_RPATH（等长替换）
  webdav.log                           生命周期日志
/etc/init.d/webdav                     START=99，开机后台等待数据盘后拉起
/etc/rc.d/S99webdav -> ../init.d/webdav
```

## 界面

浏览器打开 `http://192.168.3.2:5005/` 看到的是中文单页，而不是 lighttpd 自带的
`Index of /` 页面：

- 根目录列出 `本机储存` / `外接盘`，带文件夹图标；进入后按「目录优先 + 拼音」排序，
  显示名称、大小、修改时间，顶部有面包屑、每层有 `返回上级`、右上角 `共 N 项`
- 浅色 / 深色跟随 `prefers-color-scheme`，无主题开关；窄屏（390px）单列、不横向溢出
- 底部「上传 / 改名 / 删除」提示按 UA 只显示一条：macOS 给访达 `⌘K`、Windows 给
  「映射网络驱动器」并附「使用其他凭据」、手机与 Linux 说明浏览器内可直接浏览下载；
  地址取自当前 `location.origin`，不写死 IP
- 所有可见文案为中文；`Index of` / `Directory listing` / `Parent Directory` 不再出现
- 视觉上只参考了 Aurora 的克制风格，不依赖 LuCI 的 CSS 或变量

### 实现方式与代价

`GET /` 时用 `mod_indexfile` + 条件 `server.document-root` 把请求切到 `ui/`，
`/__ui/` 由 `mod_alias` 提供静态资源；目录条目由页面同源 `PROPFIND`（`Depth: 1`）
读取后在浏览器渲染。WebDAV 方法与认证完全不变。

没有选服务端渲染（`mod_cgi`）的原因：这版 lighttpd **没有编译 PCRE**，
`url.rewrite-once` 与正则条件不可用，无法把任意目录的 GET 分发给 CGI；
`mod_dirlisting` 的英文文案又硬编码在模块里，没有 i18n 开关。

代价：

- 列表依赖浏览器 JS；禁用 JS 时 `/` 是中文静态壳但没有条目，深层目录会退回
  lighttpd 自带英文列表页（仍可浏览/下载）
- 深层目录仍由 `mod_dirlisting` 生成（本构建无法重写 URL），`listing-shim.js`
  会立即把浏览器转到 `/?p=...`；`curl` 抓深层目录 HTML 时仍会看到英文标题
- 隐藏项目（`.` 开头）在 `PROPFIND` 响应里仍存在（与改造前一致），页面渲染时过滤，
  不显示

### 部署与回退

```sh
D=/userdisk/data/.yunshu/live/webdav
# 部署界面文件（仅静态资源，不必重启；改了 lighttpd.conf 才需要 restart）
tar -C recipes/webdav -cf - ui | tar -C $D -xf -
chown -R root:root $D/ui && chmod 644 $D/ui/*

# 配置（首次启用界面时）
cp $D/conf/lighttpd.conf $D/conf/lighttpd.conf.bak-$(date +%Y%m%d)
cp recipes/webdav/lighttpd.conf $D/conf/lighttpd.conf
$D/current/sbin/lighttpd -m $D/current/lib -f $D/conf/lighttpd.conf -t && $D/run.sh restart

# 回退
cp $D/conf/lighttpd.conf.bak-<日期> $D/conf/lighttpd.conf
mv $D/ui $D/ui.disabled
$D/run.sh restart
```

界面证据（生产 curl 矩阵与明/暗/窄屏截图）：
[`docs/evidence/2026-11-10-webdav-ui/`](../../docs/evidence/2026-11-10-webdav-ui/)。
响应式实测（19 档宽度 × 明暗、深层目录页、面包屑修复）：
[`docs/evidence/2026-11-10-webdav-responsive/`](../../docs/evidence/2026-11-10-webdav-responsive/)。
端点自检（路径/方法/认证/编码、两处修复）：
[`docs/evidence/2026-11-10-webdav-endpoints/`](../../docs/evidence/2026-11-10-webdav-endpoints/)。

## 编译期路径与 `r2d-cand`

二进制与模块在构建时把 `DT_RPATH` 写死为构建前缀下的绝对路径，不会用 `-m` 或
`LD_LIBRARY_PATH` 覆盖：实测 uClibc 先解析对象自身的 `DT_RPATH`，再查环境变量，
所以只设 `LD_LIBRARY_PATH` 无效（`LD_PRELOAD` 也会再加载一份旧路径下的库）。

处理方式是把 25 个 ELF 里的整段旧路径（构建机 `DESTDIR` 前缀 + 设备候选路径，共两段、
112 字节）**等长**改写为 `/userdisk/data/.yunshu/live/webdav/lib`，不足的字节用 NUL 填充，
再由 [`patch-rpath.sh`](patch-rpath.sh) 固化。等长是硬约束：改长短会让 ELF 后续偏移错位，
表现为启动即 SIGILL。只替换子串（保留 `/work/stage2` 之类构建机前缀）会得到
`/work/stage2/...` 的 RPATH，同样启动失败——脚本现在整段匹配。完成后数据盘根上的
`r2d-cand` 链接与 `candidates/b6-webdav` 已删除。

`bin/xmllint` 的帮助文本与 `sbin/lighttpd-angel` 的默认路径也含编译期前缀，同样做了等长
改写，分别落到 `live/webdav/etc/xml/catalog` 与 `live/webdav/sbin/lighttpd`。`sbin`
符号链接指向 `current`；原树本就不带 `etc`（xmllint 不依赖该 catalog），因此不保留 `etc` 链接。

## 开机与数据盘竞态

`/etc/init.d/webdav` 只做一件事：后台执行 `run.sh start`。`run.sh` 内部最多等 180 秒，
直到 `/proc/mounts` 出现 `/userdisk/data` 且 `current/sbin/lighttpd` 可执行，然后
bind mount `本机储存` 的各个顶层目录与外接盘并启动；数据盘没挂上时不会启动半个服务。

`run.sh start` 还会拉起一个 30 秒周期的看护进程：重新扫描数据盘顶层目录（新增目录自动出现、
消失的目录自动摘除）、跟踪 `/extdisks` 下当前挂载的分区并重绑外接盘，lighttpd 被杀会
自动重启。看护 pid 在 `state/watch.pid`。外接盘拔掉时 `外接盘` 变为空目录，服务与根列表
仍正常；重新插上（即使挂载点从 `sdb1` 变成别的名字）会在一个周期内重新绑上。

## 部署 / 升级

```sh
# 部署新版本树：复制到 versions/<ver>/root
cp -a <新树> /userdisk/data/.yunshu/live/webdav/versions/<ver>/root
# 必须先改写 DT_RPATH，否则它仍指向构建机的绝对路径（见上一节）
sh /userdisk/data/.yunshu/live/webdav/patch-rpath.sh \
   /userdisk/data/.yunshu/live/webdav/versions/<ver>/root
# 再把 current 指过去并重启
ln -sfn versions/<ver>/root /userdisk/data/.yunshu/live/webdav/current
/userdisk/data/.yunshu/live/webdav/run.sh restart
```

`patch-rpath.sh` 只改长度完全匹配的旧 RPATH 字符串，改完校验文件字节数不变；
若新树的构建前缀与 `b6-webdav` 不同，需要先改脚本里的旧串。

修改用户：改 `conf/users.basic`（`user:password`），
保持属主 `nobody:nogroup`、权限 0600，然后 `run.sh restart`。

## 回退

```sh
/userdisk/data/.yunshu/live/webdav/run.sh stop   # 停看护与 lighttpd，卸载 4 个 bind mount
rm -f /etc/rc.d/S99webdav                     # 关开机自启
rm -f /etc/init.d/webdav                      # 彻底移除入口（可选）
```

回退不会改 Samba/dropbear 的任何配置，也不会删除数据盘与外接盘里的数据。

## 已验证

- 未认证 `GET /` 返回 401（`WWW-Authenticate: Basic`）
- `GET /` 返回 200，`<title>文件浏览</title>`；`/__ui/*` 三个静态资源均 200
- 页面渲染后只有中文文案，根目录两个入口，子目录可继续进入并有 `返回上级`
- 深层目录 `GET` 200 后由 `listing-shim.js` 转跳 `/?p=...`，落到中文界面
- `PROPFIND /`、`/本机储存/`、`/外接盘/` 均 207；`OPTIONS /` 返回 200 与 `DAV: 1,2,3`
- 目录页 `Content-Type: text/html; charset=utf-8` 且含 `<meta charset>`，中文名不再乱码
- `本机储存/下载` 下 PUT 201 / GET 200（内容一致）/ DELETE 204
- 在 `本机储存` 根上 PUT 被拒（`mod_webdav` 返回 500，错误日志为 `Permission denied`）
- `.yunshu`、`samba-s2` 均 404，且不出现在 `GET /本机储存/` 的列表里（`r2d-cand` 已删除）
- 摘掉 `外接盘` 的 bind mount 模拟拔盘：根列表仍 200、`外接盘` 为空目录；35 秒内看护自动重绑
- `kill -9 lighttpd` 后由看护在 30 秒周期内自动重启
- `init.d/webdav stop/start` 往返正常，139/445 与 22 不受影响

## 外接盘首访问延迟

2026-11-11 实测（证据见 [`docs/evidence/2026-11-11-usb-first-access/`](../../docs/evidence/2026-11-11-usb-first-access/)）：

- 外接盘不休眠：空闲 900 秒后第一次未缓存 4 KB 块读 **20 ms**，`/sys/block/sdb/device/state` 始终
  `running`，没有 USB autosuspend 节点，`dmesg` 无重新枚举。**因此没有加常驻保活**——盘不 park 磁头，
  保活只会增加读写与磨损。
- 系统安静时，`本机储存` 与 `外接盘` 的首访问、`OPTIONS`/`HEAD`/`PROPFIND Depth 0/1`/`GET` 都是 **7–12 ms**，
  两者无差别；根目录只有十几项，不存在 stat 风暴。
- 变慢来自这台 254 MB 机器的资源争抢，不是盘：设备上残留脚本把 `load` 顶到 4.15 时，`HEAD /外接盘/`
  169–716 ms、裸读 140–250 ms；Mac 把 SMB 共享挂进 Finder 后 Spotlight 索引，`smbd` 常驻 145 MB、
  swap 108 MB，WebDAV 也会被拖到 100–400 ms。移除后分别回到 7–12 ms。
- Mac 侧挂 SMB 建议 `mount_smbfs -o nobrowse`（或把该卷加进「聚焦 → 隐私」），避免索引路由器上的盘；
  WebDAV 不会被 Spotlight 索引。

## 调优实测（2026-11-11）

在设备上做了六组「一次只改一个变量、测完回滚」的对照实验，证据与逐项数字见
[`docs/evidence/2026-11-11-webdav-tuning/`](../../docs/evidence/2026-11-11-webdav-tuning/)。
结论是**全部不保留，配置保持原样**：

- `server.stream-request-body = 2`、`server.stream-response-body = 1`、
  `server.network-backend = "linux-sendfile"`、`server.stat-cache-engine = "inotify"`、
  `mod_deflate`、`server.max-connections = 64` 六组改动，64 MB 写读、200×4 KB 小文件、
  200 项 `PROPFIND` 全部落在基线的 ±10% 噪声内。
- 原因是瓶颈在 Wi-Fi 链路：设备本机 loopback PUT 29.9 MB/s、GET 35 MB/s，
  4 路并发聚合 37.1 MB/s；同一台机器经 Wi-Fi 单流只有 9–16 MB/s。
- `server.max-request-size` 单位是 KB、默认不限，显式设小会直接拒绝大文件 PUT，因此不设；
  TSO/GSO 因无 `ethtool`、无 sysfs features 不可测；`server.max-worker = 2` 对单流无帮助，
  且会让缓冲区翻倍，不做。
- 不要引入 `mod_deflate`：`mod_webdav` 的 207 响应不经过它，200 项 `PROPFIND` 响应仍为
  52429 B。也不要为了"看起来更快"改 `stat-cache-engine`，根目录只有十几项。
- 客户端差异远大于服务端变量：同一批 200 个 4 KB 文件，keep-alive 0.99 s、
  每文件一个 `curl` 进程 5.80 s、`xargs -P 8` 2.39 s。要提速小文件应换客户端或加并发。

设备上留有一份 `conf/lighttpd.conf.bak-b0`（B0 副本），确认无调优痕迹后可直接删除。

## 未验证 / 已知限制

- `PROPFIND Depth: infinity`（以及非法的 `Depth: 2`）返回 403：`mod_webdav` 不支持
  无限深度；Finder 与资源管理器只用 `Depth: 0/1`，不影响挂载
- `PROPPATCH` 返回 204 但属性不持久化（`displayname` 回读为空），属于 `mod_webdav`
  未实现 dead property；要改显示名请直接改名
- `PROPFIND /__ui/*` 返回 404（`mod_webdav` 按 docroot 解析、不经过 alias）；
  `GET /__ui/` 返回 403（已关闭目录列表），资源文件本身 200
- 只读根的错误码不统一：`PUT /本机储存/x` 500、`MKCOL` 403、`PUT /x` 500、`PUT /` 400，
  功能上都被拒
- 对共享根发 `DELETE` 是 WebDAV 标准的递归删除语义，会清空目录内容（2026-11-10
  实测误删过 `共享/文件共享说明.jpg`，已从固件原件恢复，见 D-S16-07）；客户端批量操作需谨慎
- `本机储存` 直接暴露数据盘上的用户内容。SMB 的 `XiaoMi` 根共享本来也覆盖同一片数据，
  但 SMB 对 `摄像机监控视频` 有 `vfs object = readonly` + 时间窗策略，**WebDAV 没有等价
  限制**；这是可见的行为差异，见 D-S18-04
- 数据盘根部的**散落文件**（根目录下的 mp3/mp4/zip 等）没有逐个 bind，只有目录会出现在
  `本机储存` 里；这样做是为了避免文件被替换后 bind 指向旧 inode
- 在 `本机储存` 根上写入返回 500 而不是 403（lighttpd `mod_webdav` 的错误映射），
  功能上被拒，Finder 会显示通用失败
- macOS Finder 的 `mount_webdav` 在本机自动化环境下仍未能完成 GUI 级挂载（钥匙串 ACL
  在沙箱内不可满足），需人工用 `⌘K` 确认；服务端已按 Finder 的要求提供 Basic +
  `OPTIONS 200` + `PROPFIND 207` + `GET / 200`。`mod_webdav` 不返回 `D:displayname`，
  Finder 显示名来自 `D:href` 的 UTF-8 百分号解码，服务端这一层的编码已确认正确
- 无 TLS，Basic 口令在局域网内以 base64 传输；仅限可信内网，不要做 WAN 端口转发
- 凭据以明文形式存放在 `conf/users.basic`（0600 nobody），设备上仅有 root/nobody 可读
