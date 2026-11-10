# Changelog / 变更日志

本文件记录微信读书 KOReader 插件（K4 分支）各版本的重要变更，条目采用中英双语，聚焦用户可见的功能与 Bug 修复。
All notable changes are documented here in both Chinese and English, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v9.11] - 2026-11-10

### Fixed / 修复

- 修复弱网下扫码登录因连接关闭被误判为失败、会话被中断的问题；无 HTTP 状态的请求一律视为传输暂态，继续轮询到会话过期。
  Fixed QR login being aborted when a weak-network poll hits a closed socket; requests without an HTTP status now stay pending until the session expires.
- 二维码对话框改为延迟 0.2 秒渲染并加入会话守卫，避免 Kindle 首帧刷新导致二维码显示不完整。
  Deferred QR dialog rendering by 0.2s with session guards to prevent first-frame clipping on Kindle.

## [v9.10] - 2026-11-10

### Fixed / 修复

- 扫码登录提示改为底部锚定条，不再遮挡二维码；取消、超时、失败、完成路径统一关闭提示。  
  QR login hints now appear as a bottom-anchored bar instead of covering the QR code; the hint closes on every exit path (cancel, timeout, failure, completion).
- weread-only 模式下「设置」等菜单项恢复可选：收敛菜单改用与完整菜单同源的 TouchMenu，子菜单、勾选态与方向键导航一致。  
  In weread-only mode, menu entries such as Settings are selectable again: the compact menu now uses the same TouchMenu as the full menu, with working submenus, checkmarks and D-pad navigation.

## [v9.9] - 2026-11-10

### Fixed / 修复

- Cookie 续期不再在服务端确认失效会话却返回无效会话密钥时误报成功。  
  Cookie renewal no longer reports success when the server acknowledges a dead session but returns an invalid session key.
- 重新登录后自动清除页脚「登录已过期」提示并恢复阅读时长上报。  
  After a successful re-login, the "login expired" footer hint is cleared and reading-time reporting resumes automatically.
- 二维码登录无需扫码即可用 Back 取消、Menu 退出 KOReader。  
  QR login can be cancelled with Back or quit with Menu without scanning.
- 服务端返回重复 Set-Cookie 头时不再误判续期状态。  
  Renewal state is no longer misjudged when the server sends repeated Set-Cookie headers.

## [v9.8] - 2026-11-08

### Added / 新增

- 菜单回落显式记录错误；启动标记删除失败时下次启动自动重试。  
  In-app menu fallback now logs an explicit error; the launch marker is retried on the next start if removal failed.
- 新鲜度判定兼容时钟回拨；发布打包拒绝脏工作区或未打 tag 的提交。  
  Freshness checks handle backwards clock jumps; release packaging refuses dirty or untagged trees.

### Fixed / 修复

- 后台书架同步在已打开页面原地刷新，保持当前页码。  
  Background shelf sync refreshes the already-open shelf in place, keeping the current page.
- ReaderUI 重建后不再重复包裹关书回调。  
  Reader UI rebuilds no longer wrap the close handler twice.

## [v9.7] - 2026-11-08

### Added / 新增

- weread-only 菜单新增「Reading style」，直达字号、字体、行距与边距设置。  
  "Reading style" entry in the weread-only menu opens the native font, size, line spacing and margin settings directly.

## [v9.6] - 2026-11-08

### Fixed / 修复

- 书架刷新与下载完成后的指示器更新不再跳回第一页。  
  Shelf refresh and post-download indicator updates no longer jump back to the first page.

### Added / 新增

- 后台同步原地更新已打开的书单并保持翻页位置。  
  Background sync updates the open book list in place, preserving the page position.

## [v9.5] - 2026-11-08

### Added / 新增

- weread-only 菜单末尾新增「Exit KOReader」退出项。  
  "Exit KOReader" entry at the end of the weread-only menu.

## [v9.4] - 2026-11-08

### Fixed / 修复

- 未登录设备首次启动 weread-only 时直达二维码登录，不再卡在不可达的书架。  
  On a never-logged-in device, weread-only start opens QR login directly instead of an unreachable bookshelf.

