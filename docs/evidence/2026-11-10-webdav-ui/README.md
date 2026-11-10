# 2026-11-10 WebDAV 中文界面

对应代码：[`recipes/webdav/`](../../../recipes/webdav/)（`lighttpd.conf`、`ui/`）。
生产实例：`192.168.3.2:5005`，docroot `live/webdav/webroot`，仍由降权后的 `nobody:nogroup` 运行。

## 结论

- `GET http://192.168.3.2:5005/` 返回中文静态单页（`<title>文件浏览</title>`），
  根目录只列 `本机储存` / `外接盘`，带目录图标、面包屑、`返回上级`、`共 N 项`。
- 目录内容由页面同源 `PROPFIND` 读取并渲染；`PROPFIND` / `PUT` / `GET` / `MOVE` /
  `MKCOL` / `DELETE` / `OPTIONS` 仍由 `mod_webdav` 处理，认证仍是原 Basic，端口与
  bind mount 结构未改。
- `.yunshu`、`.dev` 仍为 404，且不出现在根列表。
- 底部连接提示按客户端只显示一条（macOS / Windows / 其他），不再对所有平台都写「访达 ⌘K」。
- 深层目录（地址栏直接输入 `/本机储存/下载/`）由 `mod_dirlisting` 生成后，
  `listing-shim.js` 立即转到 `/?p=...`，用户看到的是同一套中文界面。

## 为什么做成「静态单页 + PROPFIND」而不是服务端渲染

设备上的 lighttpd 1.4.85 **编译时没有 PCRE**（`-t` 校验会报
`compiled without pcre support`），因此：

- `url.rewrite-once` / 正则 `$HTTP[...] =~` 全部不可用，无法把「任意目录的 GET」
  分发给 `mod_cgi`（`mod_cgi` 本身存在，但只能按扩展名匹配物理文件）。
- `mod_dirlisting` 的标题、`Parent Directory` 等字符串硬编码在模块里，没有 i18n 开关；
  `dir-listing.external-css` / `external-js` 只能改样式和 DOM，改不了源 HTML 里的英文。
- `mod_indexfile` / `mod_alias` / `mod_staticfile` 是**静态编译**进二进制的，
  所以可以用「`GET /` 时切 docroot 到 ui 目录 + index-file」和「`/__ui/` alias」
  来交付静态页面，零新依赖、零新进程。

代价（已知限制）：

- 列表由浏览器 JS 请求 PROPFIND 后渲染；禁用 JS 时 `/` 仍是中文静态页但没有条目，
  深层目录会落到 lighttpd 自带英文列表页（可正常浏览/下载，只是英文）。
- `curl` 直接抓 `GET /` 得到的是静态页 HTML（中文），条目需要看 `PROPFIND` 响应。

## 证据

### 生产实例（curl，设备内执行，凭据只从 `conf/users.basic` 读入）

[`prod-matrix.txt`](prod-matrix.txt) 记录了：

| 项 | 结果 |
|---|---|
| 未认证 `GET /` | 401，`WWW-Authenticate: Basic realm="r2d-webdav"` |
| 认证 `GET /` | 200，`<title>文件浏览</title>` |
| `/__ui/app.css` / `app.js` / `listing-shim.js` | 200，`text/css` / `text/javascript` |
| `GET /本机储存/`（深层兜底页） | 200，含 `/__ui/listing-shim.js` 与 `/__ui/app.css` |
| `PROPFIND /` | 207，恰好 `/`、`/外接盘/`、`/本机储存/` |
| `PROPFIND /本机储存/` | 207，8 个子目录 |
| `GET /.yunshu/`、`/.dev/` | 404 |
| `PUT` → `GET` → `DELETE`（临时文件） | 201 / 200 / 204，内容一致，已清理 |
| `OPTIONS /` | 200，`DAV: 1,2,3` |
| 部署文件 md5 | 与仓库 `recipes/webdav/ui/` 完全一致（见文末） |

### 界面截图（同机隔离实例，非 5005）

生产页面需要 Basic 口令才能渲染，凭据导出到工作站被安全策略拒绝；因此截图在**同一台
R2D、同一 lighttpd 二进制、同一份 UI 字节**的隔离实例（`192.168.3.2:18086`，
独立 docroot/state，测试账号）上采集。目录结构按生产顶层目录（`下载`/`共享`/`图片`/
`文档`/`摄像机监控视频`/`数学`/`文件`/`照片视频`）布置，文件为占位数据，避免暴露真实内容。

