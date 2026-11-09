# 系统 OpenSSL 为什么不在升级范围（2026-11-10 只读审计）

- 设备：MiWiFi R2D / 固件 2.25.209 / 192.168.3.2
- 方法：只读采集（读文件、`strings`、`/proc/<pid>/maps`、`netstat`、`iptables -S`、一次 TLS 握手探测）。未改任何配置、未安装任何包。
- 结论：**未列入八项候选，且在现有固件结构下无法安全升级 → BLOCKED（范围外），不是 PASS。**

## 1. 设备上现在是什么

设备**没有 `openssl` 命令行**（`openssl: not found`），只有运行库：

| 文件 | 大小 | md5 | 说明 |
|---|---|---|---|
| `/usr/lib/libssl.so.1.0.0` | 283 556 B | `516967d69b2d863454b0a10559673f46` | OpenSSL 的 SSL/TLS 层 |
| `/usr/lib/libcrypto.so.1.0.0` | 1 161 268 B | `e78a6c80861b942326a9eff8089ad556` | OpenSSL 的密码学层 |
| `/usr/lib/libcrypto++.so.8.0.0` | 4 024 212 B | 未计 | **Crypto++ 8.0，与 OpenSSL 无关**；只是名字相近，勿混为一谈 |

- 版本字符串（`strings /usr/lib/libssl.so.1.0.0 | grep "OpenSSL [0-9]"`）：`OpenSSL 1.0.1j 15 Oct 2014`，`libcrypto.so.1.0.0` 同为 1.0.1j。
- 只有 soname，**没有开发用软链**：`/usr/lib/libssl.so`、`/usr/lib/libcrypto.so` 均不存在。这表示固件只带运行时，不带头文件与链接入口。
- `/usr/lib` 下没有第二份 OpenSSL；`/userdisk/data` 下也没有私有 OpenSSL 树（`ls -d /userdisk/data/*openssl*` 为空）。

`/` 的挂载事实：

```
rootfs on / type rootfs (rw)
/dev/ubi1_0 on / type ubifs (ro,noatime,bulk_read,no_chk_data_crc,compr=none)
```

即根文件系统是**只读 ubifs**；可用空间 20.1 MB（107.9 MB 中已用 87.7 MB，81%）。

## 2. 谁在依赖它

### 2.1 静态扫描：18 个对象引用 `libssl.so.1.0.0`

对 `/usr/bin`、`/usr/sbin`、`/usr/lib` 逐个做 `strings` 匹配，命中：

```
/usr/bin/hiapk2
/usr/sbin/copy_plugin_chroot_file
/usr/sbin/datacenter
/usr/sbin/getedgeparam
/usr/sbin/indexservice
/usr/sbin/installplugin
/usr/sbin/mediaservice
/usr/sbin/pluginControllor
/usr/sbin/plugin_action
/usr/sbin/plugin_download
/usr/sbin/plugincenter
/usr/sbin/shareUpdate
/usr/sbin/sysapihttpd
/usr/lib/libcloudengine.so
/usr/lib/libssl.so.1.0.0        （自引用）
/usr/lib/libthrift-0.9.1.so
/usr/lib/libthriftnb-0.9.1.so
/usr/lib/libthriftz-0.9.1.so
```

其中除 `libssl` 自身外，**17 个都是厂商闭源二进制或厂商私有库**（插件中心、数据中心、媒体服务、索引、分享、管理 Web 守护进程、Thrift 传输）。

### 2.2 运行时确认：只有 `sysapihttpd` 实际加载

读 `/proc/<pid>/maps`（设备无 `ldd`，所以用 maps 而不是 ldd）：

| 进程 | 是否加载 libssl/libcrypto |
|---|---|
| `sysapihttpd`（5757/5758/5759/5857/5879/5880，共 6 个） | **是**，同时加载 `libssl.so.1.0.0` 与 `libcrypto.so.1.0.0` |
| `dropbear`（6137 监听 + 会话子进程） | 否（自带密码学实现） |
| `nmbd`（11680） | 否 |

### 2.3 关键组件的 TLS 后端

| 组件 | 实际后端 | 是否受系统 OpenSSL 影响 |
|---|---|---|
| Dropbear 2011.54（`/usr/sbin/dropbear`） | 自带 crypto，无 libssl 依赖 | 否 |
| Dropbear 2026.94（B1 候选） | 自带 crypto，无 libssl 依赖 | 否 |
| `curl` 7.33.0 | `curl -V`：`PolarSSL/1.3.16` | 否（独立 TLS 库） |
| `wget`（BusyBox 1.19.4 applet） | 无 libssl 引用 | 否 |
| `sysapihttpd`（80/8443） | `libssl.so.1.0.0` | **是** |
| `perl` | 无 SSL 相关动态依赖 | 否 |

`opkg` 存在（`/bin/opkg` + `/etc/opkg.conf`），但 `opkg list-installed | grep -iE "ssl|crypto"` 为空——**OpenSSL 不是以 opkg 包形式管理的**，而是固化在固件 rootfs 里，因此也没有“升级一个包”的路径。

## 3. 为什么它不在升级范围（原文依据）

计划 §3「不纳入本轮的系统组件」把 OpenSSL 与内核、uClibc、BusyBox 并列，原文：