## [v9.3] - 2026-11-08

### Added / 新增

- weread-only 模式下关书返回书架；Menu 键打开收敛的微信读书菜单。  
  Closing a book in weread-only mode returns to the bookshelf; the Menu key opens the compact WeRead menu.

## [v9.2] - 2026-11-08

### Added / 新增

- 书架分页懒加载，万本级大书架首次打开与翻页保持流畅。  
  Lazy, paged shelf loading keeps large libraries responsive on first open and while paging.

### Changed / 变更

- 同步成功后五分钟内跳过后台书架同步，减少等待与耗电。  
  Background shelf sync is skipped for five minutes after a successful sync, reducing waiting time and power use.

## [v9.1] - 2026-11-08

### Added / 新增

- weread-only 启动默认打开上一本微信读书书籍。  
  weread-only start reopens the last WeRead book by default.

### Changed / 变更

- 书架立即展示本地缓存并在后台静默同步；启动延迟缩短。  
  The shelf shows the local cache immediately and syncs online in the background; autostart delay shortened.

## [v9.0] - 2026-11-08

### Added / 新增

- 新增 weread-only 启动模式（配合 K4weread 扩展），一键进入仅微信读书与必要设置的会话，Home 键打开书架。  
  weread-only launch mode (with the K4weread extension): a single entry into a session containing WeRead and essential settings only, with Home opening the bookshelf.

## [v8.4] - 2026-10-31

### Fixed / 修复

- 回退 v8.3 的自定义 socket 创建（明文请求发往 HTTPS 端口致全部请求失败）；请勿使用 v8.3 包。  
  Reverted the custom socket creation from v8.3, which sent plain HTTP to the HTTPS port and made every request fail; use this package instead of v8.3.

## [v8.3] - 2026-10-27

### Fixed / 修复

- 切换账号时清除旧账号的水印与账本，避免旧账号离线时长以新账号身份上报。  
  Switching accounts clears the previous account's watermarks and ledgers, so offline reading time is never reported under the new account.

### Changed / 变更

- 上报、重试与补报间隔加入小幅随机抖动。  
  Reporting, retry and catch-up intervals now include a small random jitter.

## [v8.2] - 2026-10-26

### Added / 新增

- CI 增加版本号一致性门禁，发布包附 SHA-256 校验和。  
  Version consistency gate in CI and SHA-256 checksums for release packages.
- Wi-Fi 图标改为反映真实链路（射频开启、已关联、已获取地址），不支持的设备自动回退原生行为。  
  Wi-Fi status icon now reflects an actual link (radio on, associated, address assigned), falling back to the native behaviour on unsupported devices.

### Fixed / 修复

- 跳页百分比保留小数，不再因四舍五入跨到相邻页。  
  Jump-to-percent keeps decimals instead of rounding to a neighbouring page.
- 进度上传校验账号指纹，丢弃此前登录账号的结果。  
  Progress uploads verify the account fingerprint and discard results from a previously logged-in account.
- 换章 30 秒内重开时跳过陈旧的远端进度比较。  
  Reopening a chapter within 30 seconds skips a stale remote position comparison.
- 离线预检改为链路态快查，不再阻塞 UI 线程。  
  Offline prechecks use a fast link-state query instead of blocking the UI thread.

## [v8.1] - 2026-10-20

### Added / 新增

- 新增本地故障注入网关与真实传输回归测试（慢响应、断连、空响应、错误码）。  
  Local fault-injection gateway and real-transport regression tests for slow, dropped, empty and error responses.

### Fixed / 修复

- 传输失败向上层返回真实错误，不再显示为空 HTTP 状态。  
  Transport failures now surface the real error instead of a blank HTTP status.

## [v8.0] - 2026-10-20

### Added / 新增

- 新增模块覆盖映射门禁：新模块必须声明 spec 或豁免理由。  
  Module-to-spec coverage gate: new modules must declare a spec or a documented exemption.
- 凭据改存独立 0600 权限文件，启动时自动迁移旧设置中的 cookies。  
  Credentials are stored in a dedicated 0600-permission file; cookies in the old settings are migrated at startup.
