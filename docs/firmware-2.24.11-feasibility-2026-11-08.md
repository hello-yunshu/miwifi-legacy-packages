# 升级到 2.24.11 的离线可行性摸底（保留 SMB compat 现状）

- 设备：MiWiFi-R2D（`root@192.168.3.2`），当前固件 `2.25.209`，compat 层 `1.0.3-r2d`
- 方式：**纯离线**。只下载官方包、拆包、读固件内脚本；**未登录设备、未刷机、未重启、未改任何配置**
- 时间：2026-11-08
- 证据分级：`[实测]` 本机下载/计算/解包验证 ｜ `[脚本]` 固件包内脚本原文 ｜ `[推断]` 由证据推出、未直接验证 ｜ `[未证实]` 无法离线确认

---

## 一、结论先行

1. **不建议做；在"完整保住现状"这个前提下，结论是不可行。** 卡点在一条硬约束上：**`2.24.11` 的 rootfs 里根本没有 SSH 服务端**（无 `dropbear`、无 `sshd`、无 OpenSSH 客户端），而 OTA 会把 rootfs 整块换掉、并删掉持久 `/etc` 里的 `init.d/rc.d`。升级完成后设备既没有 SSH，也没有任何能自动拉起自装件的持久钩子，**而重装 compat 层依赖 SSH**。这不是"麻烦一点"，是自我锁死。
2. **这不是升级，是跨分支的版本号倒挂（横跳/降级）**：`2.24.11 < 2.25.209`，但 `2.24.11` 的构建时间是 2023-03-13、`2.25.209` 是 2018-10-16。两个包的 channel 也不同（`release` vs `stable`）。
3. **两版核心组件几乎同代同版，换过去没有技术收益**：内核同为 Linux `2.6.36`（同 `#3`、同 GCC 4.8.2）、`ld-uClibc-0.9.33.2.so` **字节完全相同**、BusyBox `1.19.4`、OpenSSL `1.0.1j`、Samba `4.0.21`、nginx `1.2.2`、dnsmasq `2.71`。差异主要在"本地工具集被砍"和"云端特性被加"。
4. **分区动作是安全的（对数据而言）**：升级只重写**非当前运行槽**的内核分区与 rootfs 分区（本机运行在 `ubi1_0` → 写 `mtd5` + `mtd8`），不碰 CFE、不碰 `/data`（`mtd10`/`ubi2_0`）、不碰内置硬盘 `/dev/sda1`。`/userdisk/data` 上的 `s7root`、`s8compat`、`samba-s2`、`s8-usb-test` 与硬盘数据都在。
5. **但 `/etc` 会被"半重置"**：`/etc` 虽在 `mtd10` 上、不被格式化，升级后首次启动的 `remove.conf` 会删掉 `/data/etc/init.d`、`rc.d`、`hotplug.d`、`crontabs`、`modules.d` 及一批 config，再从新 rootfs 覆盖。**compat 的 init 包装器、`90-s8-mounts` 钩子必丢**；`/etc/config/samba`（共享定义）保住。
   - 直接后果：升级后 139/445 会**退回原厂 `samba_multicall` 4.0.21**（compat 的 4.25.1 因包装器被删而不会启动）——SMB 服务本身也"降级"了。
6. **回退 2.25.209 的"素材"是完整的**：官方包仍可下载、签名有效、当前槽不会被覆盖。但"刷完能不能启动新槽、以及能不能自动退回"由 CFE 决定，rootfs 脚本里查不到写入点，`[未证实]`。

---

## 二、固件包取证与校验

### 2.1 来源与完整性（`[实测]`）