> | OpenSSL 1.0.1j（8443 实际加载） | 被 `sysapihttpd` 加载；设备无 `openssl` CLI。私有 OpenSSL 只保护新工具，不修复 8443 | 厂商支持的 TLS 配置审计结论；未证明不影响 App 前不改 `sysapihttpd` |

同时 §2.3（B1）写明：Dropbear「不必替换系统 OpenSSL（Dropbear 不链接它）」。

所以准确回答是：**从来没有列进八项候选**（A0、A1、B1–B6 里没有 OpenSSL），在排期逻辑的第一层——§3 系统级组件——就被排除，理由是「唯一的实际消费者是厂商闭源管理守护进程，私有库换不掉它」。不是“列过、后来判不可行”，而是**在系统组件层面被判定为不可单包替换**。`decisions.md` 此前没有针对 OpenSSL 的独立决策条目，本次补记为 D-S13-02。

## 4. 如果要升，卡在哪

| 卡点 | 实证 | 影响 |
|---|---|---|
| 根分区只读 | `/dev/ubi1_0 on / type ubifs (ro,…)`；so 文件在 `/usr/lib` | 不能原地替换；remount rw 属写 flash，固件升级会覆盖，且失败可能无法启动 |
| ABI/soname 锁定 | 依赖名是 `libssl.so.1.0.0` / `libcrypto.so.1.0.0`；OpenSSL 1.1.0 起 soname 改为 `libssl.so.1.1`，3.x 为 `.so.3` | 升到 1.1/3.x 会让 17 个厂商消费者全部加载失败，首当其冲是管理 Web（80/8443） |
| 厂商二进制闭源 | 17 个引用者均为厂商 ELF/私有库；无源码、无 opkg 依赖记录 | 无法重编、无法重链接；只能“同 soname 换库”赌 ABI 完全兼容 |
| 同 ABI 的选择也过期 | 1.0.x 最后一版是 1.0.2u（2019-12 EOL） | 换上去仍是 EOL 库，安全收益有限，反而引入未验证的厂商二进制兼容风险 |
| 静态链接组件需整体重编 | 本次扫描未发现用 OpenSSL 静态链接的关键组件（curl 用 PolarSSL、Dropbear 自带 crypto），但厂商闭源程序内部是否静态包含 1.0.1j 无法排除 | 无法给出“只换库就干净”的结论 |
| flash 余量 | 根分区剩 20.1 MB | 1.0.2u 的两个库约 2–3 MB，体积本身不是硬阻断；硬阻断是只读与 ABI |
| 私有 OpenSSL 的边界 | 计划 §3 已写明“私有 OpenSSL 只保护新工具，不修复 8443” | 放 `/userdisk/data` 只对自建工具有效，管不了 `sysapihttpd` |

## 5. 风险判断

- **版本暴露面**：1.0.1j 发布于 2014-10，1.0.1 分支最终版为 1.0.1u（2016-09）。按公开发布公告，1.0.1j 之后修复过的问题包括 FREAK（CVE-2015-0204）、CVE-2015-0286/0287、CVE-2015-1793、DROWN（CVE-2016-0800）、CVE-2016-2105–2109、CVE-2016-6304、CVE-2016-7055、CVE-2017-3731/3732 等。本节按公告归纳，未逐条在设备上复现。
- **实际可达面**：只有 `sysapihttpd`。`netstat` 显示 `0.0.0.0:80` 与 `0.0.0.0:8443` 由其监听；8443 实测可以完成 **TLSv1.2** 握手，证书为自签名（`Verify return code: 18`）。
- **是否暴露到公网**：没有证据。设备自身在 `192.168.3.0/24` 内为 `192.168.3.2`，上游网关是 `192.168.3.1`；`iptables -S` 里没有 8443 的显式规则，INPUT 默认策略为 ACCEPT，另有一条 `mixbox-firewall` 对 `22,80,135:139,445` 的 ACCEPT。是否存在端口转发取决于上游路由器，本次未登录上游，不下结论。
- **判定**：这是**已知的、被接受的局域网侧风险**，不是“该尽快排”的 P0，也不是“已解决”。它的正确状态是 **BLOCKED（范围外）**：唯一消费者是闭源管理守护进程，修复等价于替换厂商管理栈（§3 的 `sysapihttpd`/nginx 一并排除）。
- **可做的低成本动作**（不改固件）：不要把 80/8443 端口转发到公网；管理口令保持强口令；如需访问管理面，走内网或 SSH 隧道。B1 接管 22 之后，SSH 隧道是最实际的替代路径。

## 6. 复现命令

```sh
# 版本与文件
openssl version 2>&1                      # -> not found
ls -l /usr/lib/libssl* /usr/lib/libcrypto*
md5sum /usr/lib/libssl.so* /usr/lib/libcrypto.so*
strings /usr/lib/libssl.so.1.0.0 | grep -m3 "OpenSSL [0-9]"

# 依赖面（设备无 ldd）
for d in /usr/bin /usr/sbin /usr/lib; do for f in $d/*; do \
  [ -f "$f" ] && grep -q "libssl.so.1.0.0" "$f" 2>/dev/null && echo "$f"; done; done
for p in $(pidof sysapihttpd); do grep -E "libssl|libcrypto" /proc/$p/maps; done

# 挂载与空间
mount | grep -E " on / "
df -h /
```
