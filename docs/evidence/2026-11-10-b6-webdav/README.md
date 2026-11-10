# 2026-11-10 B6 WebDAV 生产上线证据

对应决策：`docs/decisions.md` S16（D-S16-01…08）与 S17（403 修复、Digest→Basic）。

| 文件 | 内容 |
|---|---|
| `pre-reboot.txt` | 首次冷启动前的基线：服务状态、22/139/445/5005 监听、`current` 指向、`S99webdav` 链接 |
| `post-coldboot.txt` | 冷启动后核对：WebDAV 状态、TCP/UDP 监听、`homes=0`、`s8-diskacl` 计数、无测试残留 |
| `client-mac.txt` | 从用户 Mac 用 curl 实测：未认证 401、根目录只列 4 个共享、PUT/GET/MOVE/MKCOL/DELETE、`.dev` 404 |
| `finder-probe.txt` | 403 定位证据：临时开 accesslog 抓到 Finder `WebDAVLib/1.3` 只发一次 `OPTIONS /` → Digest 401 不重试 |
| `client-fix-matrix.txt` | 403 修复后的完整矩阵：未认证 401、`GET /` 200 四目录、子目录 200、PROPFIND 207、OPTIONS 200、`.dev` 404、PUT/GET/DELETE |

设备侧原始证据在 `/userdisk/data/.dev/evidence/webdav-20261110/`。

事故记录：验证共享根 DELETE 语义时误删 `共享/文件共享说明.jpg`，已从固件原件
`usr/share/datacenter/文件共享说明.jpg` 恢复，md5 `adaaf63f0e57d8ba4ae23f987333cf4b`，
详见 D-S16-07。
