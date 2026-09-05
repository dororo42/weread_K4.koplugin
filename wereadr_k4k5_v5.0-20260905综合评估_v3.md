# weread_K4.koplugin 综合评估报告（v3 · 场景更新版）

**项目**：dororo42/weread_K4.koplugin @ main · v0.6.0-k4-v5.0（2026-08-29）
**评估日期**：2026-09-05
**报告性质**：v2（合并版）经代码逐项核实后的场景修订版；含勘误
**适用设备**：Kindle 4 + Kindle 5（非触摸）
**KOReader 版本**：**锚定 v2026.07.1**（"Sailing Walrus" 修正版，用户实测版本）
**新增评估维度**：**微信读书服务端风控**
**适用读者**：维护者、代码贡献者、版本评审

---

## 一、核心结论（更新版）

在"K4/K5 同代硬件 + KOReader 2026.07.1 锚定 + 风控约束"的新场景下：

1. **P0 收敛为 3 项**：inline 网络阻塞 UI（原#3，证据较 v2 更强——fork 已禁用，全部上报走 UI 线程）、测试/回归保障缺失（原#5）、`_books_cache` 引用共享契约缺失（S-02，修正定位）。
2. **两项 v2 评级经代码核实后降级**：S-10 deepcopy 升 P0 的论据不成立（books 路径恰恰不做 deepcopy）→ 降 P3；S-03 "rt=-30" 反例不成立（`math.max(0,…)` 已防负）→ 保留 P1 但按风控维度重述。
3. **一项升级**：S-18 多设备进度同步默认关闭，因 K4+K5 双机使用场景成为真实痛点 → 升 P1。
4. **风控成为显式维度**：插件已有的保守化设计（30s 心跳对齐、3h 补报上限、指数退避、UA 一致性）是有效防线，本版将其固化为"不可回退常量"红线；剩余风控敞口集中在时钟异常（S-03）与弱网 tick 语义（S-12）。
5. **信息泄露类全部降级 P3**，打包为"顺手修复包"：每项 ≤5 行、不影响用户使用，一次提交完成。
6. 合并后共 **25 项风险**：**P0 × 3、P1 × 7、P2 × 5、P3 × 10**。

---

## 二、硬件基线（K4 + K5）

| 维度 | Kindle 4 | Kindle 5 | 对评估的影响 |
|---|---|---|---|
| CPU | Freescale i.MX508 · Cortex-A8 · 800MHz 单核 | Freescale i.MX508 · Cortex-A8 · 800MHz 单核 | **同代 SoC**：K4 基线的性能结论对 K5 完全适用 |
| RAM | 128–256MB（主流 256MB） | 256MB（Hynix Mobile DDR） | KOReader 基线 ~50MB，插件预算极小，GC 压力敏感 |
| 显示 | 6" E-ink 600×800 · 167ppi · 16 级灰阶 | 6" E-ink 600×800 · 167ppi · 16 级灰阶 | 相同 |
| 输入 | 非触摸 · 5 向键 + 翻页键 + ScreenKB | 非触摸 · 4 向+中键（等效 5 向）+ 翻页键 + 键盘键 | 交互模型一致，ScreenKB 组合键两机型均可用 |
| 存储 | 2GB EMMC，可用 ~1.3GB | 2GB flash，可用 ~1.25GB | 缓存膨胀风险相同 |
| 网络 | Atheros AR6103 · 802.11 b/g | Atheros AR6103 · 802.11 **b/g/n** | K5 弱网略好，backoff/降级设计对两者仍关键 |
| 电池 | 890–1800mAh | 同代 | 定时器泄漏直接影响待机 |

**结论**：K5 与 K4 属同一硬件代际，v2 报告的 K4 硬件基线分析**无需修改即可扩展到 K5**；唯一场景增量是"双机共用一个微信读书账号"（见 S-18 与风控说明）。

---

## 三、场景与需求修订 → 评级影响

### 输入 1：K4 + K5 双机型（硬件适配、稳健优先）

- 硬件基线不变（上表），性能权重维持高位。
- **新增双设备使用场景** → S-18（进度同步默认关闭）从 P2 升 **P1**：两台设备交替阅读时，默认配置下打开不拉取、关闭不上传，极易出现"读了几十页进度回退"或本地覆盖云端；同时双机并发在线阅读产生的并发心跳模式值得在 README 提示。

