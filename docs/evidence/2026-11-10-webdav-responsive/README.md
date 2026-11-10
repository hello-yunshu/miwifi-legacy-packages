# 2026-11-10 WebDAV 单页界面响应式验证

对象：`recipes/webdav/ui/`（`index.html` + `app.css` + `app.js` + `listing-shim.js`），
部署后 `http://192.168.3.2:5005/` 与深层目录（listing-shim 接管）。

方法：Playwright（`playwright-core` + 缓存的 chromium headless shell，真实浏览器引擎）
按给定 CSS 视口宽度与 `colorScheme` 打开页面，读取 `documentElement.scrollWidth` /
`clientWidth`、各元素 `getBoundingClientRect()`、`scrollWidth > clientWidth` 判定文本截断，
并截图。生产环境用 `httpCredentials` 走 Basic 认证；界面文件的本地副本与设备上的
md5 一致（`app.css c97daede…`、`app.js 7cb59415…`、`index.html 454a6c65…`、
`listing-shim.js ec545334…`），因此本地 harness 与生产渲染同源。

## 本轮修复

1. **面包屑当前段在窄屏折成两行**：`.crumbs .current` 原只有 `padding`，长中文目录名
   （如 `摄像机监控视频-2026年11月10日晚间备份归档`）会整段换行，既与下方面板标题重复，
   又把面包屑撑到 75px 高。改为 `min-width:0; max-width:100%; overflow:hidden;
   text-overflow:ellipsis; white-space:nowrap`，单行省略。
2. **面包屑点击目标偏小**：链接高度原为 25px。基准 `padding` 改为 `5px 6px`（31px），
   `≤640px` 时 `6px 7px`（33px）。

## 生产实测（浅色；深色数值一致）

| 视口 | scrollWidth/clientWidth | 横向溢出 | 面板右边界 | 行高 | 面包屑链接高 | 提示块行数 | 长文件名截断 |
|---|---|---|---|---|---|---|---|
| 320 | 320/320 | 0 | 304 | 63 | 33 | 3 | 0/2 |
| 390 | 390/390 | 0 | 374 | 63 | 33 | 2 | 0/2 |
| 768 | 768/768 | 0 | 748 | 56 | 31 | 1 | 0/2 |
| 1024 | 1024/1024 | 0 | 932 | 56 | 31 | 1 | 0/2 |
| 1440 | 1440/1440 | 0 | 1140 | 56 | 31 | 1 | 0/2 |
| 1920 | 1920/1920 | 0 | 1380 | 56 | 31 | 1 | 0/2 |

本地 19 档矩阵（含缩放等效档：1920@125%→1536、1920@150%→1280、1440@125%→1152、
1440@150%→960、1280@150%→853、1024@125%→819、1024@150%→683、390@125%→312）：
明暗共 38 例，全部 `scrollWidth == clientWidth`、无越界元素、无标题/计数重叠、
无 console 错误（`report.json`，`cases=41 flagged=0` 含 3 个深层例）。

长目录标题页（`/本机储存/摄像机监控视频-2026年11月10日晚间备份归档/`）：
320 下面包屑当前段 `clientWidth/scrollWidth = 288/308`，单行省略；390 起 `308/308` 完整。
面包屑整体高度 68px（≤480，两行）与 31px（≥768）。

深层目录（`/本机储存/下载/`）：390 下经 `listing-shim.js` 转跳到
`/?p=%2F%E6%9C%AC%E6%9C%BA%E5%82%A8%E5%AD%98%2F%E4%B8%8B%E8%BD%BD%2F`，
面包屑「根目录 / 本机储存 / 下载」，横向溢出 0，9 个条目中 2 个长名省略。

中文提示块（整段文案）：
- macOS：320 三行、340–480 两行、≥768 一行（`hint-mac.txt`）；
- Windows（含一行弱化说明）：320–390 五行、480 四行、768 三行、1024 两行，
  各档 `overflow = 0`（`hint-win.txt`、`prod-win-320-light.png`）。

## 已知与未改

- 320/390 下面包屑三段放不下一行，当前段落到第二行；这是正常换行，段内已单行省略，
  没有为了压成一行而隐藏上级路径。
- 列表与提示块之间没有额外外边距（`gap = 0`），视觉上靠 1px 分隔线与 12/13px 内边距
  区分，截图确认不塌陷。
- 触屏点击目标 31/33px，仍低于 44px 的无障碍建议值；面包屑是次级导航，继续放大
  会明显挤压内容，故未再加大。列表行 56/63px，满足点击需求。
- 未覆盖真实 iOS Safari / Android WebView 的地址栏收缩（`100vh` 未使用，页面高度
  自适应，无固定底栏，风险低）；也未做 RTL 与超长英文单词的额外验证。

## 文件

| 文件 | 内容 |
|---|---|
| `prod-report.json` | 生产 6 档 × 明暗 + 深层 390 × 明暗的实测与截图对应关系 |
| `prod-root-{320,390,768,1440}-{light,dark}.png` | 生产截图 |
| `prod-deep-390-{light,dark}.png` | 深层目录经 shim 转跳后的生产截图 |
| `prod-win-320-light.png` | Windows 文案在 320 下的生产截图 |
| `report.json` / `report2.json` | 本地 19 档 × 明暗 + 深层 + 长标题页的逐例测量 |
| `crumb.json` | 长目录名面包屑在 320–1440 的宽度/行数/截断 |
| `hint-mac.txt` / `hint-win.txt` | 提示块行数与溢出（按内容高度剔除内边距计算） |
| `longtitle-{320-light,390-dark}.png` | 长目录名页面截图 |

测量脚本为临时文件（`/tmp/pwshot/`），未入库；生产复现要点：Playwright
`browser.newContext({ viewport: { width }, colorScheme, userAgent, httpCredentials })`，
打开 `http://192.168.3.2:5005/`，等待 `.entry` 后读取上述数值。
