# R2D 清理收尾与第二批评估（2026-11-11）

- 设备：MiWiFi R2D / ROM 2.25.209 / 192.168.3.2，根 `ubifs (ro)`，数据盘 `/dev/sda1` ext4
- 范围：清掉无引用残留、收敛归档；对四项“需评估后再动”的对象给结论
- 保留规则见 [decisions.md S22](../decisions.md)

## 1. 第一批清理结果

| 项 | 处理 | 空间 | 回滚 |
|---|---|---|---|
| `evidence/coldboot-20261110/` 空壳 | 补入 `2026-11-10-post-coldboot.txt`（自 `2026-11-10-yunshu-cutover/` 复制）与 `README.txt`；原有 `baseline.txt`/`after.txt` 保留 | 0 | 无需回滚；证据只增 |
| `releases/` 归档 | 保留 1.0.7-r2d 与 1.0.8-r2d 两个包；删除空目录 `release/`；1.0.7 包上移一层 | 0（未删包） | 包未删，原位可用 |
| `builds/b1-dropbear-relax` | 候选与 live 二进制 md5 同为 `fd9574db…`，B1 已上线并多轮验证，删除 | 524 KB | `recipes/stage2/b1-dropbear-relax.sh` 可重建 |
| `.dev` 残留 | 设备 `live/webdav/run.sh` 与仓库同步，注释改 `.yunshu`；旧版存 `backups/cleanup-20261111/run.sh.device-before` | 0 | 还原该备份即可 |
| 两条 `192.168.31.6` DNAT | 归档 `iptables-save.before.txt`、`firewall.uci.before.txt`、`firewall.config.before` 后删除 `firewall.dmz`/`firewall.dmzudp`；`firewall reload` 后 `iptables -t nat -S` 无 31.6 | 0 | 按归档的 UCI 段恢复两条 redirect 后 reload |
| `var/state` 0777 → 0755 | `testparm` 权限告警消失（仅剩既有 `null passwords` deprecated）；SMB 枚举、`.yunshu` 隐藏、`下载` put/get/del 实测正常 | 0 | `chmod 777 var/state` |
| `/tmp` 陈旧文件 | 删除 `5m.bin` 5,132 KB、`webdav-stageC.sh` 8 KB | 5,140 KB（tmpfs/RAM，不是根分区） | 无需回滚 |
| `backups/s7root-backup` | 14,088 KB，`versions/1.0.7-r2d/root` 仍在，回退链不缺，删除 | 14,088 KB | 不恢复；v1 已被 1.0.x 取代 |
| `backups/` 其余 12 项 | 全部被 `decisions.md`、`LAYOUT.txt`、回滚脚本或 `MANIFEST` 引用，保留 | 0 | — |

数据盘已用由 508,855,356 KB 降至 508,840,740 KB（约 14.3 MB）。根分区仍为
20.1 MB 可用（81%），`/tmp` 为 99.4 MB tmpfs、当前占用 940 KB。

## 2. 第二批评估

### 2.1 `/userdisk/data` 根 0777 → 0755

现状：`drwxrwxrwx root:root`，ext4，无 ACL。

依赖核查：

- SMB `[XiaoMi]` 的 `path = /userdisk/data` 为 `guest ok = yes` + `force user = root`，
  网络写入实际以 root 进行，mode 位不构成边界；其余共享均指向子目录。
- WebDAV 的 `server.document-root` 是 `.yunshu/live/webdav/webroot`，`本机储存` 为
  `dr-xr-xr-x`，8 个子目录以 bind mount 挂入；`/userdisk/data` 根本身不在 WebDAV 路径上。
- 本机非 root 进程只有 lighttpd（nobody）与 samba 子进程（65534）；前者不写数据盘根，
  后者在共享内被 `force user = root` 覆盖。厂商服务（datacenter/indexservice/mediaservice/
  `stat_lan` 等）均以 root 运行。

结论：改 0755 在功能上安全，但安全收益低——SMB 整盘共享以 root 写，mode 不是访问边界；
WebDAV 不经过该层。建议可改，但不是必须；若改，窗口内 `chmod 0755 /userdisk/data`，
回滚 `chmod 0777`，随后回归 SMB 根目录建/删、8 个共享读写与 App 上传。本轮未改。

### 2.2 `外接盘` 根 0777

现状：`/extdisks/sdb1` 为 tntfs，挂载参数 `uid=0,gid=0,umask=00`；WebDAV 的
`webroot/外接盘` 是同一文件系统的 bind mount，因此呈现 0777。

- `chmod` 不持久：权限由 `umask=00` 决定，重新挂载/热插拔后仍是 0777。
- lighttpd 以 nobody 运行，需要在外接盘根创建、改名、删除；改成 `umask=022` 会让根
  变为 root:root 755，WebDAV 外接盘写入直接退化。