### 输入 2：KOReader 锚定 v2026.07.1

- **S-14（KOReader 内部 API 强依赖）从 P1 降 P3**：版本锚定后"上游升级即 break"的近期风险不成立，`koreader_compat.lua` 降为远期工作。实际用到的内部模块（`socketutil`、`ffi/util`、`ui/time`、`ui/event`、`luasettings`、`libkoreader-lfs`、`json`/`rapidjson`）在 2026.07.1 上已被用户实测验证。
- 2026.07 "Sailing Walrus" 的 **非触摸 D-pad 改进（#11749）与 Kindle 文档更新对插件是利好**：K4/K5 的按键导航与文本选择体验在上游侧改善，插件自身的按键适配维持现状即可。
- 建议 README 安装节把"建议 KOReader 2026.03 或更高版本"更新为"**已在 2026.07.1 验证**"（一行文档改动）。

### 输入 3：微信读书风控（新增显式维度）

**已有防线盘点（全部在代码中核实，固化为"不可回退常量"红线）**：

| 防线 | 位置 | 说明 |
|---|---|---|
| 心跳对齐 | read_report.lua:75/86 | `MAX_SINGLE_REPORT_SECONDS=30`、`BACKLOG_TICK_SECONDS=30`，与 web 阅读器真实心跳一致 |
| 补报上限 | read_report.lua:525 | 跨会话 pending_backlog 钳制 3h，超出丢弃（R-A） |
| 失败退避 | read_report.lua:326-331 | 30s→60s 指数退避，cap 60s（P1-2 调整），杜绝弱网请求风暴 |
| 弱网超时降级 | read_report.lua:33-34 | 连续 2 次失败后 8s→4s，恢复自动还原 |
| 挂起排除 | read_report.lua:54 | SUSPEND_EXCLUDE_THRESHOLD_SECONDS=30，睡眠不计入时长 |
| 重试链瘦身 | read_report.lua:1327-1345 | 单 tick 失败至多 2 个请求；renewal 冷却 10 分钟 |
| UA/appId 一致性 | v4.0 变更 | Edge-Windows UA + `clear_stale_app_ids` 迁移 |

**剩余风控敞口（本版保留/重述为 P1）**：
- **S-03**：域逻辑用 `os.time()` 墙钟。勘误：v2 所称"时钟回拨 → rt=-30"不成立（read_report.lua:308 `math.max(0,…)` 已防负）；真实风险是**回拨后产生"幽灵 30s 时长"**（无阅读仍按 interval 上报）与跳变后的异常节奏，属服务端可观测的异常模式。修复方向不变：单调时钟包装 + 启动时合理性检查。
- **S-12**：弱网下 tick 与翻页的阻塞权衡（见 P1-7）。
- **S-04**：私有协议/endpoint 硬编码，服务端协议突变时插件会发出"带错误字段的合法请求"，异常请求模式可能先于功能不可用被风控观察。协议指纹日志 + 降级链仍是正解（P2）。
- **双设备提示**：两台设备同时在线阅读会产生并发心跳（双 IP 同账号），建议 README 增加"避免双机同时在线阅读同一账号"一行提示。

### 输入 4：信息泄露降级 + 顺手修复

- 原#1（凭据明文）、S-01/07/08/11 全部维持 P3。**但按"改动成本不高且不影响使用即顺手处理"原则**，P3 中的五个小项打包为一次提交（见第八节顺手修复包），其中 S-01（日志脱敏）性价比最高。

---

## 四、合并后风险矩阵（25 项 · 按新评级排序）