| 项目 | 2.24.11 | 2.25.209（对照） |
|---|---|---|
| 来源 URL | `http://cdn.cnbj1.fds.api.mi-img.com/xiaoqiang/rom/r2d/brcm4709_r2d_all_1148b_2.24.11.bin` | `http://bigota.miwifi.com/xiaoqiang/rom/r2d/brcm4709_r2d_all_ba6b5_2.25.209.bin` |
| HTTP | `200 OK` | `200 OK` |
| 大小 | **37,492,824 B**（35.76 MB） | **36,068,576 B**（34.40 MB） |
| SHA-256 | `852a1116b8475c6a27cbb6d547c78859fc9007d30bfcbb867591f099f626b996` | `cf4f7a2e77f52e9e2c465d652daeffcc3b1fc8d72fa9fff8ac1a386fa853c0bc` |
| MD5（与 CDN `ETag` 一致） | `139c77f2c25a89e6f40970edf891148b` | `b39a23a6f1dae065f1166e8cc1dba6b5` |
| CDN `Last-Modified` | `Thu, 30 Mar 2023 15:26:51 GMT` | `Thu, 30 Mar 2023 15:27:24 GMT` |
| 包内 `BUILDTIME` | 2023-03-13 | 2018-10-16 |
| 包内 `CHANNEL` / `HARDWARE` | `release` / `R2D` | `stable` / `R2D` |

> 注意两点：① `2.25.209` 的 CDN 包也是 2023-03-30 重传的，别把 CDN 时间当成固件发布日期；② 两包 `ETag` 就等于 MD5，可视为 CDN 侧的完整性声明，但**不等于签名**。

### 2.2 签名校验（`[实测]`）

- 包格式为小米私有 `HDR1` 容器：文件头 12 字节（`HDR1` + 签名块偏移 + `0x00040000`），随后是 48 字节段描述符 + 段数据；文件尾部固定 272 字节 = 16 字节头 + **256 字节 RSA-2048 签名**。
- 固件内的校验工具 `/usr/sbin/mkxqimage`（strings 可见 `EVP_VerifyFinal`、`MD5_*`、`public.pem`、`public_ssh.pem`、`Image verify failed`），升级入口 `bin/flash.sh` 调 `mkxqimage -v "$1"`。
- 用包内 `/usr/share/xiaoqiang/public.pem`（两包**同一把**公钥，SHA-256 `51b3828af2384a5076f94d074eb0e2a1eaf8c2cc137202b334f8e428f2881b4a`）直接验：

| 包 | 签名结果 | 覆盖范围 |
|---|---|---|
| 2.24.11 | **VALID**（RSA-2048 / PKCS#1 v1.5 / SHA-1） | 文件字节 `[0x0c, 0x23c1748)`，签名块起于 `0x23c1748` |
| 2.25.209 | **VALID**（同上） | 文件字节 `[0x0c, 0x2265bd0)`，签名块起于 `0x2265bd0` |

结论：**完整性、签名、机型三关都过**。包内三个段只有 `xiaoqiang_version`、`root.ubi.lzma`、`vmlinuz.trx`，**没有 `mice_cfe`**，即这两个包都不会刷 CFE/引导器。

> 机型说明：包只声明 `HARDWARE=R2D`、包名 `brcm4709_r2d`，没有单独的 "1TB" 标识。R2D 就是带 1TB SATA 硬盘的那款（本机 `/dev/sda1` 931.2 GB 可佐证）；官方只有 R2D 一条固件线，`R2DDEV/R2DSTA/R2DUSB` 是同一硬件的不同分支/刷机方式，不存在"拿错 1TB 版"的可能。

---

## 三、2.24.11 与 2.25.209 拆包比对

### 3.1 核心版本（`[实测]`，全部来自解包后的文件 itself）