- EPUB 发布前校验归档，截断或空包不再覆盖有效书籍。  
  EPUB archives are validated before publishing, so truncated or empty archives never replace a valid book.

### Fixed / 修复

- 图片下载限制大小并在每个重定向跳复验域名白名单。  
  Image downloads are size-limited and re-validate the domain allowlist on every redirect hop.
- 进度同步进行中相关菜单项置灰。  
  Menu entries are disabled while progress sync is running.

## [v7.6] - 2026-10-05

### Added / 新增

- 新增设备指纹，避免同账号多设备互相踢下线。  
  Device fingerprint to avoid signing out other devices on the same account.
- 未显式设置语言时跟随 KOReader 运行时界面语言。  
  UI language follows the KOReader runtime locale when no explicit setting exists.
- 新增上报状态单键入口与开书耗时打点。  
  Single-key access to the report status and startup timing instrumentation.

### Fixed / 修复

- 整本下载存在失败章节时不再发布，保留续传状态并自动重下半写入章节。  
  Incomplete whole-book downloads are no longer published; spool state is kept and half-written chapters are re-downloaded.
- 续传重建分批处理，长书不再卡住 UI。  
  Resume scanning is batched so long books no longer freeze the UI.
- 增加版本号与构建标识一致性校验。  
  Version and build identifier consistency checks.

## [v7.5] - 2026-10-05

### Fixed / 修复

- 跨分区移动不再谎报成功或把缓存路径改写为不存在的位置。  
  Cross-partition moves no longer report false success or rewrite cache paths to non-existent locations.
- 超长离线时长跨会话续排不再丢弃；下载完成仅在目录缺失时写入。  
  Long offline reading time is carried across sessions instead of being dropped; download completion only writes the catalogue when missing.
- EPUB 与设置文件改为临时文件 + 原子改名发布，断电不留半写文件。  
  EPUB and settings files are published via temporary file plus atomic rename, preventing half-written files after power loss.
- 请求总时限、上报 tick 预算与预取超时收敛，消除长时间 UI 冻结。  
  Request deadlines, reporting tick budget and prefetch timeouts are bounded, eliminating long UI freezes.
- 瞬态网络错误单次重试；会话失效终止下载任务并提示登录。  
  Transient network errors are retried once; expired sessions stop the whole download and prompt for login.
- 休眠只依据生命周期事件判定，睡眠时间不再计为阅读时长。  
  Sleep is detected only from lifecycle events, so suspend time is no longer counted as reading.
- 批量书架操作只持久化实际变更记录，大幅减少闪存写入。  
  Bulk shelf operations persist only changed records, drastically reducing flash writes.

## [v7.0.1] - 2026-09-29

### Added / 新增

- 章节内联图片增加域名白名单，阻止任意 URL 抓取。  
  Domain allowlist for inline chapter images, preventing arbitrary URL fetching.

### Fixed / 修复

- 缓存路径校验与删除使用同一规范化路径，堵住目录穿越绕过。  
  Cache path validation and deletion now use the same normalized path, closing a traversal bypass.
- 手动登录模板沙箱在 Lua 5.2+ 不再静默失效；无沙箱可用时拒绝导入。  
  Manual-login template sandbox no longer silently fails on Lua 5.2+; imports are refused when no sandbox is available.
- 异步进度上传不再提前复位在途状态。  
  Async progress uploads no longer reset their in-flight state prematurely.

## [v7.0] - 2026-09-19

### Added / 新增

- 章节目录优先使用官方免登录网关接口，web 会话过期不再影响目录获取。  
  Chapter catalogue prefers the official gateway endpoint, so an expired web session no longer blocks chapter listing.
- 本地阅读账本自动修剪过期的日键。  
  Local reading ledger prunes old daily entries.

### Fixed / 修复

- 修复空 OTP 参数导致的间歇性扫码登录失败。  
  Intermittent QR login failures caused by an empty OTP query parameter.
- 设置落盘失败隔离；页脚提示与 Wi-Fi 图标不再互相覆盖；HTTP 重试每轮重建请求体。  
  Settings flush failures are isolated; footer hints and the Wi-Fi icon no longer overwrite each other; HTTP retries rebuild the request body each attempt.

