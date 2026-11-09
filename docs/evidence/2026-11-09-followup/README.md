# 2026-11-09 后续验证（B1 / B6 / B2）

本轮不新增部署，不接管 22，不改生产 `macfilter`，MiniDLNA 未触碰。

| 文件 | 内容 | 结论 |
|---|---|---|
| [b1-dropbear-relax.txt](b1-dropbear-relax.txt) | Dropbear 2026.94 放宽补丁构建、2222 备用实例公钥登录、密码行为、banner、进程归属、门控反证与清理 | PASS（仅备用实例） |
| [b6-webdav-guard.txt](b6-webdav-guard.txt) | 18084 隔离实例的 5 秒撤权、fail-closed、看护存活逐项测量与清理 | PASS（三项，隔离） |
| [b2-curl-analysis.txt](b2-curl-analysis.txt) | 私有 curl 协议集、`localhost:`/`--proto-default` 实测、`helper.sh -k`、只读 `/usr` 调用方 | 全量替换不可行 |

实现与构建产物：

- B1：`recipes/stage2/b1-dropbear-relax.sh`、`recipes/stage2/dropbear-relax-authkeys.patch`
- B6：`recipes/webdav/webdav-guard.sh`、`recipes/webdav/lighttpd-test-18084.conf`
- 设备候选：`/userdisk/data/r2d-cand/b1-dropbear-relax/`（仅 `sbin/dropbear`、`bin/dropbearkey`）
