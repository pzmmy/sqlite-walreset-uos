# sqlite-walreset-uos — SQLite WAL-reset 修复，面向统信 UOS / Deepin

SQLite 的 **WAL-reset 缺陷**（3.7.0 至 3.51.2，官方 3.51.3 修复）在 UOS / Deepin 的打包里没有跟进。
本仓库提供两样东西：

- **`patches/`** — 一条可直接进 `debian/patches/` 的补丁，给发行版维护者。
- **`tools/`** — 官方出包之前的用户侧临时缓解（自编译 + 影子测试 + 可回滚替换）。

本仓库是证据仓库，不是产品。目的只有一个：让维护者或任何人在 30 分钟内能复现结论、或者反驳它。

---

## 事实基线（全部可查）

| 项 | 值 |
|---|---|
| 受影响版本 | SQLite **3.7.0**（2010-07-21）– **3.51.2**（2026-01-09） |
| 修复版本 | **3.51.3**（2026-03-13）；backport：**3.44.6**、**3.50.7** |
| 上游文档 | <https://sqlite.org/wal.html#walresetbug> |
| 是否有 CVE | **没有**。SUSE / Debian / Ubuntu 的 changelog 都以 "Fix the WAL-reset database corruption bug" 记，不挂 CVE 号 |
| 上游对概率的定性 | "unlikely to occur in common use"；"occurrence rate in the wild appears to be less than or equal to the expected occurrence rate of SSD malfunctions and/or cosmic-ray hits" |
| 真实现网事故 | Tailscale 因该缺陷经历约 6 个月服务不稳定，才定位到根因 — <https://tailscale.com/blog/sqlite-wal-reset-bug> |
| 独立复现 | Antithesis — <https://antithesis.com/blog/2026/wal-reset-bug> |

> 关于严重度：本仓库不主张它是高危漏洞，也不主张"触发条件不苛刻"。上游明确说罕见。
> 主张只有一条：**这是一个已修复、有官方 backport、其它发行版已跟进、而 UOS/Deepin 打包里缺失的补丁。**

## 各发行版的跟进状态

| 发行版 / 分支 | 当前 SQLite | WAL-reset 修复 |
|---|---|---|
| Debian bookworm | 3.40.1-2+deb12u2 | ✗ 未合（changelog 里没有该条） |
| Debian trixie | 3.46.1-7+deb13u2 | ✗ 未合 |
| Ubuntu jammy | 3.37.x | ✓ 已 backport，LP #2171337，补丁名 `0019-Avoid-an-obscure-race-condition-between-a-checkpoint.patch` |
| Ubuntu resolute | — | ✓ 已 backport |
| SUSE SLE 12 / 15、Micro 6.0 | 升到 3.51.3 | ✓ 已修 |
| **Deepin / UOS 打包基线** | **3.46.1-8deepin6**（2026-11-10，lichenggang@uniontech.com） | **✗ 未合** — `debian/patches/` 里 CVE-2026-11822/11824/119371–119379/119591/39113/50812/50813 一共 30 条补丁齐全，唯独没有这一条 |
| UOS 20（eagle 1070）实测机 | 3.39.3 | ✗ 未修 |

表格里最关键的一行是 Deepin 那行：**他们的补丁清单是按 CVE 号扫的，非 CVE 的上游修复会整条漏掉。**
这不是能力问题，是清单覆盖面问题 —— 而这正是补一条 patch 就能闭合的缺口。

## 给维护者：应用补丁

```bash
# 在 deepin-community/sqlite3 的 3.46.1 源码树上
cp patches/56-WAL-reset.patch debian/patches/
echo 56-WAL-reset.patch >> debian/patches/series
# 然后照常 dpkg-buildpackage
```

已在 3.46.1 官方 orig tarball 上验证：

```
$ patch -p1 --dry-run -i 56-WAL-reset.patch
checking file src/wal.c
checking file test/walrestart.test
# 零 reject，零 fuzz
```

补丁内容（3 处）：

1. `src/wal.c` — checkpoint 里，在拿到 `WAL_READ_LOCK(0)` 后比对本连接读到的 WAL header salt 与当前 live salt。
   salt 不一致说明 WAL 已被写者 wrap，此时 `nBackfill` 已被置 0，继续 backfill 会写出比实际帧数更多的页 —— 直接跳过。
2. `src/wal.c` — 增加 `sqlite3FaultSim(660)` 测试钩子，供回归用例在 checkpoint 中途插入竞争写入。
3. `test/walrestart.test` — 上游随修复一起发布的 TCL 回归用例。

补丁源：上游 trunk check-in `7168988acbec2d8d`，3.44 分支 cherry-pick `2af8439a0c22c652`（注释写明"omits testing infrastructure"）。
本仓库这条是对 **3.46.1** 的适配，同时借了 Ubuntu jammy 已发布的同源 backport 作为交叉参照。

### 本仓库验证到的结果（x86_64）

| 用例 | 未打补丁 3.46.1 | 打补丁 3.46.1 |
|---|---|---|
| `test/walrestart.test` | **2 errors / 7** — 1.3 expected `[0 45 0]` got `[0 45 45]`；1.4 expected `[0 58 58]` got `[0 45 45]` | **0 errors / 7** |
| 功能回归 16 项（FTS3/4/5、trigram、JSON、RTREE、MATH、窗口函数、CTE、UPDATE LIMIT、BLOB、WAL 并发） | — | **16/16 通过**，`integrity_check=ok` |

原始输出在 `evidence/`，构建指纹在 `evidence/BUILD-RECORD.md`。

## 给用户：官方出包前的临时缓解

`tools/` 是自编译 + 替换系统库的脚本，**只在你能物理接触机器、且已接受风险时使用**。

```bash
bash build_sqlite.sh 3540100        # 编译 + 影子测试（LD_LIBRARY_PATH，不碰系统库）
sudo bash replace_system_sqlite.sh --yes   # 备份原库 + 生成回滚脚本后替换
sudo reboot
sudo bash rollback_sqlite.sh        # 出问题回滚
```

替换系统共享库是高风险操作：新库有问题时，依赖它的程序（含开机自启的桌面组件）可能全部异常，
极端情况影响进入图形界面。**先跑影子测试，全绿再替换。** 详细说明见原包 `docs/`。

这里要说明白：这个方案是权宜之计。真正该做的是让发行版出包 —— 也就是上面的 patch。

## 验证矩阵

| 架构 | 环境 | 做了什么 | 状态 |
|---|---|---|---|
| x86_64 | WSL2 / gcc 13.3 / Ubuntu 24.04 | 补丁应用 + 编译 + `walrestart.test` A/B + 16 项功能回归 | ✅ 完成 |
| aarch64 | UOS 20（eagle 1070）/ 内核 5.10.97 / arm64 | 自编译 3.54.1 替换系统库，294 个进程重启后正常；10 项影子测试 + 并发压测（13 线程 / 1285 事务）+ `integrity_check` | ✅ 运行验证（用户机） |
| x86_64 | 真实 UOS x64 | 未测 | ⬜ 邀请回报 |
| loongarch64 / 其它 | — | 未测 | ⬜ 邀请回报 |

补丁本身是纯 C 源码改动，与架构无关；未测的是"在具体发行版+架构组合上的编译与运行"。

## 许可

- `patches/` 中的 SQLite 代码改动：SQLite 为 Public Domain（<https://sqlite.org/copyright.html>）。
- `tools/` 与本文档：MIT，见 `LICENSE`。
- `test/walrestart.test` 的版权声明随上游原文保留（"The author disclaims copyright to this source code"）。