- 收紧必须同时改挂载参数（uid/gid/umask）与 WebDAV 运行身份，且厂商 hotplug 重挂
  会覆盖参数，回归面远大于收益。

结论：不改。边界是“可物理接触的 USB 盘 + LAN 认证”，已在文档标注原因。

### 2.3 nmbd 监听面

现状：私有 nmbd 4.25.1（PID 11692）持有 UDP 137/138；`netstat -lunp` 同时显示
`0.0.0.0:137/138`、`192.168.3.2:137/138` 与广播地址。`smb.conf` 已是
`interfaces = 192.168.3.2` + `bind interfaces only = yes`。

实测：`nmblookup -A 192.168.3.2` 返回 `XIAOMI_8041<00/03/20>` 与 `WORKGROUP<00/1e>`；
`nmblookup -A 127.0.0.1` 返回 `No reply from 127.0.0.1`。说明通配 socket 只是 nmbd
的广播接收实现，应用层仍按 `interfaces` 过滤，非配置漏项。

可达面：`br-lan`（192.168.3.2）与 `lo`；`br-guest` 成员为空（`brctl show` bridge id
`0000…`，无接口），无 WAN 接口。因此当前没有额外网络可达。防火墙现状：`br-lan` 的
TCP 139/445 与 UDP 137/138 都进 `s8-diskacl`（MAC 黑名单）；`br-guest` 只有
TCP 139/445 的整段 DROP，UDP 137/138 未单独覆盖。

结论：现状可接受，不建议现在改。若将来启用访客 Wi-Fi，应先把 UDP 137/138 加入
`br-guest` DROP 再开放访客网络；回滚 = 删除新增两条 DROP + `firewall reload`。
停用 nmbd 可彻底消除监听，但会失去网络邻居与电视/App 的发现路径，不作为默认建议。

### 2.4 8443 返回 502（已修复）

配置：`/tmp/sysapihttpdconf/sysapihttpd.conf`（每次 start/reload 由 `/etc/sysapihttpd/`
模板生成），原 8443 块为：

```nginx
server {
    listen 8443 ssl;
    server_name miwifi.com www.miwifi.com;
    location / {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $http_host;
    }
}
```

上游 `127.0.0.1:8080` 是厂商 `himan`（PID 7057，`--proxy https://api.miwifi.com/utils/proxy`），
按 Host 做虚拟主机路由。实测：

| 请求 | 结果 |
|---|---|
| `curl -H 'Host: 192.168.3.2' http://127.0.0.1:8080/` | 200（nginx/1.2.2 页面） |
| `curl -H 'Host: 192.168.3.2:8443' http://127.0.0.1:8080/` | 空回复（curl rc 52） |
| `curl -H 'Host: 127.0.0.1:8080' http://127.0.0.1:8080/` | 空回复（curl rc 52） |
| `curl -k https://127.0.0.1:8443/` | 502 Bad Gateway（nginx） |

根因：`$http_host` 保留了客户端端口（`:8443`），himan 的 vhost 表只匹配不带端口的
主机名，匹配失败后直接关闭连接；nginx 将“上游空回复”映射为 502。

**方案取舍**

1. 开机后用 init 改 `/tmp` 配置再 reload：不可行。`reload` 会 source `/usr/sbin/ngxld`，
   而 `env_init` 先 `rm -rf /tmp/sysapihttpdconf` 再从 `/etc/sysapihttpd/` 复制模板，
   `/tmp` 的补丁会被这次 reload 自己冲掉。
2. 改 himan 的 vhost：himan 是二进制 + 云端规则（`--rule https://api.miwifi.com/...`），
   没有可编辑的本地 vhost 文件，且属 App 通道，放弃。
3. 在 8443 前加自建反代：需要抢占 8443 或改端口，影响 App、证书与 SNI，影响面最大，放弃。
4. **选定：改 `/etc/sysapihttpd/sysapihttpd.conf` 模板中 8443 块的 Host 头。**
   模板是每次生成的源头，改模板等价于“每次重生成后都套上补丁”，不需要额外 init；
   只改 8443 块（第 713 行），其余 4 处 `$http_host`（591/612/634/655）保持原样，
   避免影响 App 的其它代理通道。

```diff
@@ /etc/sysapihttpd/sysapihttpd.conf (8443 server block)
-            proxy_set_header Host $http_host;
+            proxy_set_header Host $host;
```

**备份与回滚**