| ID | 风险名称 | 所在模块（已核实行号） | 等级 | 维度 | 相对 v2 |
|---|---|---|---|---|---|
| 原#3 | inline 网络请求阻塞 UI（fork 已禁用，全量上报走 UI 线程） | read_report.lua:255；client.lua:18 | **P0** | 性能+风控 | 强化证据 |
| 原#5 | 测试/回归保障缺失 | 全局（无 spec/、无 CI、无 luacheck） | **P0** | 工程 | 维持 |
| S-02 | `_books_cache` 引用共享契约缺失（有意设计但未文档化，失效重建后有脏写回窗口） | settings.lua:191/255 | **P0** | 稳健 | 重述定位 |
| S-20 | **新增**：`set("books")` 全表重写仍是 UI 路径常规操作（14 处调用点，每次 O(N)×3 个 JSON 写盘） | library.lua×7、cache.lua×5、downloader.lua:1115、migrations.lua:28/72 | **P1** | 性能 | 新增 |
| 原#2 | `_G` 跨实例状态收口（跳转槽 + 对话框栈两处 `_G` 结构，防护已在位，防扩散） | reader_lifecycle.lua:103；ui/common.lua:179 | P1 | 稳健 | P0→P1 |
| S-05 | 定时器闭包持有实例，flush 定时器无 unschedule 兜底 | read_report.lua:1147/1236；progress_sync.lua:108 | P1 | 性能+稳健 | 修正位置 |
| S-03 | 时间源混用（域逻辑 os.time 墙钟）→ 时钟回拨产生幽灵时长 | read_report.lua:253/306-313 | P1 | 风控 | 重述论据 |
| S-18 | 多设备进度同步默认关闭（双机场景成真实痛点） | settings.lua:24-28 | P1 | 稳健 | P2→P1 |
| 原#4 | `os.execute("lipc-set-prop…")` 阻塞 + 平台耦合 | downloader.lua:54/63 | P1 | 稳健 | 维持 |
| S-12 | backoff cap 60s × 4s 超时 = 弱网下每分钟 ~4-8s UI 阻塞 | read_report.lua:330 | P1 | 性能 | 维持 |
| S-04 | 私有协议/endpoint 硬编码单点（6 处） | client.lua:461/502/558/587/630/664 | P2 | 稳健 | 维持 |
| S-09 | JSON 库双失败无降级 | client.lua:8-11；book_store.lua:1-4 | P2 | 稳健 | 维持 |
| S-16 | 纯 Lua MD5/SHA256（bit 库实现，单核 800MHz 热点有限） | crypto.lua | P2 | 性能 | 维持 |
| 原#1 | 凭据明文落盘（K4/K5 单用户自有设备，物理接触即失守前提） | settings.lua（LuaSettings 明文） | P2 | 隐私 | 维持（降权） |
| S-15 | 并发 flush 无锁（KOReader 单线程下暂无实际并发） | settings.lua/read_report.lua | P2 | 稳健 | 维持 |
| S-01 | HTTP 失败日志带响应体（500 字符截断） | client.lua:102-116；read_report.lua:232 | P3 | 隐私 | **顺手修复** |
| S-07 | `resolved_dir` 信任 `book.cache_dir` 无前缀校验 | book_store.lua:52-54 | P3 | 隐私 | **顺手修复** |
| S-08 | Cookie key 未过滤控制字符（value 已过滤；key 来源受 `[%w_]+` 白名单约束，实际风险极低） | cookie.lua:7-8 | P3 | 隐私 | **顺手修复** |
| S-11 | `display_error` 不剥 URL query | plugin_util.lua:47-54 | P3 | 隐私 | **顺手修复** |
| S-13 | 子进程 fork 死代码（`make_subprocess_runner` 永不启用） | read_report.lua:108-137 | P3 | 性能 | **顺手修复** |
| S-14 | KOReader 内部 API 强依赖 | 多处 | P3 | 稳健 | **P1→P3**（版本锚定） |
| S-10 | deepcopy 使用（勘误：books 路径不做 deepcopy，现存均为小表复制） | settings.lua:62-71/180；client.lua:72-81 | P3 | 性能 | **P0→P3**（勘误） |
| S-17 | 手动登录沙箱白名单缺 math/os.time（现有模板够用，防御性补充） | settings.lua:380-395 | P3 | 稳健 | 维持 |
| S-19 | `merge_req_opts` headers 合并 O(n²)（header 数 <10，实际影响微） | client.lua:118-141 | P3 | 性能 | 维持 |
| S-21 | **新增**：文档/状态漂移——client.lua:14-16 "read-report fork subprocess" 注释已过时；对话框 `_G` 栈只增不清（已关闭 widget 残留） | client.lua:14-16；ui/common.lua:179-199 | P3 | 稳健 | 新增 |