| 组件 | 2.24.11 | 2.25.209 | 判断 |
|---|---|---|---|
| 内核 | `Linux 2.6.36 #3 MiWiFi-R2D-2.24.11`，GCC 4.8.2 / crosstool-NG 1.19.0，**2023-03-13 08:19:42 UTC** | `Linux 2.6.36 #3 MiWiFi-R2D-2.25.209`，同工具链，**2018-10-16 11:45:02 UTC** | 同 2.6.36，仅重建时间不同 |
| uClibc | `ld-uClibc-0.9.33.2.so`（SHA-256 `53c59c7a…`） | 同一文件，**字节相同** | ABI 完全一致 |
| BusyBox | 1.19.4 | 1.19.4 | 同版，二进制有重建差异 |
| OpenSSL | `libssl` 与 2.25.209 **字节相同**；`libcrypto` 同为 `1.0.1j 15 Oct 2014` | 1.0.1j | 无安全版本提升 |
| SSH 服务端 | **不存在**（无 `dropbear`/`sshd`） | Dropbear 2011.54 + OpenSSH 6.1p1 客户端 + `autossh` | **关键差异** |
| Samba | `samba_multicall` 4.0.21，软链布局 `nmbd/smbd/smbpasswd → samba_multicall` | 同版、同布局 | compat 层依赖的布局不变 |
| dnsmasq | 2.71 | 2.71 | 无变化 |
| nginx（`sysapihttpd`） | 1.2.2 | 1.2.2 | 无变化 |
| 内核模块 | 141 个 `.ko`，**文件名清单相同** | 141 个，清单相同 | `wl` 7.14.116、`tntfs/tfat/texfat` 同版（`tntfs` 等字节相同） |

### 3.2 文件级差异（`[实测]`，已排除 2.24.11 独有的 `usr/lib/opkg` 元数据 856 条）

- 同路径但内容不同：**983** 个文件（都是重建导致，版本号未变）
- 仅 2.24.11 有：**23** 个 —— `mifeed`、`tquery`、`guest_ssid_network`、`http_url_proxy`、`uaq` Lua 脚本、`libevent` 系列、`xqapp.apk` 等
- 仅 2.25.209 有：**123** 个 —— `dropbear`、`ssh/scp/dbclient`、`autossh`、`dig`、`iftop`、`mtr`、`screen`、`ss-server`、`tbus`、`himan2.sh`、`wrsst`、`syslog.conf`、`/etc/ssh/ssh_config`、`lib/upgrade/keep.d/dropbear` 等

> `[推断]` 两个 channel 的功能取向不同：2.24.11 更像"云端/国际向"的 release 构建（UAQ、mifeed、URL proxy），2.25.209 带更多本地运维工具（SSH、拨测、抓包、屏幕）。具体业务含义无法从离线包确认。

### 3.3 compat 层依赖的三处钩子（`[实测]`）

| 依赖点 | 2.24.11 是否支持 | 证据 |
|---|---|---|
| `/etc/hotplug.d/block` | **支持，且脚本相同** | 两个 rootfs 都有 `10-swap`、`20-fsck`、`40-mount`、`80-sambaAndDlna`；`40-mount`、`80-sambaAndDlna` diff 为空 |
| `samba_multicall` 布局 | **支持，完全相同** | 均为 `nmbd`/`smbd`/`smbpasswd` → `samba_multicall` 三个软链，4.0.21 |
| TaskMonitor 注册 | **支持，机制未变** | `taskmonitorTool`（9892 B）、`pluginTaskmonitor`（236268 B）两版同尺寸；`taskmonitorServer` 仅差 4 字节；注册走 `/tmp/taskmonitor/taskmonitor.conf`（运行时文件），由适配器启动时 `tm-register` 自动完成 |

**支持不等于保得住**：OTA 会把持久 `/etc` 里的 `hotplug.d`、`init.d` 整目录删掉（见第四节），钩子文件本身没了。

### 3.4 `/etc/init.d` 与 hotplug 机制差异（`[实测]`）

- 两版都有：`samba`、`taskmonitor`、`plugintaskmonitor.init`、`telnet`（`S40telnet`，且 `xiaoqiang-defaults` 里 `telnet_en=0`）
- 仅 2.25.209 有：`dropbear`、`autossh`、`himan2.sh`、`tbus`、`wrsst`
- `init.d/samba`：2.25.209 多了 `STOP=02`、cgroup `samba/tasks`、摄像头目录只读限制；函数接口（`updateconfig`/`start_impl`/`stop`/`reload`/`status`）两版都有，**compat 包装器可以照旧覆盖**
- `hotplug.d/block`：除上面两个完全相同的脚本外，机制（`hotplug2` 规则 + `40-mount`）无变化

