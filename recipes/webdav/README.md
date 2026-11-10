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
- 两个根用 `chmod 555`（属主 root），在根上 `PUT`/`MKCOL`/`DELETE` 会被拒；子目录是独立
  bind mount，权限仍是 0777/0666，可正常读写
- `.yunshu` 与顶层兼容链接 **从不挂进 webroot**：点开头条目、符号链接
  和 `lost+found` 在 `sync_local()` 里直接跳过，因此它们既不可访问也不会出现在列表里
  （原先的 `r2d-cand` 链接已于 2026-11-10 消除，`samba-s2` 也在 Samba 重编后删除）
- 目录列表已启用（`mod_dirlisting`）：浏览器 `GET /` 直接看到这两个入口，不返回 403
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
- `GET /` 返回 200 且恰好列出两个入口：`本机储存`、`外接盘`；两者子目录 `GET` 均 200
- `PROPFIND /`、`/本机储存/`、`/外接盘/` 均 207；`OPTIONS /` 返回 200 与 `DAV: 1,2,3`
- 目录页 `Content-Type: text/html; charset=utf-8` 且含 `<meta charset>`，中文名不再乱码
- `本机储存/下载` 下 PUT 201 / GET 200（内容一致）/ DELETE 204
- 在 `本机储存` 根上 PUT 被拒（`mod_webdav` 返回 500，错误日志为 `Permission denied`）
- `.yunshu`、`samba-s2` 均 404，且不出现在 `GET /本机储存/` 的列表里（`r2d-cand` 已删除）
- 摘掉 `外接盘` 的 bind mount 模拟拔盘：根列表仍 200、`外接盘` 为空目录；35 秒内看护自动重绑
- `kill -9 lighttpd` 后由看护在 30 秒周期内自动重启
- `init.d/webdav stop/start` 往返正常，139/445 与 22 不受影响

## 未验证 / 已知限制

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
