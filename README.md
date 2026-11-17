# LEDE-CI — JDCloud BE6500 固件自动编译

给 [Qianzf/LEDE-JDCloud-BE6500](https://github.com/Qianzf/LEDE-JDCloud-BE6500) 出固件的 GitHub Actions 流水线。

目标设备：**JDCloud RE-CS-06 / BE6500**（IPQ5322 + QCN6224，`qualcommbe/ipq53xx`，Wi-Fi 7 双频 4×4）。

## 产物

每次跑完在 Actions 页面的 artifact 里：

```
jdcloud-be6500-<run_number>.zip
├── openwrt-qualcommbe-ipq53xx-jdcloud_re-cs-06-squashfs-sysupgrade.bin   # 升级用（保留配置）
├── openwrt-qualcommbe-ipq53xx-jdcloud_re-cs-06-squashfs-factory.bin      # 首次刷机用
├── sha256sums.ci.txt
├── *.manifest
└── result.config    # 本次实际生效的 .config（defconfig 之后）
```

## 触发

| 方式 | 说明 |
|---|---|
| 手动 | Actions → **Build JDCloud BE6500** → Run workflow，可指定源仓库分支、配置文件、是否强制重下源码包 |
| push | 改 `config/`、`overlay/`、工作流本身时自动触发 |
| 定时 | 每周五 18:00 UTC（周六 02:00 CST） |

## 仓库结构

```
.github/workflows/build.yml        流水线
config/jdcloud-be6500.config       .config（从本地工作树导出）
overlay/env/kernel-config          env/kernel-config（内核配置片段，Docker 等）
overlay/files/etc/uci-defaults/…   files/ 覆盖层（默认中文、vantage 主题、主机名等）
scripts/export-from-tree.sh        从本地 LEDE 树同步上面三样东西
```

> 为什么 `env/` 和 `files/` 要放在这里：源仓库的 `.gitignore` 把 `/env`、`/files`、
> `/.config`、`/feeds` 都忽略了，所以它们在源码仓库里**不存在**，必须由 CI 注入。

## 工作流做了什么

1. 释放 runner 磁盘（默认只剩 ~14 GB，不够）
2. 装编译依赖
3. `actions/checkout` 拉源仓库（默认 `master`，`fetch-depth: 1`）
4. 注入 `.config` + `overlay/`
5. `./scripts/feeds update -a && ./scripts/feeds install -a`，然后 `make defconfig`
6. 核对关键配置项（target / device / 主题 / wolplus / ATH_DEBUG 必须在，`luci-app-wol` 必须不在），不对就直接失败，省得白编 5 小时
7. `make download -j8`（带重试）+ 缓存 `dl/`
8. `make -j5 V=w`
9. 打 artifact：固件 + sha256 + `result.config` + 编译日志

## 本地改动后怎么同步配置

在本地 LEDE 树里改完 `.config` / `env/kernel-config` / `files/` 之后：

```sh
/path/to/scripts/export-from-tree.sh /workspace/code/lede
cd /path/to/this-repo && git add -A && git commit -m "config: 同步 xxx" && git push
```

脚本做的事就是：

```sh
cp  <tree>/.config                     config/jdcloud-be6500.config
cp  <tree>/env/kernel-config           overlay/env/kernel-config
rsync -a <tree>/files/                 overlay/files/
```

## 缓存策略

| 缓存 | 路径 | key | 作用 |
|---|---|---|---|
| 源码包 `dl` | `source/dl` | 配置/overlay 哈希 + `v1` | 省掉 `make download`（本地实测 **2.4 GB**） |
| `feeds` | `source/feeds`、`source/package/feeds` | `feeds.conf.default` 哈希 | 省 2~4 分钟 clone |
| **ccache** | `source/.ccache` | 配置哈希 + `run_id` | 真正的**编译缓存**，命中后只重编改动过的对象 |

要点：

- ccache 由 `CONFIG_CCACHE=y` 打开（`rules.mk:341` 起把 `TARGET_CC` / `HOSTCC` 外面套一层
  ccache），缓存目录默认就是 `$(TOPDIR)/.ccache`，正好在 `source/` 里，直接被缓存。
- ccache 上限 `3 GB`（`--max-size=3G` + `CCACHE_COMPRESS`），避免顶穿 GitHub 单仓库
  **10 GB** 的缓存配额；旧条目由 GitHub 按 LRU 淘汰。
- ccache 的 key 带 `run_id` 是有意的：`actions/cache` 命中后**不再回写**，不带 `run_id`
  就永远停留在第一次那份。代价是每次运行新增一条，靠 LRU 淘汰。
- 缓存命中率会写进 job summary（`ccache -s`），自己看 hit rate 判断值不值得留。
- `workflow_dispatch` 的 `force_download` 勾上会跳过 `dl` 缓存恢复（想彻底重下源码时用）。

### 没缓存什么，以及为什么

| 项 | 大小 | 为什么不缓存 |
|---|---|---|
| `build_dir` | 15~25 GB | 超过 10 GB 配额；且配置一变就是脏对象，报错很难查 |
| `staging_dir` / `toolchain` | 5~10 GB | 体积大、对配置和 patch 极其敏感，跨 run 复用容易出玄学错误 |
| `bin/` | 1 GB+ | 每次都要重新打包，缓存无意义 |

> 如果以后确实需要"几分钟出包"，正确做法是挂 **self-hosted runner**（机器上保留
> `build_dir`/`staging_dir`），而不是把 20 GB 塞进 Actions 缓存。

## 已知限制

- **GitHub 免费 runner 只有 4 核 / 16 GB，job 上限 6 小时。** 这套配置（Docker +
  passwall2 + openclash + homeproxy + ssr-plus + 完整 wpad + 全套 luci 翻译）第一次
  冷编译很容易贴到 350 分钟的上限。缓解办法：
  - `dl/` 缓存命中后，`make download` 基本为 0，能省 10~20 分钟；
  - 想稳定出包，建议挂一台 self-hosted runner（改 `runs-on:` 即可），或者按需删包；
  - 也可以在 `workflow_dispatch` 里只跑 `make download` 先把缓存养起来。
- artifact 保留 30 天，固件 **156 MB/个**，两个 bin ≈ 313 MB，注意配额。
- CI 出来的镜像**没有经过刷机验证**，刷之前先核 sha256，且建议先刷 `sysupgrade` 到
  一台可回滚的机器上。
- 私有仓库/私有 feed 需要额外配 `secrets`；当前源仓库是公开的，不需要。

## 相关文档

无线那几个坑（2.4G HT 能力位、MAX-AMSDU、ath12k 校准数据、开机 60 秒固件加载阻塞、
DFS/CAC 语义）的完整排查记录在源仓库：

- `firmware-changes/WIFI-FIX.md`
- `firmware-changes/CHANGES.md`