---

## 四、升级脚本会动哪些分区（脚本级证据）

### 4.1 刷写流程（`[脚本]`，2.24.11 包内 `/bin/flash.sh` + `/bin/boardupgrade.sh`）

```
flash.sh:  mkxqimage -v "$1"   # RSA 验签 + MD5/CRC，失败即 "not formal image"
           pkg=...; echo $pkg > /tmp/update_pkg
           nvram set restore_defaults 2      # 正常升级；只有 recovery 才传 1
           ... /etc/init.d/... stop & reboot_safe.sh
           nvram set flag_ota_reboot 1
           /bin/boardupgrade.sh "$pkg"

boardupgrade.sh:
  mkxqimage -x $filename            # 解出 xiaoqiang_version / root.ubi.lzma / vmlinuz.trx
  /usr/sbin/config_backup.sh
  cat /proc/mounts | grep -q "/dev/ubi1_0 /" && part=1 || part=0
  [ -f mice_cfe ] && upboot          # 本包无 mice_cfe → 不刷 CFE
  [ -f vmlinuz.trx ] && upker        # part=1 → /dev/mtd5；否则 /dev/mtd6
  [ -f root.ubi.lzma ] && upfs_ubi   # part=1 → /dev/mtd8；否则 /dev/mtd9
```

`upfs_ubi()` 关键行：

```sh
unlzma -c root.ubi.lzma | ubiformat "$dev" -s 2048 -O 2048 -S "$len" -y -f -
...
rm -rf /data/etc_bak
cp -prf /etc /data/etc_bak      # 刷完把"当前运行中的旧 /etc"整份备份
```

`upker()` 是 `mtd write vmlinuz.trx /dev/mtd5`（失败再 `dd`），并用 `mtd verify` 复核。

### 4.2 本机的目标分区（`[推断]`，由设备现状 + 脚本常量推出）

设备当前根是 `/dev/ubi1_0`，因此 `part=1`，升级写的是：

| 分区 | 设备名（按 `/proc/mtd` 命名） | 动作 | 是否影响当前系统 |
|---|---|---|---|
| `mtd5` | `os0`（4 MB，内核槽 0） | `mtd write vmlinuz.trx` | 否（当前跑槽 1 的内核 `mtd6`） |
| `mtd8` | `rootfs0`（128 MB，根槽 0） | `ubiformat -y` 整块重写 | 否（当前跑 `mtd9`/`ubi1_0`） |
| `mtd10` | `overlay`（240 MB，`/data`=`ubi2_0`） | **不动** | — |
| `mtd0` | `boot`（CFE） | **不动**（包内无 `mice_cfe`） | — |
| `/dev/sda1` | 内置硬盘（931.2 GB，挂 `/userdisk/data`） | **不动** | — |

> 即：**A/B 双槽设计，永远写"另一个槽"**。当前 2.25.209 的内核+rootfs 不被覆盖，这是回退的最大资产。

### 4.3 `/etc` 会不会被重置（`[脚本]`，本轮最关键的证据）

`/etc` 不是 rootfs 的一部分：`lib/preinit/90_mount_bind_etc` 把 **`/data/etc` 绑定到 `/etc`**，而 `/data` 在 `mtd10`（`ubi2_0`）上，升级不格式化它。但 OTA 首次启动会走 `process_etc()` 的 `flag_ota_reboot=1` 分支 → `do_recovery_config()`：

```sh
cat /etc/remove.conf | xargs rm -rf      # 注意：清单里是绝对路径 /data/etc/...
echo N | cp -ri /etc/* /data/etc         # 用新 rootfs 的 /etc 补进来，已有文件一律回答 No
```

`/etc/remove.conf`（2.24.11 自带，共 142 行）明确删除：