- 备份目录：`/userdisk/data/.yunshu/backups/8443-hostfix-20261111/`
  - `sysapihttpd.conf.etc-before`（md5 `b319adbef183280ff7e1a36ddd5e6b31`）
  - `sysapihttpd.conf.tmp-before`（md5 `4f13e5135bf8a620a76f2c8c1e31c9e1`）
  - `MANIFEST.txt`（证书 sha256、回滚命令）
- 回滚：`cp -p .../sysapihttpd.conf.etc-before /etc/sysapihttpd/sysapihttpd.conf &&
  /etc/init.d/sysapihttpd reload`

**验证**

| 项 | 结果 |
|---|---|
| `curl -sk https://192.168.3.2:8443/`（Mac） | 200，1770 字节，返回正常页面 |
| `curl -s http://192.168.3.2/` | 200 |
| 8443 证书 sha256（SNI `miwifi.com`） | `1C:BA:D0:…:86:74`，与改动前一致 |
| `--resolve miwifi.com:8443:192.168.3.2` | 200，SNI 行为不变 |
| 回滚演练 | 还原模板后 502，重新套用后 200 |
| 配置重生成演练 | `rm -rf /tmp/sysapihttpdconf && reload` 后第 713 行仍为 `$host`，8443/80 均 200 |

冷启动未执行真实 reboot；`/tmp/sysapihttpdconf` 在每次 start/reload 都由 `/etc/sysapihttpd/`
重建，上面的“删目录 + reload”与开机生成路径等价，可证明补丁随重生成保留。

### 2.5 `ngx_http_load_usb` 的 emerg 日志（已消除）

reload 时固定出现两条日志：

```
Error while opening the file.
: No such file or directory
nginx: [emerg] "" usb root is  in /tmp/sysapihttpdconf/sysapihttpd.conf:407
ngx_http_load_usb
```

排查结论：

- `preload` 指令由 `ngx_http_load_usb` 模块实现，位于 8193 server 的 `location /`；
  它读 `/tmp/usbDeployRootPath.conf` 作为 USB 部署根，再拼 `/xiaomi_router/.cache_dir/`。
- 全 rootfs 只有 `sysapihttpd` 自身引用该文件，没有生成脚本或二进制；UCI 也没有
  usb deploy 配置。属于厂商通用能力，本机从未触发，**不是“该生成但失败了”**。
- `nginx -t` 仍成功，是因为模块在缺文件时降级为空 usb root 并返回 `NGX_CONF_OK`，
  这条日志只是解析期诊断，不影响配置有效性。
- 占位文件不能消日志：空文件仍打印 `"" usb root is`；写入路径反而多一条
  `cache_dir is`。模块对这两条是无条件按 emerg 输出，与文件内容无关。
- 本机该功能是死路径：`/userdisk/data/.cache_dir` 只有 4 KB 空目录，`cachecenter`
  未运行，全系统没有 8193 的调用方，改动前 8193 本身返回 500。

处理：注释 `/etc/sysapihttpd/sysapihttpd.conf` 第 407 行的 `preload` 指令，保留
`preload_zone`（8194 的 `preload_statistics` 仍在用）和 8193 的 `/http_proxy`。
8193 由 500 变为 404，两者都不是可用路径。

- 备份：`/userdisk/data/.yunshu/backups/usbpreload-20261111/`（`sysapihttpd.conf.before`，
  md5 `e396a10c20f77ba5399ba754362abe2d`，`MANIFEST.txt` 含原因与回滚命令）
- 回滚：`cp -p .../sysapihttpd.conf.before /etc/sysapihttpd/sysapihttpd.conf &&
  /etc/init.d/sysapihttpd reload`

验证：reload 与“删 `/tmp/sysapihttpdconf` 再 reload”后 `usb-emerg=0`、`nginx -t` 成功；
80=200、8443=200、5005=401；139/445 仍归 `samba-s5d`，137/138 仍归 `nmbd`；
回滚演练 emerg 回到 2 条，重新套用后回到 0。

## 3. 结论汇总

| 对象 | 结论 | 是否改动 |
|---|---|---|
| `/userdisk/data` 根 | 可改 0755，功能安全但收益低；SMB 以 root 写，mode 非边界 | 否，等决定 |
| `外接盘` 根 | 不改；tntfs `umask=00` 决定呈现权限，收紧会破坏 WebDAV 写入 | 否 |
| nmbd 监听面 | 保持；通配 socket 已被 `bind interfaces only` 过滤，实测 loopback 无响应 | 否 |
| 8443 502 | 厂商 Host 头带端口导致 himan 空回复；改 `/etc/sysapihttpd/` 模板为 `$host` 修复 | 是（2026-11-11） |
| `ngx_http_load_usb` emerg | USB 部署功能未启用、无生成方；占位文件无效，注释模板中 8193 的 `preload` 指令 | 是（2026-11-11） |
