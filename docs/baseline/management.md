# 管理调用图与生命周期

描述现场 2.25.209 与样本 2.24.11 一致或互为补充的部分；差异单独标注。证据编号见 [evidence.md](evidence.md)。

## 启动与重载

```text
init.d/samba start
  └─ 读取 /userdisk/appdata/app_infos/<appid>.manifest
       └─ status == 5 ?
            └─ start_impl
                 ├─ /usr/sbin/shareUpdate -s
                 ├─ updateconfig
                 │    ├─ 读取 UCI samba 全局段与 sambashare 段
                 │    ├─ 以 /etc/samba/smb.conf.template 生成 /var/etc/smb.conf
                 │    ├─ 按 misc.samba 的调优项追加 socket/缓存/绑核配置
                 │    └─ 确保 /etc/samba/smb.conf 指向 /var/etc/smb.conf
                 ├─ /usr/sbin/supervisord start        (按 PROCLINE 启动 smbd)
                 └─ service_start /usr/sbin/nmbd -D
```

| 环节 | 记录 | 等级 |
| --- | --- | --- |
| 插件闸门 | init 只在 manifest 的 `status=5` 时启动；现场 manifest 的开发者字段为 MiWifi，状态为 5 | 现场、样本 |
| 配置生成 | `shareUpdate -s` 先运行，再由 UCI 与模板生成 `smb.conf`；直接改生成文件会在下次 reload/start 时丢失 | 现场、样本 |
| 进程管理 | smbd 交给 supervisord，nmbd 由 init 直接启动 | 现场、样本 |
| reload | 重新生成配置后执行 `smbcontrol all reload-config` | 现场、样本 |
| stop | `supervisord stop` 加停止 nmbd；不直接杀 smbd | 样本 |
| restart | stop、等待 3 秒、再 start | 样本 |

共享项由 UCI 生成：名称、路径、`preexec`、`valid users`、`read only`、`guest ok`、创建/目录掩码、`browseable`、`force user`。现场媒体分享主要使用 `guest_ok=yes`，普通媒体分享强制以 root 访问文件；账号库为空。配置模板还声明：`map to guest = Bad User`、`guest account = nobody`、`smb encrypt = disabled`、`server role = STANDALONE`、`bind interfaces only = yes`，接口来自 UCI 解析后的 LAN 设备。见 [evidence.md](evidence.md) 的 E7。

## 磁盘与摄像机热插拔

```text
block add
  ├─ /usr/sbin/shareUpdate -a
  ├─ /usr/sbin/sendmessage
  ├─ /usr/sbin/pluginControllor -a <mountpoint>
  └─ datacenterClient api 63 (status=1)

block remove
  ├─ datacenterClient api 63 (status=0)
  ├─ 首个分区被拔出时 pushClient type 302 提示
  ├─ /usr/sbin/shareUpdate -r <mountpoint>
  ├─ /usr/sbin/sendmessage
  ├─ /usr/sbin/pluginControllor -r <mountpoint>
  └─ 延迟 umount
```

| 环节 | 记录 | 等级 |
| --- | --- | --- |
| 磁盘事件 | block 热插拔脚本调用 shareUpdate 的 `-a` / `-r`，并通知数据中心、插件控制器与消息通道 | 现场、样本 |
| 摄像机事件 | USB PTP 摄像机挂载为 gphotofs 目录后，同样调用 shareUpdate、插件控制器与数据中心 | 样本 |
| 摄像机分享 | init 为摄像机分享加载厂商只读 VFS，并按 `misc.smb_ctl` 写入时间范围 | 现场 |

## 其他管理链路

| 链路 | 记录 | 等级 |
| --- | --- | --- |
| `prepare_sync.sh` | 依据插件状态调用数据中心或重启 Samba；可通过 api 75 更新“整盘访问”授权；本轮未执行 | 现场 |
| datacenter | 二进制含 `StorageApi::modifySambaAccess`、`getCanAccessAllDisk`、`LoginMacManager`、`SambaUtils` | 现场符号 |
| pluginControllor | 含 `SambaPlugin` 的启动/停止逻辑 | 现场符号 |
| shareUpdate 内部 | 含配置更新、访问控制修改、单共享访问修改、reload、restart 以及 MiniDLNA 配置与电视通知函数 | 样本符号、现场 |
| 电视/DLNA 副作用 | shareUpdate 同时更新 MiniDLNA 配置并发出电视通知，不能视为只服务 SMB | 样本、现场 |

`shareUpdate` 的符号名来自样本程序（E7，本轮复核），现场二进制中也有对应字符串（E1）。这证明管理职责存在，不等于每个手机 App 按钮的分支都已验证。

## 生命周期矩阵（当前可知）

| 操作 | 已知行为 | 未确认 |
| --- | --- | --- |
| 首次启动 | 需要插件 manifest 状态为 5；先生成配置再启动 smbd/nmbd | 失败时的退出码与日志位置 |
| 手动重载 | 重新生成配置并通过 smbcontrol 通知 | 新版 smbcontrol 能否控制旧进程、反之亦然 |
| 停止 | supervisord 停 smbd，init 停 nmbd | 已连接会话的中断表现 |
| 配置生成失败 | 未记录回退行为 | 是否保留上次有效配置、错误输出位置 |
| 磁盘拔出 | shareUpdate 移除共享并通知外围 | 正在传输/打开的句柄行为 |
| 插件关闭 | manifest 状态改变后 Samba 不启动 | 运行中关闭是否立即停止服务 |

## 待确认

1. supervisord 的主配置文件位置、`PROCLINE` 展开方式、PID/锁目录与进程名约束。
2. 现场 smbd/nmbd 的实际命令行、PID 文件和日志级别（日志级别此前已确认恢复为 1，但未留存输出）。
3. `smbcontrol reload-config` 的跨版本兼容性；这是 S5 的前置，不能用同名命令存在来推断兼容。
4. `shareUpdate` 与新版 Samba 的配置键、模块语义和退出码兼容性。
5. 配置生成失败、端口被占用、双实例并存时的实际行为。