- **目录级**：`/data/etc/init.d`、`/data/etc/rc.d`、`/data/etc/crontabs`、`/data/etc/hotplug.d`、`/data/etc/modules.d`
- **脚本/配置级**：`/data/etc/samba/smb.conf.template`、`/data/etc/samba/smb.conf`、`/data/etc/rc.local`、`/data/etc/profile`、`/data/etc/functions.sh`、`/data/etc/config/{system,misc,fstab,traffic,dropbear,features,module,push,peripheral,upnpd,noflushd,vas,soft_fast_path,ctf_mgr,uaq,http_url_proxy,turbo,miqos_default,firewall_default}` 等

**不在清单里、因此保住的**：`/etc/config/samba`、`/etc/config/network`、`/etc/config/wireless`、`/etc/config/dhcp`、`/etc/config/firewall`（以及 `/userdisk` 下的一切）。

结论：
- **共享定义保住**（`/etc/config/samba` 没被删）——Samba 的 share、用户、路径不会丢。
- **自装的启动接线必丢**：`/etc/init.d/samba`（compat 包装器）、`/etc/init.d/samba.vendor`、`/etc/hotplug.d/block/90-s8-mounts` 都在被删的目录里。
- **旧 `/etc` 有一份完整备份**：`upfs_ubi()` 刷完会把旧 `/etc` 拷到 `/data/etc_bak`（含 compat 接线），这是人工恢复的素材。

### 4.4 `/userdisk/data` 会不会被格式化（`[脚本]`，`lib/preinit/42_format_ext_part`）

- `/data`（`mtd10`）：只有 `nvram flag_format_disk3=1` 才 `mkfs`；该标志由 `restore_defaults=1`（恢复出厂）设置。`lib/preinit/31_restore_nvram` 明确：`restore=1`→恢复出厂（`nvram clear` + `flag_format_disk3=1`），`restore=2`→**OTA 升级**（只重刷 nvram 默认值，保留 `mode/vlan1ports/vlan2ports`，不动磁盘标志）。
- `/dev/sda1`（内置硬盘）：只有 `nvram flag_format_disk4=1` 才格式化；该标志只由 `format_userdisk`（网页"格式化硬盘"）设置。正常 OTA 为 `restore_defaults=2`，**不会格式化硬盘**。
- 另外：`/data` 挂载失败时会自动 `mkfs` 重建（异常路径，不是常态）。

**所以：`/userdisk/data/s7root`、`/userdisk/data/s8compat`、`/userdisk/data/samba-s2`、`/userdisk/data/s8-usb-test`、硬盘上的用户数据，正常 OTA 后都在。**

---

## 五、"保留现状"的真实成本

| 类别 | 内容 | 依据 |
|---|---|---|
| **能保住** | `/userdisk/data` 全部（compat 树、samba-s2、s8compat、s7root、s8-usb-test、用户数据）；`/etc/config/samba` 的共享定义；`/etc/config/network`、`wireless`、`dhcp`、`firewall`；`/data/etc_bak` 里的旧 `/etc` 快照 | 4.3 / 4.4 |
| **必然丢失** | Dropbear/OpenSSH/autossh/shadowsocks/dig/iftop/mtr/screen 等本地工具（rootfs 被整块替换）；`/etc/init.d/samba` 包装器、`samba.vendor`、`/etc/hotplug.d/block/90-s8-mounts`、任何自加 cron/init/modules.d；`/etc/samba/smb.conf*`、`/etc/config/misc` 等被 remove.conf 重置；**139/445 从 compat 4.25.1 退回原厂 4.0.21** | 3.1 / 3.2 / 4.3 |
| **需重做** | 1) 重装 compat 接线（`install.sh` 会重放 `samba` 包装器 + `samba.vendor` + `90-s8-mounts`，见仓库 `recipes/samba/s8-compat/install.sh`）；2) TaskMonitor 无需手工注册，包装器启动时适配器 `tm-register` 自动注册；3) 复核 `/etc/config/samba` 与共享 | 仓库脚本 + 固件脚本 |
| **工作量** | 顺利时约 10–15 分钟（4 个文件 + 一次 `install.sh` + 一次 SMB 验证）——**但这一步必须通过 SSH 执行** | — |