## [v6.5] - 2026-09-18

### Added / 新增

- 新增 IPv4 优先 DNS 与解析类错误单次重试（K4 无 IPv6 协议栈）。  
  IPv4-first DNS resolution with a single retry on resolution errors (K4 has no IPv6 stack).
- 会话过期时页脚常显提示与状态行提示。  
  Persistent footer hint and status line when the session expires.

### Fixed / 修复

- 连续失败后自动上报暂停，并在网络恢复、重登、重启或上报成功时恢复。  
  Automatic reporting pauses after repeated failures and resumes on network recovery, re-login, restart or a successful report.
- 进度拉取失败如实记录，不再伪装为「进度一致」。  
  Failed progress pulls are recorded as failures instead of a false "positions match".
- 进度拉取优先官方网关，避免 cookie 过期时的重复请求。  
  Progress pulls prefer the official gateway, avoiding duplicate requests when cookies have expired.

## [v6.0] - 2026-09-16

### Added / 新增

- 新增本地阅读时长账本与统计页对账卡。  
  Local reading-time ledger with an on-screen reconciliation card.
- 设置写入增加快照、校验与失败恢复；Cookie 续期四态分级；预取连续失败触发冷却。  
  Settings write snapshots with verification and recovery; cookie renewal distinguishes four outcomes; repeated prefetch failures trigger a cooldown.
- Wi-Fi 图标与页码共存，禁用时还原原页脚设置。  
  Wi-Fi status icon coexists with the page number and restores the original footer settings when disabled.
- 新增强制门户检测与设备身份诊断。  
  Captive-portal detection and device identity diagnostics.

### Changed / 变更

- 后台预取请求超时放宽，前台请求仍快速失败。  
  Background prefetch requests use a longer timeout; foreground requests still fail fast.

## [v5.7] - 2026-09-13

### Added / 新增

- 状态栏新增可选 Wi-Fi 连接图标（默认关闭）。  
  Optional Wi-Fi connectivity icon in the status bar (off by default).

## [v5.6] - 2026-09-05

### Fixed / 修复

- 脚注收集拒绝整章级候选与返回箭头定义；书籍样式表中的零字号规则不再导致全书空白。  
  Footnote collection rejects chapter-sized candidates and stray back-arrow definitions; zero font-size rules in book stylesheets no longer render books blank.
- 公众号图片流式落盘，附域名白名单与单图大小上限，降低内存峰值。  
  Article images stream to disk with a domain allowlist and a per-image size cap, reducing peak memory.

## [v5.5] - 2026-09-05

### Changed / 变更

- 书籍更新改为单记录写盘，消除菜单与翻页卡顿；请求头合并改为线性复杂度。  
  Book updates write a single record instead of the whole table, removing menu and paging stalls; headers merge in linear time.
- 弱网下上报间隔与请求超时自动收敛，恢复后自动还原。  
  Weak-network reporting intervals and request timeouts contract automatically and recover afterwards.

### Fixed / 修复

- 修复定时器泄漏、时钟回拨异常、多设备同步默认值与菜单状态滞留。  
  Timer leaks, clock-rollback anomalies, multi-device sync defaults and stale menu state.
- 日志脱敏、缓存路径白名单与 Cookie 头校验。  
  Log redaction, cache path allowlist and cookie header validation.

## [v5.0] - 2026-08-29

### Added / 新增

- 新增前台交互屏障（翻页优先）、脚注显示位置设置与目录缓存回退。  
  Foreground interaction barrier (paging takes priority over background downloads), footnote placement setting, catalogue cache fallback.

### Fixed / 修复

- 章节目录跳转支持四级兜底，旧缓存无需重新下载。  
  Chapter navigation now resolves the selected chapter (four-level fallback, existing cached books need no re-download).
- 修复重下后目录缺失、Back 需逐层关闭弹窗、网络未就绪时自动拉取静默失败。  
  Missing catalogue after re-download, Back needing to close stacked dialogs one by one, and silent auto-pull failures before the network is ready.

## [v4.5] - 2026-08-26

### Added / 新增