| 文件 | 视口 | 主题 | 说明 |
|---|---|---|---|
| `ui-light-root.png` | 1280×900 | 浅色 | 根目录，两个入口 |
| `ui-light-sub.png` | 1280×900 | 浅色 | 本机储存，`返回上级` + 8 个目录 |
| `ui-light-deep.png` | 1280×900 | 浅色 | 下载，文件大小/修改时间/类型图标 |
| `ui-dark-root.png` | 1280×900 | 深色 | 根目录 |
| `ui-dark-deep.png` | 1280×900 | 深色 | 下载 |
| `ui-mobile-light.png` | 390×844 | 浅色 | 窄屏单列，名称/大小/时间两行不溢出 |
| `ui-mobile-dark.png` | 390×844 | 深色 | 窄屏深色 |
| `ui-tablet-light.png` | 768×1024 | 浅色 | 平板宽度 |

自动化检查（Playwright + 同机 Chromium）：8 个场景均无 console error，
`document.documentElement.scrollWidth == clientWidth`（无横向溢出），
页面正文不含 `Index of` / `Directory listing` / `Parent Directory`。

截图完成后隔离实例（18086）与占位数据已全部删除，设备上只保留生产实例 5005 与
`/userdisk/data/.yunshu/evidence/webdav-ui-20261110/`（`prod-matrix.txt` + `NOTE.txt`）。

### 客户端提示（2026-11-10 增补）

页面底部只渲染与当前 UA 匹配的一条提示（`hint-mac.png` / `hint-win.png` /
`hint-android.png`）：

| 客户端 | 文案 |
|---|---|
| macOS | 上传、改名、删除：访达按 ⌘K → 输入 `<origin>` → 用当前账号密码连接。 |
| Windows | 上传、改名、删除：资源管理器 →「映射网络驱动器」→ 输入 `<origin>`，提示时选「使用其他凭据」重填一次密码。<br>（附注）Windows 自带客户端对 http + Basic 支持有限，连不上可改用第三方 WebDAV 客户端。 |
| 手机 / 平板 / Linux | 可在浏览器里直接浏览和下载；需要上传、改名、删除时，用任意 WebDAV 客户端连接 `<origin>`。 |

iPadOS 的 UA 含 `Macintosh`，判断时先排除 `iPhone|iPad|iPod|Android`，否则会把「访达」
显示给 iPad。三张截图来自本地静态 harness（同一份 UI 字节 + 固定 PROPFIND 响应，
地址显示为 `127.0.0.1:18099`），逐条文案见 `client-hint-harness.json`；三个场景均
`overflow=0`、无 console error、正文不含三个英文串。

生产侧只替换了静态文件、未重启：`client-hint-prod.txt` 显示 `GET /` 200（1490B）、
`GET /__ui/app.js` 200（11539B，含 UA 分支）、`PROPFIND /` 仍 207，md5 与仓库一致。

## 复现

```sh
# 生产侧（在设备上执行，凭据不落盘到工作站）
D=/userdisk/data/.yunshu/live/webdav
U=$(awk -F: 'NR==1{print $1}' $D/conf/users.basic)
P=$(awk -F: 'NR==1{print $2}' $D/conf/users.basic)
curl -s -u "$U:$P" http://192.168.3.2:5005/ | head
curl -s -u "$U:$P" -X PROPFIND -H 'Depth: 1' -H 'Content-Type: application/xml' \
  --data '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>' \
  http://192.168.3.2:5005/
```

## 部署文件 md5

```
454a6c650852c855b722408ddd172487  index.html
db97cec8dcfe2e2b3e1f13f95f6658a1  app.css
7cb594152580bfbd036c2c1812341b95  app.js
ec54533432f94796f99ffca683d58718  listing-shim.js
```

## 回退

```sh
D=/userdisk/data/.yunshu/live/webdav
cp -a $D/conf/lighttpd.conf.bak-20261110-webdav-ui $D/conf/lighttpd.conf
mv $D/ui $D/ui.disabled        # 或直接删除
$D/run.sh restart
```

回退只影响界面层：`webroot`、bind mount、`users.basic`、`umask`、降权用户均未改动。