关键点：**"丢失清单"里包含 SSH 本身**，而"重做清单"又依赖 SSH。这就是成本从"十几分钟"变成"不可行"的原因。

---

## 六、三个问题，直接回答

### ① 这是"升级"还是"跨分支降级/横跳"？版本号反向会不会影响后续回退？

- **是跨分支、版本号倒挂的降级/横跳**。`2.24.11 < 2.25.209`；但 2.24.11 构建于 2023-03-13，比 2.25.209 的 2018-10-16 晚；channel 也不同（`release` / `stable`）。
- 网页上传路径会**显式识别降级**：`xqsystem.lua` 里 `result["downgrade"] = XQSysUtil.checkRomVersion(uploadFilepath)`（按版本号比较，当前版本更大即为 downgrade），前端 `sysinfo.js` 会带 `&downgrade=1` 跳提示页。也就是说**官方 UI 会警告，但不禁用**。
- **对后续回退的影响是"反向的"**：回 `2.25.209` 在数值上是"升级"，不会被降级逻辑拦。风险不在版本号比较，而在**引导器选槽**（见 ②）。

### ② 升级后还能不能回到 2.25.209？官方包与回退路径是否完整？

- **包层面完整**：`2.25.209` 官方 CDN 仍 200 可下（36,068,576 B，SHA-256 `cf4f7a2e…`），签名有效，`HARDWARE=R2D`，且**当前运行槽（`mtd9`/`ubi1_0`）不会被这次刷写覆盖**。
- **路径层面分两段**：
  1. 如果 2.24.11 能启动 → 网页 80 端口可用，直接上传 2.25.209 回刷（不需要 SSH）。**可行**。
  2. 如果 2.24.11 启动不起来 → 依赖 CFE 的失败回落（`flag_try_sys1_failed`/`sys2_failed` + `flag_last_success` + `/data/etc_bak` 机制）。`[未证实]`：这些标志的**读取**在 rootfs 脚本里能看到（`key_services_boot_check`），但**写入/选槽在 CFE**，离线包内看不到，无法证明一定回得来。
- **最坏分支**：两个槽都起不来 → 只能走 U 盘刷机（官方明确 U 盘刷机会**格式化硬盘**），`/userdisk/data` 与 compat 全没。这是唯一会丢数据的路径。

### ③ 在保住现状的前提下，值得做还是不如不动？

**不如不动。** 理由按重要性：

1. **没有收益**：内核/库/服务版本全部同代同版（2.6.36、uClibc 0.9.33.2、BusyBox 1.19.4、OpenSSL 1.0.1j、Samba 4.0.21）。`2.24.11` 的 2023 重建是否含安全补丁，`[无法确认]`——只能确认版本号没动。
2. **负收益**：丢掉 SSH 服务端与一整批本地工具；这正是你日常运维/compat 调试所依赖的。
3. **额外风险**：一次不可预期的选槽/回退（CFE 行为未证实），以及 `/etc` 半重置后需要"无 SSH 状态下重装接线"的死循环。

---

## 七、卡在哪条硬约束上

> **硬约束（唯一但致命）：`2.24.11` 的 rootfs 不含任何 SSH 服务端；而它的 OTA 会整块替换 rootfs、并删除持久 `/etc` 的 `init.d`/`rc.d`/`hotplug.d`。因此升级后"既没有 SSH 可用，也没有能自动拉起自装件的持久钩子"，而重装 compat 的唯一入口是 SSH。**

拆开看是三条同时成立：