- 新增脚注显示位置设置（章节末尾 / 页面底部+章节末尾）。  
  Footnote placement setting (end of chapter / page bottom plus end of chapter).

### Fixed / 修复

- 弱网下减少上报写盘、错峰翻页与上报、收敛退避与超时；修复重下后的自动同步与章节跳转。  
  Weak-network reporting write volume, paging/report tick interleaving, retry backoff and timeouts; automatic sync and chapter jumps after re-download.

## [v4.0] - 2026-08

### Added / 新增

- 整本下载逐章流式落盘，峰值内存降至单章。  
  Whole-book downloads stream chapter by chapter to disk, with peak memory reduced to a single chapter.
- 新增断点续传（进度文件 + 续传/重下询问）。  
  Resume support with progress files and a resume/restart prompt.
- 新增 SQLite 离线索引与离线书架。  
  SQLite offline index and offline bookshelf.

### Fixed / 修复

- 章节下载失败自动重试一次；磁盘满时校验目录写入。  
  Chapter downloads retry once on transient failures; catalogue writes are validated when disk is full.

### Changed / 变更

- 阅读时长补报上限与节奏保守化，失败退避改为指数增长。  
  Reading-time catch-up limits and pacing are conservative, with exponential failure backoff.

## [v3.5] - 2026-08

### Fixed / 修复

- 离线阅读时长跨会话不再丢失或重复计算。  
  Offline reading time is no longer lost or double-counted across sessions.

### Added / 新增

- 新增清理旧版本遗留阅读时长积压的脚本（自动备份）。  
  Cleanup script for stale reading-time backlog accumulated by older versions (with automatic backup).

## [v3.0] - 2026-08

### Fixed / 修复

- 迁移失败不再清除章节目录；跨文件系统移动不再误删源文件；磁盘满时不再写出损坏元数据。  
  Failed migrations no longer erase chapter catalogues; cross-filesystem moves no longer delete sources prematurely; full disks no longer produce corrupt metadata.
- 修复孤儿控件、复选框状态不刷新、路径穿越与若干空值崩溃。  
  Orphaned widgets, stale checkbox states, path traversal and several nil-handling crashes.

### Changed / 变更

- MD5 常量硬编码，消除跨平台浮点精度差异。  
  MD5 constants are hardcoded to avoid cross-platform floating-point differences.

## [v2.5] - 2026-08

### Fixed / 修复

- 修复下载异常导致无法休眠、睡眠时间误报为阅读时长、进度同步死锁、离线时长丢失/串书/超上限上报及配置损坏。  
  Download failures no longer prevent sleep; suspend time is no longer reported as reading time; progress sync deadlocks, missing or dropped offline time, cross-book contamination, over-limit reports and corrupt settings are fixed.

### Changed / 变更

- 提升 base64 解码速度，缓存书架与目录读取，减少网络唤醒。  
  Faster base64 decoding, cached shelf and catalogue reads, and fewer network wake-ups.

### Security / 安全

- 登录模板沙箱、去 shell 化缓存清理、Cookie 仅限 HTTPS、日志脱敏与跨域凭据清理。  
  Sandboxed login templates, shell-free cache cleanup, HTTPS-only cookies, header/URL redaction and cross-origin credential stripping.

## [v2.0] - 2026-08

### Added / 新增

- K4 分支首个稳定版：全按键操作、快捷菜单、手动登录模板、离线时长上报与补报、按键驱动的阅读统计。  
  First stable K4 release: full keyboard operation, quick menu, manual login template, offline reading-time reporting with catch-up, keyboard-driven statistics.

### Removed / 移除

- 移除划线、想法、书评等触摸专属功能。  
  Touch-only features such as highlights, thoughts and book reviews.

## [v1.5] - 2026-08

### Changed / 变更

- 优化快捷菜单（ScreenKB+Down）的可用性。  
  Improved the quick menu (ScreenKB+Down) and its usability.

## [v1.0] - 2026-08

### Added / 新增

- 面向 Kindle 4 / Kindle 5 非触摸设备的初始适配，全按键导航。  
  Initial port for non-touch Kindle 4 / Kindle 5 devices with full key-driven navigation.