**勘误说明（相对 v2）**：① S-10 降级——v2 称"每次 `settings:get('books')` 触发 deepcopy"，实际 books 路径经 H-8 缓存**恰好避免 deepcopy**（settings.lua:189-207），其余调用对象均为小配置表；② S-03 重述——"rt=-30" 反例不成立（read_report.lua:308 有 `math.max(0,…)` 钳制）；③ 原#2 从 P0 降 P1——book_id 校验（reader_lifecycle.lua:123-130）、session 代数守卫（:112-114）、读后即清（:104-105）三重防护已在位，核心诉求是收口防扩散而非现行缺陷；④ v2 行号引用普遍失效，本版全部换为已核实行号；⑤ v2 文件在"附录 B 权重模型"处截断，本版已补全（附录 B）。

---

## 五、P0 级详解（立即处理）

### P0-1 inline 网络请求阻塞 UI【原#3 · 性能+风控】

**v3 证据强化**：read_report.lua:255 明确 `subprocess = nil`（注释：fork 导致 UI 卡顿 0.5-3s），即**全部**上报/续期/上下文刷新请求都在 UI 线程 inline 执行；8s 默认超时（client.lua:18）+ 4s 弱网降级 + 60s 退避是仅有的缓冲。弱网下一次失败 tick = 1 个 4s 阻塞，叠加 `_context_fingerprint`/`get("books")` 重建时每本书 3 次 JSON 读盘。

**优化方向**（维持 v2 并收敛）：
- 弱网继续降级到 2s + 立即入 backlog；
- "翻页期间 0 网络请求"硬约束从 downloader（foreground_barrier 已具备）推广到 read_report tick；
- S-20 修复后，tick 内的 `get("books")` 不再触发全量磁盘重建。

### P0-2 测试/回归保障缺失【原#5 · 工程】

维持 v2 判断：仓库无 spec/、无 CI、无 luacheck；README 变更日志是补丁编号流水账；v5.0 一口气修了 4 个回归。**v3 补充**：本版勘误（S-10/S-03 论据错误）本身即证明"无测试 → 连评估报告都缺核对基线"。优先覆盖 `settings.lua` / `book_store.lua` / `read_report.lua` 三个核心模块，建立补丁编号 → 测试用例映射。

### P0-3 `_books_cache` 引用共享契约【S-02 · 稳健 · 定位修正】

v2 将其定性为缺陷；v3 修正：这是 H-8/P0-1C 的**有意设计**（settings.lua:253-258 注释明确"store the reference…stay consistent"，read_report 的就地修改 + `set_book` 持久化是配套协议）。真实风险有二：
1. 契约未文档化，新调用方极易"改了不存"或"存了旧引用"；
2. 缓存失效重建（`set("books")` 置 dirty）后，先前置开的旧引用持有人写回 `set_book` 会产生**丢更新**。

**修复方向**：顶部契约注释 + 提供 `mutate_book(book_id, fn)` 事务式 API（改完即存），新代码一律走该入口。与 S-20、原#5 联合解决。

---

## 六、P1 级详解（30-60 天）

### P1-1 `set("books")` 全表重写收敛【S-20 · 新增 · 性能】

settings.lua:229 注释自证：`set("books")` 对每本书写最多 3 个 JSON，"0.5-2s of blocking I/O per call"。P0-1C 只把 30s tick 挪到了 `set_book`，但 **UI 路径仍有 14 处全量调用**（library.lua ×7、cache.lua ×5、downloader.lua:1115、migrations.lua:28/72），在几十本书 + K4/K5 慢 flash 上是菜单操作卡顿的直接来源。这是 v2 遗漏的、比 deepcopy 更实在的热点。
**修复**：逐点审计，高频路径（排序、关闭上传、清理）改 `set_book`/局部更新；`set("books")` 仅保留给批量迁移。

### P1-2 `_G` 状态收口【原#2 · 稳健 · P0 降级】

防护已在位（勘误③），风险是 v5.0 出现第二个 `_G` 结构（对话框栈）后扩散。**修复**：统一 `weread/lib/global_state.lua`——单一命名空间 + API 读写 + TTL/代数校验 + `onCloseDocument` 清理；对话框栈增加"widget 已关闭则自清理"。长期探索 ReaderUI-scope 状态。

### P1-3 flush 定时器 unschedule 兜底【S-05 · 性能+稳健 · 位置修正】

