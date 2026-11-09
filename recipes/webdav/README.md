# WebDAV（lighttpd 1.4.85 + mod_webdav）

R2D 上的 WebDAV 文件服务，与 Samba 共用同一批目录，但**不共享 Samba 的免密口径**。

## 端口与地址

- 监听：`192.168.3.2:5005`（br-lan 地址，与 Samba `interfaces=br-lan` 一致）
- 与现役服务无冲突：dropbear 22、samba-s5d 139/445、nmbd 137/138
- 不做 WAN 端口转发；仅内网可达
- 无 TLS（构建未启用 OpenSSL），因此用 HTTP Digest 认证，密码不以明文过网

## 认证与权限

- Digest 认证，`realm=r2d-webdav`，用户文件 `conf/users.htdigest`（`user:realm:md5`）
- lighttpd 绑定端口后降权到 `nobody:nogroup`，**不以 root 运行**
- `umask 000` 启动，新建文件 0666、目录 0777，与 Samba 的 `create mask`/`directory mask` 一致，两边可互相改写
- 只暴露 4 个目录：`下载`、`共享`、`图片`、`文档`；其它目录（含 `.dev`）不在 document-root 内
- 四个目录用 `mount --bind` 挂进 `webroot/`，避免客户端 DELETE 掉共享入口本身

## 设备布局

```
/userdisk/data/.dev/live/webdav/
  current -> versions/1.0.0-r2d/root   二进制 + mod_webdav + 私有 lib
  conf/lighttpd.conf                   配置
  conf/users.htdigest                  凭据（0600 nobody）
  state/                               pid、error.log、上传临时目录、webdav.db
  webroot/{下载,共享,图片,文档}          四个共享的 bind mount 点
  run.sh                               start|stop|restart|status|watch|heal
  webdav.log                           生命周期日志
/etc/init.d/webdav                     START=99，开机后台等待数据盘后拉起
/etc/rc.d/S99webdav -> ../init.d/webdav
```

二进制通过 `-m <current>/lib` 加载模块，不依赖编译期候选目录；`r2d-cand` 兼容链接保持不变。

## 开机与数据盘竞态

`/etc/init.d/webdav` 只做一件事：后台执行 `run.sh start`。`run.sh` 内部最多等 180 秒，
直到 `/proc/mounts` 出现 `/userdisk/data` 且 `current/sbin/lighttpd` 可执行，然后
bind mount 四个共享并启动；数据盘没挂上时不会启动半个服务。

`run.sh start` 还会拉起一个 30 秒周期的看护进程：共享挂载点丢失会重挂，lighttpd
被杀会自动重启。看护 pid 在 `state/watch.pid`。

## 部署 / 升级

```sh
# 部署新版本树：复制到 versions/<ver>/root，再把 current 指过去
ln -sfn versions/<ver>/root /userdisk/data/.dev/live/webdav/current
/userdisk/data/.dev/live/webdav/run.sh restart
```

修改用户：改 `conf/users.htdigest`（`user:realm:md5(user:realm:password)`），
保持属主 `nobody:nogroup`、权限 0600。

## 回退

```sh
/userdisk/data/.dev/live/webdav/run.sh stop   # 停看护与 lighttpd，卸载 4 个 bind mount
rm -f /etc/rc.d/S99webdav                     # 关开机自启
rm -f /etc/init.d/webdav                      # 彻底移除入口（可选）
```

回退不会改 Samba/dropbear 的任何配置，也不会删除四个共享目录里的数据。

## 已验证

- 设备本机与用户 Mac 的 curl：PROPFIND `/` 只列出 4 个共享；PUT/GET/MOVE/MKCOL/DELETE 均成功
- 未认证请求返回 401
- `kill -9 lighttpd` 后由看护在 30 秒周期内自动重启
- `init.d/webdav stop/start` 往返正常，139/445 与 22 不受影响

## 未验证 / 已知限制

- 对四个共享根发 `DELETE` 是 WebDAV 标准的递归删除语义，会清空目录内容（2026-11-10
  实测误删过 `共享/文件共享说明.jpg`，已从固件原件恢复，见 D-S16-07）；客户端批量操作需谨慎
- macOS Finder 的 `mount_webdav` 在本机自动化环境下未挂载成功（`-S` 返回 19/22，
  AppleScript 挂载超时），真实 Finder 客户端待人工确认；curl 走的是同一网络与认证路径
- 无 TLS，仅限内网使用
- Digest 认证下密码以 md5 摘要落盘；强弱取决于密码本身
