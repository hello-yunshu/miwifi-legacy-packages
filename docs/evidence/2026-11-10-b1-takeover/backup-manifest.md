# B1 备份清单：原厂 Dropbear 2011.54（22 端口）

- 采集时间：2026-11-10 01:29 CST（设备本地时间）
- 设备备份目录：`/userdisk/data/dropbear-state/backup-dropbear-v2011.54/`
- 备份方式：`cp -p` 实际字节副本（非仅哈希），`md5sum -c` 全部 OK
- 设备无 `sha256sum`/`openssl`：md5 在设备上计算，sha256 在把同一副本取回主机后计算
- 还原脚本：`/userdisk/data/dropbear-state/backup-dropbear-v2011.54/restore.sh`

## 文件

| 设备原路径 | 大小(B) | md5 | sha256 |
|---|---|---|---|
| /usr/sbin/dropbear | 175184 | c2cd6355107bfffb32c8d773c2c8ad25 | 1b631a6b8d706792a0db756832a0a37d64d01c1e70fff1b9eede574ebb9d9211 |
| /usr/bin/dropbearkey | 175184 | c2cd6355107bfffb32c8d773c2c8ad25 | 1b631a6b8d706792a0db756832a0a37d64d01c1e70fff1b9eede574ebb9d9211 |
| /usr/bin/dbclient | 175184 | c2cd6355107bfffb32c8d773c2c8ad25 | 1b631a6b8d706792a0db756832a0a37d64d01c1e70fff1b9eede574ebb9d9211 |
| /etc/init.d/dropbear | 4583 | b010c10c00d12dec35b8ab4d2e88e2bb | 29b8f6beae81fccd82fc8981fb364b906959f18ea34958a2db5287fac3f5c888 |
| /etc/config/dropbear | 134 | 4ff9c827d4f95ca5082a5520c03e1419 | 0198dbc97b5a9aac76a5c6233684571ccdcc91fcb735e91c36d2b06a98158589 |
| /etc/dropbear/authorized_keys | 578 | 2b25ef3311bbec3c3a16426834d1a38f | bd61cf09b9b44c4572b9fb481402c797d351db68a8e931f23c7d2cbf10e0f0c0 |
| /etc/dropbear/dropbear_rsa_host_key | 427 | 7b335b01de340c26de923e6e5770c13b | cf538c1c70c4a116780c5217ceb0b33a4cce09e0fb6e0305ed69d66fada9798a |
| /etc/dropbear/dropbear_dss_host_key | 459 | f0d0cdbd4f71136ee94b181ee3df3e29 | 5c473e7122027d96cc1866fca16184d2a58457bbcdda86cb776d271e1d11bb9b |
| /etc/rc.common | 1761 | 5f5be5254ae90e76817844038a485f0b | 10603aa0809cafa3e7512d999389d9461510610b273bde86b60d80318568a9ae |
| /lib/functions/service.sh | 3488 | cffa973cb0e71e1d12967d843ee92179 | fe3fb5f72ad858bae211a8ab7f386f61836529ef6399921624a78aae9306ff60 |
| /etc/rc.local | 128 | 8b495cce031f84dbc05fe2e1135827ea | b8e87eea052d9ab3de2cf926a54dfb33dfef35ec16cce3ea887c4bb19de7ec56 |

## 启动与运行态

- 备注：`/usr/sbin/dropbear`、`/usr/bin/dropbearkey`、`/usr/bin/dbclient` 为同一 multicall 二进制的三个入口，md5 相同。
- 原厂监听 PID：`7152`；启动命令行：`/usr/sbin/dropbear -P /var/run/dropbear.1.pid -p 22`
- `/proc/7152/exe` → `/usr/sbin/dropbear`
- 监听：`0.0.0.0:22` 与 `:::22`
- 运行态 pidfile 内容：`7152`
- `nvram get ssh_en` = `1`；`xiaoqiang_version...CHANNEL` = `stable`
- `/etc/rc.d/S50dropbear`、`K50dropbear` → `../init.d/dropbear`

## 还原

```sh
sh /userdisk/data/dropbear-state/backup-dropbear-v2011.54/restore.sh
```

脚本会：先停掉 `dropbear.*.pid` 记录的所有实例 → 从备份覆盖 init/config/authorized_keys/两个 host key → `/etc/init.d/dropbear start` → 打印 22 归属。原厂二进制在只读 `/usr` 原位，从未被覆盖，无需写回。