v2 所指位置（reader_lifecycle L10/19）无定时器；实际问题是 read_report.lua:1147（水印 flush）与 :1236（上下文 flush）两个 30s 定时器**在 `stop()` 中不被 unschedule**（stop 只清 task 与 job.poll，:570-624），关书后闭包持有实例最长 30s；progress_sync.lua:108 同型。功能无害（标志位守卫）但属于待机功耗与生命周期的确定性缺口。
**修复**：实例级定时器注册表，`stop()/onCloseDocument` 统一 unschedule。

### P1-4 单调时钟与风控【S-03 · 风控 · 论据重述】

域逻辑（watermark、backlog、interval）全部用 `os.time()` 墙钟（read_report.lua:253）。勘误后真实风险：时钟回拨 → 无阅读仍按 interval 产出"幽灵 30s 时长"（服务端可观测的异常模式）；时钟跳前 → backlog 异常增大（有 3h cap 兜底，:525）。
**修复**：`ui/time`（KOReader 单调毫秒源，已在文件内引入仅作打点）包装为域时钟；启动时若 `os.time()` 与上次持久化值倒退超过阈值则跳过当次上报。

### P1-5 多设备进度同步【S-18 · 稳健 · P2 升级】

K4+K5 双机共用账号的新场景下，`pull_on_open/upload_on_close` 默认 false（settings.lua:24-28）意味着换设备阅读必然出现进度回退/覆盖。**修复**：默认值翻转为 true（新配置；老配置不动，与 v2.x 默认启用上报的先例一致）；增加 `last_remote_position` 与本地差值检测，差值异常大时提示选择。

### P1-6 `os.execute("lipc-set-prop…")`【原#4 · 稳健】

维持 v2：常量字符串 + `xpcall` 防泄漏已在位。**修复**：feature-flag + Kobo 分支走 PluginShare 的注释说明；顺带确认 `preventScreenSaver` 的成对调用（downloader.lua:54/63）在取消路径总是释放。

### P1-7 弱网 tick 节奏【S-12 · 性能】

失败退避 cap 60s（read_report.lua:330）× 降级后 4s 超时 = 弱网下每分钟约 4-8s UI 阻塞，与翻页撞车概率不低。**修复**：连续失败 ≥4 次时把 tick 拉长到 120s（时长不丢，watermark 语义不变），并叠加 P0-1 的"翻页 0 网络"约束。

---

## 七、P2/P3 简要

- **P2-1 S-04 协议单点**：`protocol_versions.lua` + 接口 fallback 链 + 协议指纹日志（风控相关：异常请求模式先于不可用被观察）。
- **P2-2 S-09 JSON 双失败**：纯 Lua fallback 或启动 fail-fast。
- **P2-3 S-16 纯 Lua crypto**：调用频率有限，profile 显示热点再考虑 FFI。
- **P2-4 原#1 凭据明文**：K4/K5 单用户场景维持降权；轻量加密（XOR + 设备指纹）作为可选低成本缓解，README 已有"勿外借设备/备份"提示，可暂缓。
- **P2-5 S-15 并发 flush**：单线程事件循环下无实际并发，未来引入 worker 时补 mutex。
- **P3 顺手修复包（一次提交，每项 ≤5 行，不影响使用）**：
  1. S-01：`log_response`/`response_summary` 增加一行 `redact_body()`（去凭证字段）；
  2. S-07：`resolved_dir` 增加 `settings.cache_dir` 前缀白名单校验；
  3. S-08：cookie.lua:8 key 增加 `gsub("[%c]","")`；
  4. S-11：`display_error` 剥离 query string；
  5. S-13：删除 `make_subprocess_runner` 死代码（或 `SUBPROCESS_ENABLED=false` 标注）；
  6. S-21：更新 client.lua:14-16 过时注释；对话框栈弹出时自清理已关闭 widget；
  7. S-17：沙箱白名单补 `math`、`os.time`（防御性）；
  8. S-19：headers 合并改小写 key 索引预处理；
  9. 文档：README 标注"已在 KOReader 2026.07.1 验证"+ 双设备并发阅读风控提示。

---

## 八、30/60/90 天行动计划（v3）

### 30 天（P0 全清 + P1 性能双项）

