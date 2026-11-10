# WebDAV 全端点自检（2026-11-10）

对生产实例 `http://192.168.3.2:5005/` 做的路径 × 方法 × 认证 × 编码 × 边界实测。
所有写操作只发生在 `/本机储存/下载/.webdav-selftest-20261110/`，测完已删除（复查 404，
磁盘上无残留）；没有对任何共享根发过 `DELETE`。

## 结论

| 维度 | 结果 |
|---|---|
| 路径矩阵（2 根 + 8 子目录 + 外接盘、静态资源、不存在、隐藏、8 组穿越） | 全部符合预期；穿越与隐藏项 404，无目录外泄漏 |
| 方法矩阵（GET/HEAD/OPTIONS/PROPFIND 0-1-inf/PUT/DELETE/MKCOL/MOVE/COPY/LOCK/UNLOCK/PROPPATCH） | 除下表限制外全部通过 |
| 认证（无/错用户/错口令/空口令/正确） | 401 / 401 / 401 / 401 / 200；`WWW-Authenticate: Basic realm="r2d-webdav", charset="UTF-8"` |
| 编码（UTF-8、大小写百分号、200B 文件名、30 层 2.8KB 路径、`%E4%`、`%FF`） | 正常编码全部可用；截断编码 404、非法 UTF-8 400 |
| 客户端序列（Finder `WebDAVLib/1.3`、资源管理器 `MiniRedir`、`Translate: f`、LOCK） | 全部 200/207，LOCK 200 + token，UNLOCK 204 |
| 并发（20×GET、10×PROPFIND、5×PUT） | 全 200/207/201，无 5xx |
| 边界（0B、5MB、只读根、bind mount 摘除） | 见下 |

## 自检发现并已修的问题

1. **`/__ui/` 返回英文目录列表**（`GET 200`，lighttpd `Index of /__ui/`）。
   修：`$HTTP["url"] == "/__ui/" { dir-listing.activate = "disable" }`，现在 403；
   `app.css` / `app.js` / `listing-shim.js` 不受影响（仍 200）。见 `stageA-fix.txt`。
2. **`外接盘` 根可写**（`PUT /外接盘/x.txt` 返回 201 并真的落盘）。原因：`外接盘` 是
   bind mount，根权限来自 vfat（恒 777），`run.sh` 挂载前的 `chmod 555` 不生效；
   一次误 `DELETE /外接盘/` 会递归清空整块盘。
   修：`$HTTP["url"] == "/%E5%A4%96%E6%8E%A5%E7%9B%98/" { webdav.is-readonly = "enable" }`，
   只封集合本身。现在 `PUT /外接盘/` 400；子路径不受影响（`PUT /外接盘/t.txt` 201、
   `MKCOL` 201、`DELETE` 子项 204、`PROPFIND` 207）。测试文件已删除。

两处修复都已 `lighttpd -t` 校验后部署并 `run.sh restart`，配置备份
`conf/lighttpd.conf.bak-20261110-selfcheck`。

## 仍然存在的限制（不改）

- `PROPFIND Depth: infinity` 与 `Depth: 2` 都返回 403：`mod_webdav` 不支持无限深度。
  Finder / 资源管理器只用 `Depth: 0/1`，不影响挂载。
- `PROPPATCH` 返回 204，但属性不持久化（`displayname` 回读为空）：属于 `mod_webdav`
  未实现 dead property。设置显示名请改文件名。
- `PROPFIND /__ui/*` 返回 404：`mod_webdav` 按 docroot 解析，不经过 alias；客户端不会
  对这些资源发 PROPFIND。
- 只读根的写入状态码不统一：`PUT /本机储存/x.txt` 500（`mod_webdav` 错误映射）、
  `MKCOL` 403、`PUT /x.txt`（根）500、`PUT /` 400。功能上都被拒。
- 无 TLS，Basic 口令在局域网明文传输（既有约束，未变）。

## 文件

| 文件 | 内容 |
|---|---|
| `stageA.txt` | 路径矩阵（修复前，`/__ui/` 还是 200 英文列表） |
| `stageA-fix.txt` | 修复后复查（`/__ui/` 403，其余不变） |
| `stageA2.txt` | 特殊字符/长名夹具创建日志（后半段 `timeout` 参数写错，噪声行保留） |
| `stageA2b.txt` | 夹具读取校验、Depth 1 href 编码、未编码特殊字符行为 |
| `stageB.txt` | 方法矩阵 |
| `stageC.txt` | 认证、编码、PROPPATCH、Finder/资源管理器请求序列 |
| `stageC-longpath.txt` | 30 层、2.8KB URL 路径的增量创建与读取 |
| `stageD.txt` | 并发、只读根、bind mount 摘除与 29 秒自动重绑 |

## 复现

脚本只在设备上执行过（`/tmp/webdav-stage*.sh`，未入库），凭据从
`conf/users.basic` 就地读取、不落地。设备侧副本：
`/userdisk/data/.yunshu/evidence/webdav-ui-20261110/selfcheck/`。