1. **没有 SSH 二进制**：`2.24.11` 包内 `find` 不到任何 `dropbear`/`sshd`/`ssh`；`/etc/init.d/dropbear`、`/etc/config/dropbear`、`/etc/rc.d/S50dropbear` 也都没有（对照 `2.25.209` 全部存在）。
2. **持久钩子被清空**：`remove.conf` 精确删除 `/data/etc/init.d`、`/data/etc/rc.d`、`/data/etc/hotplug.d`、`/data/etc/crontabs`、`/data/etc/modules.d`；`/data/etc/rc.local`、`/data/etc/profile` 也在删除列表。
3. **兜底入口不可靠**：两版都自带 `S40telnet`（`telnetd -l /bin/login.sh`），但 `telnet_en=0`，且现有设备清点里没有 23 端口监听的记录（`[未证实]` 是否可用）；telnet 是明文、要 root 密码，不能作为"保住现状"的常规通道。

**要让它变成"可行"，至少需要先满足其一（都超出本次范围）：**

- 串口/CFE 带外控制台；或
- 在升级前把自备 SSH 服务端放到硬盘，并找到**能在 remove.conf 清洗后仍然自动执行**的持久入口（当前固件里 `/etc` 下几乎全部可执行钩子都在删除清单内，`/etc/config` 只存配置不执行）；或
- 接受"升级后只用网页 + 重新刷回 2.25.209"这一段无 SSH 窗口，并且能承担 CFE 不回落的尾巴风险。

正因为这三条都不满足，**本次结论是不可行，不提供完整迁移方案**；上面的"假如要做"的前置条件仅供决策参考。

---

## 八、推断与未证实项（请勿当成事实）

| # | 内容 | 级别 |
|---|---|---|
| 1 | 分区编号映射 `mtd5/6=os0/1`（内核槽）、`mtd8/9=rootfs0/1`、`mtd10=overlay` 与设备 `/proc/mtd` 命名/容量一致 | `[推断]`（脚本常量 + 设备分区容量吻合） |
| 2 | 刷完新槽后，CFE 如何选择启动槽、`flag_boot_rootfs` 由谁写 | `[未证实]`（rootfs 脚本只有读取，没有写入点） |
| 3 | 新版优先规则只在 nvram 四个标志"既非 0 也非 1"（异常恢复）时触发；正常路径不按版本号选槽 | `[脚本]`（`key_services_boot_check` 条件已核对） |
| 4 | 若 2.24.11 不启动，CFE 是否一定回落到 2.25.209 槽 | `[未证实]` |
| 5 | 2.24.11 的 2023 重建是否含安全补丁 | `[无法确认]`（版本号未变，二进制不可反证） |
| 6 | 设备当前 `/data/etc` 的真实内容（是否与 rootfs 默认值一致、是否还有除仓库之外的私改） | `[未证实]`（本次未登录设备） |
| 7 | compat 适配器注册的具体 TaskMonitor 任务清单 | `[未证实]`（需设备侧 `/tmp/taskmonitor/taskmonitor.conf` 核对；仓库只证明注册机制在两版都在） |
| 8 | `2.24.11` 若是"国际/云端向"分支，对国内机型的行为差异 | `[推断]`（由 channel 与增删功能集推断） |

---

## 九、附：本次离线分析的可复现步骤

1. `curl` 两个官方 URL，记录 `Content-Length`/`Last-Modified`/`ETag`；
2. `sha256/md5` 计算，`ETag` 与 MD5 对齐；
3. 按 `HDR1` 结构解析段表（3 段），取尾部 272 B，用包内 `public.pem` 做 `RSA/PKCS1v15/SHA1` 验证（覆盖 `[0x0c, sig_off)`）；
4. `lzma` 解 `root.ubi.lzma` → UBI 镜像，`ubi_reader` 抽 `vol-system.ubifs` 并解出文件树；
5. `LZMA` 解 `vmlinuz.trx`（`HDR0` 容器，偏移 `0x1c` 起 LZMA-alone）→ 取内核版本串；
6. 两棵 rootfs 做 SHA-256 清单 diff；逐项读 `flash.sh` / `boardupgrade.sh` / `lib/preinit/*` / `etc/remove.conf`。

> 全流程未对 `192.168.3.2` 发起任何连接；设备侧数据仅引用既有清点报告 `docs/device-inventory-2026-11-08.md`。