| 行动 | 负责风险 | 验证方式 |
|---|---|---|
| busted 测试基建（settings / book_store / read_report） | 原#5 | CI 跑通 |
| `set("books")` 14 处调用点审计收敛到 `set_book` | S-20 | 翻页/菜单操作帧延迟 profiling |
| `_books_cache` 契约注释 + `mutate_book()` API | S-02 | 修改返回值行为测试 |
| `global_state.lua` 收口（跳转槽 + 对话框栈） | 原#2 | 切书冒烟 + 单元测试 |
| flush 定时器注册表 + unschedule | S-05 | 关书后实例释放验证 |
| S-18 默认翻转 + 差值检测 | S-18 | 双机交替阅读实测 |

### 60 天（P1 剩余）

| 行动 | 负责风险 |
|---|---|
| 单调时钟域包装 + 倒退跳过 | S-03 |
| lipc feature-flag + 平台注释 | 原#4 |
| 弱网 tick 拉长 120s | S-12 |

### 90 天（P2）+ 机会性（P3 顺手修复包一次提交）

见第七节；P3 包不占节奏，随任意 PR 顺路完成。

---

## 九、风控红线（不可回退常量清单）

以下常量经实测调优且与 web 阅读器行为对齐，**任何改动必须同时评估风控影响**：

| 常量 | 值 | 位置 | 红线理由 |
|---|---|---|---|
| MAX_SINGLE_REPORT_SECONDS | 30 | read_report.lua:75 | 对齐 web 心跳；超限服务端静默丢弃 |
| BACKLOG_TICK_SECONDS | 30 | read_report.lua:86 | 补报节奏与正常阅读不可区分 |
| pending_backlog cap | 3h | read_report.lua:525 | 超长单段时长是典型异常标记 |
| backoff ramp | 30s→60s cap | read_report.lua:326-331 | 弱网失败风暴是可观测异常模式 |
| FAILURE_DEGRADE_TIMEOUT | 4s | read_report.lua:34 | UI 体验与请求节奏的平衡点 |
| SUSPEND_EXCLUDE_THRESHOLD_SECONDS | 30 | read_report.lua:54 | 睡眠误报是严重异常时长 |
| RENEWAL_COOLDOWN_SECONDS | 10min | read_report.lua:43 | 续期频率 |
| USER_AGENT | Edge-Windows | v4.0 | 与 app_id 迁移配套，勿单独改动 |

---

## 附录 A：评估依据来源

| 参数 | 来源 |
|---|---|
| K4 规格（i.MX508/800MHz/256MB/600×800/AR6103） | MobileRead Wiki（v2 报告沿引） |
| K5 规格（i.MX508 同代/256MB Hynix/2GB flash/AR6103 b/g/n/4 向+中键） | MobileRead Wiki "Kindle 5" 页面 |
| KOReader 2026.07 "Sailing Walrus"（非触摸 D-pad 改进 #11749、2026.07.01 修正版） | KOReader GitHub Releases / 开发者博客 |
| 代码证据 | 本仓库 v0.6.0-k4-v5.0 逐文件核实（2026-09-05） |

## 附录 B：权重模型（补全 v2 截断部分）

**维度权重**（K4/K5 双机 + 版本锚定 + 风控场景）：

| 维度 | 权重 | 升降规则 |
|---|---|---|
| 性能（UI 阻塞/GC/IO） | 35% | 单核 800MHz + 单线程 UI：任何 >500ms 的 UI 线程工作直接进入 P0/P1 候选 |
| 稳健性（丢进度/死机/状态串扰） | 25% | 丢进度类（S-02）不低于 P0；状态串扰按防护现状评级 |
| **风控（服务端异常模式 → 账号风险）** | **20%（新增）** | 一切改变请求节奏/时长语义/凭证行为的改动需对照第九节红线；时钟/节奏类风险按"服务端可观测性"评级 |
| 工程质量（测试/CI/文档） | 12% | 补丁式演进的根源项，维持 P0 直到测试基建落地 |
| 隐私（日志/凭据/路径） | 8%（下调） | 单用户自有设备：仅当"≤5 行且不影响使用"时顺手修复，否则不占排期 |

**评级合并规则**：某项风险在多个维度同时命中时取最高维度评级；v2 → v3 的单项调整均在上文勘误说明中给出代码级依据。
