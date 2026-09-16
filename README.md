# WeRead KOReader Plugin · K4 分支（v0.6.0-k4-v5.7.2）

> **免责声明**：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担。请遵守微信读书的用户协议和相关法律法规。

在 KOReader 上阅读微信读书书籍和公众号文章、同步阅读时长的插件。

## 项目来源

本分支 fork 自 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)（AGPL-3.0），K4 非触摸适配分支独立维护于 [dororo42/weread_K4.koplugin](https://github.com/dororo42/weread_K4.koplugin)。
- 基线：官方 **v0.6.0**（含个人 K4 适配补丁）
- 上游最新：**v1.4.0**（本分支**不完全跟随**，脚注双修复已随 v5.6 对齐；见「与主线 v1.0.0 的差别」）

## 本分支定位

面向 **Kindle 4（非触摸）** 等无触摸屏设备：
- 全交互按键可操作（方向键 + 确认 + 返回 + 键盘数字行），无触摸手势依赖
- **使用按键 ScreenKB+Down，唤出"快捷菜单"**
- 针对Kindle4硬件配置，优化代码执行效率
- 离线优先：离线阅读时长上报、离线缓存阅读
- 精简功能面：去掉触摸设备才用得到的划线/想法、书评等

---
## 安装

1. 将 `weread_K4.koplugin` 文件夹复制到 KOReader 的 `plugins` 目录：
   ```
   koreader/plugins/weread_K4.koplugin/
   ```
2. 重启 KOReader，在菜单中找到 `工具 → 微信读书`。

> 已在 **KOReader 2026.07.1**（"Sailing Walrus" 修正版）+ Kindle 4 / Kindle 5（非触摸）实测验证。

---

## 登录

- **扫码登录**为推荐方式，扫码前需在微信读书 App 中开通微信读书 Skill 并获取 API Key。
- 【手动登录】（USB 模板导入）保留作备用。USB 连接后编辑 `koreader/settings/weread_manual_login.lua` 模板文件，重启或「立即导入」
---
## 快捷菜单

阅读**微信读书缓存书籍**时，**可随时调出「微信读书·快捷菜单」面板**，集中入口常用操作。
**首次使用**需从从菜单书架阅读第一本书开始。

**调出方式：**
- **ScreenKB + Down**：阅读微信读书书籍时按此组合键调出。仅在打开微信读书书籍时覆盖 KOReader 默认的「书籍地图」。
- **末页自动弹出**：读到章节末页或全书末页时自动弹出。

| 行 | 按钮 | 说明 |
|----|------|------|
| 1 | 书架 / 已下载书目 | 书架=云端（需联网）；已下载=本地列表（离线可用） |
| 2 | 书籍详情 / 章节目录 | 章节可直接跳章阅读，未缓存自动下载 |
| 3 | 阅读统计 / 搜索 | 阅读统计页；搜书 |
| 4 | 立即同步进度 | 上传/拉取云端进度 |
| 5 | 上报状态 / 关闭书籍 | 查看上报状态；关闭当前书 |

>关于**搜索**：K4 上中文输入受限，推荐通过书架浏览，默认按最新顺序。

>阅读时的文本搜索，使用Koreader自带功能：按 Up/Down 进入「内容选择」模式→ 方向键选中文中某词 → 确认弹出操作菜单 → 选「搜索」→ 直接搜选中文字。

## 键盘操作速查

Kindle 4（K4）实体键只有：5 向 D-pad、左右翻页键、Home/Back/Menu/Keyboard(ScreenKB) 按钮。

**快捷面板（微信读书·快捷菜单）**：阅读微信读书缓存书籍时，可随时按 **ScreenKB + Down**（D-pad 下方向键）调出快捷面板；读到末页也会自动弹出。
该组合仅在打开微信读书书籍时覆盖 KOReader 默认的「书籍地图」，非微信读书书籍仍走默认。

### K4 阅读时按键速查（KOReader + hotkeys.koplugin + 本分支改动）

| 键 | 功能 |
|----|------|
| Left / Right（单键） | 上一章 / 下一章（使用**阅读统计**时，为翻上一/下一周期）|
| Up / Down（单键） | 切换「内容选择」模式（查词/高亮） |
| LPgFwd / RPgFwd | 下一页 |
| LPgBack / RPgBack | 上一页 |
| Back | 返回/关闭（也关闭全屏对话框） |
| Home | 文件管理器 |
| Menu | **顶部菜单** |
| Press（确认键） | **底部菜单**（使用**阅读统计**时，为循环切换 周/月/年/总） |
| ScreenKB + Up | 目录 |
| ScreenKB + Right | 添加书签 |
| ScreenKB + Down | **微信读书快捷菜单**（本分支，仅 WeRead 书；默认为书籍地图） |
| ScreenKB + Left | 书签/笔记/高亮 列表 |
| ScreenKB + Press | 保存当前页到位置历史 |
| ScreenKB + Home | 开关 Wi-Fi |
| ScreenKB + Back | 切换到上一本书 |

---
## 菜单结构

```
微信读书
├── 书架
├── 搜索
├── 阅读时间上报
│   ├── 启用阅读时间上报（默认勾选，v2.x 起）
│   ├── 仅在阅读时上报
│   ├── 选择目标书籍（自动关联（默认） / 手动设置）
│   └── 上报状态
├── 阅读统计
├── 设置
│   ├── 缓存管理（扫描并关联本地书籍 / 缓存清理 / 缓存目录）
│   ├── 进度管理（打开时拉取进度 / 关闭时上传进度）
│   ├── 下载设置（书籍图片 / 公众号文章图片 / 章节预下载）
│   └── 账号管理（账号状态 / 手动登录 / 立即续期 Cookie / 清除账号数据）
├── （阅读微信读书缓存书籍时插入）
│   ├── 立即同步进度
│   └── 书籍详情
├── 已登录 · 账号名 / 微信扫码登录   （菜单末尾）
└── 关于（v0.6.0-k4-v5.6）          （菜单末尾）
```

## 阅读时长上报

> **默认启用**（v2.x 起）：全新安装后默认开启并自动关联当前书籍。如不需要可在菜单关闭。

离线时长已持久化：关书、重启、挂起唤醒后不丢失，联网后自动补报。上报状态可在 `阅读时间上报 → 上报状态` 查看。

本地另有按书按天的**阅读时长账本**（v5.7.2 起，官方客户端同款"先记账后上报"）：阅读统计页的「本地阅读账本」卡片展示设备已记账时长与同周期服务端确认时长，两者差距持续增大即"上报未打通"预警。

---

## 版本变更日志

### v5.7.2（2026-09-16）· reMarkable 官方客户端借鉴（时长统计 P0：本地阅读账本）

> 对应《K4_remarkable官方v1.0.0_网络通信与时长统计借鉴评估 v2》P0 项 B1。官方客户端在本地 SQLite `reading_progress.reading_time` 按书持久化阅读时长（开书即记账、上报失败不影响账目），服务端心跳之外始终有一份可离线展示、可对账的记录；K4 此前只有服务端视角的 watermark。

- **B1 · 本地阅读时长账本**：新增 `weread/lib/stats_ledger.lua`（纯 Lua 按天账本，`read_report.ledgers[book_id] = { [YYYYMMDD] = 秒 }`，经 settings 落盘、B11 原子 flush 抗损，合并 flush 节奏与 watermark 一致——每 30s 至多一次写盘，无 SQLite 每 tick 开销）。
- **记账时机（对齐官方"先记账后上报"）**：
  1. **服务端确认即记账**——每次上报被接受（watermark 前进 `reported_seconds`）时，把该秒数记入当日账（`_apply_outcome`）；
  2. **离线会话即记账**——`stop()`（关书/挂起/切书）时，把本会话未发送的阅读时长（`last_active_at - watermark`，≤24h 封顶）记入当日账；watermark 机制保证这些秒数随后仍会被补报，账本只是让它们在离线期间可见。
- **统计页对账卡**：阅读统计页新增「本地阅读账本」卡片（Overview 之后）——"设备已记账" vs "服务端已确认（本周期）"，本地多出的部分给出解释文案：未发送积压通常联网后自动补报，差距持续增大即上报被吞预警。数据经 `ReadStats.fetch(..., ledger)` 注入，无账本（如未登录）时卡片自动隐藏。
- **测试**：`spec/stats_ledger_spec.lua`（记账/封顶/按日聚合/跨书求和/快照只读/flush 调度/apply_outcome 记账联动）。


### v5.7.1（2026-09-16）· reMarkable 官方客户端借鉴（网络通信 P1 批次）

> 依据《K4_remarkable官方v1.0.0_网络通信与时长统计借鉴评估 v2》（项目根目录）。本轮为 P1 批次（B11/B2/B4/B5/B12）；P0 项 B1（本地时长账本）另行实施；B3（JSON 直报降级通道）按报告约束在真机抓包验证前不实施。

- **B11 · settings 落盘抗损加固**：`Settings:flush()` 在框架写入前快照 `weread.lua`，写入后校验文件存在且非空，失败时恢复快照并告警（官方 auth.json temp+rename 原子写同款目标；LuaSettings 原地写遇掉电会截断配置=登录态丢失）。对已内置原子替换的 KOReader 构建自动退化为两次属性检查。历史上全部 flush 调用点已在 pcall 内，失败重抛不改变调用方行为。
- **B2 · 会话续期分级（官方 -2013 状态机借鉴）**：`client.renew_cookie` 失败不再一律当"认证失败"——按官方四态分类 `replaced / stale（HTTP OK 但 succ!=1，凭据仍有效，保留不误清）/ expired（401/403 或会话类错误，需要重新扫码）/ network（传输层失败，凭据未知但保留）`，通过 `result._renewal_outcome` 与 `outcome.renewal_status` 带出；`read_report` 据此把 error_kind 细化为 `renewal_network / renewal_stale / renewal_expired`，`上报状态` 暴露 `last_renewal_status`。K4 既有的 auth fingerprint 竞态防护与 10 分钟续期冷却保持不变。
- **B5 · captive portal 显式判定（官方空 uid 判定借鉴）**：getLoginUid 返回 HTTP 200 但 uid 为空时（portal 劫持响应的典型签名，官方 "doRequestUid got empty UID (captive portal?)" 同款），扫码登录给出专门提示"当前网络似乎需要网页认证（强制门户）"并标记 `last_login_error_kind=captive_portal`；手机热点/公共 WiFi 场景不再误报为通用登录失败。i18n 已配中文词条。
- **B4 · 登录设备身份留档（官方 deviceId/deviceName 借鉴，K4 适用面收敛）**：首次生成稳定 uuid `device_id`（持久化 `<dataDir>/weread/weread_device_id`）与固定名 `Kindle K4 - weread_K4`，扫码登录成功后写入 account 记录（`device_id/device_name` 字段，诊断用途）。注：K4 走 Skill API 登录流，无 /weblogin 等价请求可提交设备三元组，故不做服务端设备注册；设备名如实申报，不伪装官方客户端。
- **B12 · TLS SECLEVEL 坑位档案**（见下方「移植坑位档案」节）。
- **知识档案 · 原生通道与 web 通道不可混用**：官方 reMarkable 客户端使用原生 UA `WeRead/1.0.0 WRBrand/remarkable wr_eink` + /weblogin 颁发的 accessToken/refreshToken，不走 web 端 s/sg 签名；K4 的 web 签名通道（Chrome UA，web_app_id 由 UA 派生）与之是两条自洽通道，不可混用。若未来 web 签名被服务端风控，"设备登录通道"是官方认证过的备用路线（K4 qr_login 已拿到 accessToken/refreshToken，改造有起点；需真机验证 /weblogin 对第三方客户端的行为）。

### 移植坑位档案（B12 · TLS SECLEVEL）

官方包 `payload/config/openssl.cnf` 内的实测排查记录，摘录归档：

- **现象**：`weread.qq.com`（登录/扫码域名）握手直接失败 `alert 40 (handshake_failure)`；同一网络下 `i.weread.qq.com` / `wo4.weread.qq.com` 完全正常——表现为"部分域名连不上"而非网络故障，极易误判为设备网络问题。
- **根因**：`weread.qq.com` 只支持 TLSv1.2（`-tls1_3` 得 alert 70），且其接受的密码套件 `ECDHE-RSA-AES128-GCM-SHA256` 在 OpenSSL 3.x 默认 `SECLEVEL=2` 客户端策略下被排除。
- **官方解法**：应用级 `OPENSSL_CONF` 指向自带 cnf，`CipherString = DEFAULT@SECLEVEL=1`（仍要求 ECDHE + AEAD + 合法证书链）；不改 `/etc/ssl/openssl.cnf` 全局（会被 OTA 覆盖且降低整机安全等级）。
- **K4 适用性**：Kindle K4 固件时代的 OpenSSL 默认接受老套件，当前无此问题。触发条件（对号入座）：未来把插件移植到 OpenSSL 3 构建的 KOReader（新设备/新版固件）且出现"登录域名握手失败但 API 域名正常"。KOReader 侧可用 `ssl.wrap(params)` 的 protocol/ciphers 参数或启动环境变量解决，同样不要动全局。


### v5.7 补遗（2026-09-14）· FM 模式位置修复 + 健壮性加固（审计驱动）

- **FM 存储路径修复（P0）**：`footer_indicator.apply_to_store` 此前硬编码 `reader_footer_mode = 11`（MODE 常量值），但官方 `reader_footer_mode` 语义是 **mode_index 的 0 基位置**，且设备门控会先行剔除不支持的项——无前光的 K4 上 `wifi_status` 实际位置是 **10**，硬编码 11 会在文件管理器场景启用后静默指向 `book_title`（图标不显示）。现改为**运行时计算位置**：镜像官方 `set_mode_index` 逻辑（设备能力门控 `hasFastWifiStatusQuery`/`hasFrontlight`/`hasNaturalLight`/`hasBattery` + 可选自定义排序 `footer.order`），无自定义排序时 K4 得 10、有前光设备得 11、自定义排序按保存顺序。
- **接口探测加固（新报告「中」项）**：`apply_to_footer` 对 `updateFooterTextGenerator`/`refreshFooter` 增加存在性探测，缺失时降级走 `onUpdateFooter` 通用重绘；`device_supports` 对探测错误保守判为不支持，不再假设可用。
- **CI 语法哨兵**：新增 `luac -p`（严格 Lua 5.1）全量语法检查步骤，与既有 busted/luacheck 并列。
- **README**：上游版本号同步 v1.3.0 → v1.4.0（脚注双修复已随 v5.6 对齐）。
- **测试**：`footer_indicator_spec` 新增 7 用例（设备门控位置计算 ×2 / 自定义排序镜像 / 门控项跳过 / 无 device 模块回退 / 探测错误保守化 / FM 路径持久化计算值 / 自定义排序持久化 / 既有断言修正为计算值）。

### v5.7（2026-09-13）· 状态栏联网状态图标（复用 KOReader 内置项，紧凑设计）


- **新功能**：设置菜单新增「状态栏联网状态图标」开关，开启后阅读页底部状态栏显示 Wi-Fi 连接/断开小图标（KOReader ReaderFooter 内置 `wifi_status` 项，v2026.07.1 源码级验证 K4 门控 `hasFastWifiStatusQuery=yes` 通过，默认关闭）。
- **紧凑设计（v5.7 定稿）**：**绝不触碰 `all_at_once`**——默认单显模式下 7 个状态项全亮会挤爆 800px 状态栏。改为：开启时把单显模式**直接切到 wifi 图标**（状态栏只剩一个小图标+进度条，最小视觉足迹；关闭时自动切回页码，对称可逆）。依据：K4 非触摸无法轮换单显模式（footer 触区不可用、"Toggle mode"菜单项仅在触区归零时出现），"加入轮换"等于永远不可见。
- **实现（零 patch、零自绘控件）**：新增 `weread/ui/footer_indicator.lua` 胶水层，逐分支对齐内置开关的刷新簿记（`set_has_no_mode` → `applyFooterMode`/`updateFooterTextGenerator` → `refreshFooter` → `rescheduleFooterAutoRefreshIfNeeded`），并即时 `flush` 全局设置防掉电丢失。
- **文件管理器降级路径**：FM 无实时 footer，写全局 `G_reader_settings`（缺表时以 `readerfooter.default_settings` 完整种子，绝不写半截表；同步写 `reader_footer_mode` 使下次开书图标直接可见），开书生效并弹提示。
- **语义边界**：图标反映 Wi-Fi 射频/链路状态（`NetworkMgr:isWifiOn`，sysfs 级非阻塞查询），**不等于**互联网可达（`isOnline` 需阻塞 DNS，与阅读循环互斥）；被动断网的图标刷新滞后 ≤1 分钟或一次翻页。
- 手动等价路径：KOReader 顶部菜单 → 设置 → 状态栏 → 状态栏项目 → 勾选「Wi-Fi 状态」；如需页码与图标同时显示，可自行开启「全部同时显示」。
- **测试**：新增 `spec/footer_indicator_spec.lua`（21 用例：刷新簿记契约含 MODE 顺序桩、单显切换/塌缩/恢复/过渡分支、FM 存储降级与 mode 持久化、缺省值种子、flush 容错），全套 spec 与 luacheck 通过。

### v5.6（2026-09-05）· 脚注双缺陷修复 + 公众号图片流式（对齐上游 v1.4.0）

**移植上游 finlater/weread.koplugin v1.4.0 的两项脚注修复（P0，by @baily-zhang）**：
- **脚注定义收集加固（PR #133）**：修复三类叠加缺陷——①章节根包装块（如双语书的 `<div id="root">` 包住全章）把"整章拍平文本"当注释内容，先到先得挤掉真注释；②与注释共享 id 的返回箭头（"↩/←"）占用定义槽，生成"只剩箭头"的脚注；③整章级候选无大小上限。移植后按码点判断纯符号（假名/谚文/西里尔/扩展区汉字等一切真文本均保留，仅全符号候选被拒）、单条注释 6000 字节上限、同锚点更短候选胜出（真注释是最小描述区域）。
- **服务端书籍 CSS 清洗（PR #137）**：部分书籍的 e_2 样式表带 `html, body { font-size: 0 }`，WeRead 自家 App 忽略根元素字号而 crengine 遵守，导致全书字号塌缩（症状：打开书全是空白）。下载时按平衡花括号扫描，仅当选择器列表**恰好只有 html/body**（`body p`、`body, .wrapper` 等复合选择器不碰）时剔除零值 font-size 声明（`0`/`0px/0vh`/含 `!important` 均算；`0.5rem` 等分数值不受影响），其余规则逐字透传，多轮迭代至不动点。
- ⚠️ **已下载的缓存书籍不会自动修复**（转换发生在下载时）：受脚注/CSS 问题困扰的书需**删书重下**。

**吸收上游 PR #132（公众号图片）**：
- **流式落盘**：文章图片改为逐张写入文章旁的 `<标题>.assets/` 目录、HTML 相对引用，不再 base64 内嵌——此前二进制 + 编码副本全程驻留内存，多图长文在 K4/K5 的 256MB RAM 上逼近 OOM；现在峰值占用为单图。
- **URL 白名单锚定**：图片源白名单锚定到 `https?://mmbiz.qpic.cn/` 与 `mmbiz.qlogo.cn/` 双域（原先的不锚定匹配可被 `//evil.com/?x=mmbiz.qpic.cn` 类 URL 绕过）。
- **单图上限**：64MB（对齐上游），超限丢弃并记日志；下载失败保留原始引用。

**测试**：新增 `spec/footnotes_spec.lua`（#133 七组回归，含双语书污染/shortest-wins/箭头共享 id/多文字系统/纯符号拒绝/双模式渲染）、`spec/content_css_sanitize_spec.lua`（#137 全部断言）、`spec/mp_images_spec.lua`（#132 锚定/流式/上限/失败兜底），全套 51 个用例通过；`PluginUtil.mkdirs` 顺带容忍 Windows 风格路径（盘符/反斜杠，生产 KOReader 无感知）。

**CI 接入与修复（2026-09-05 ~ 09-06，`101405e`/`3a57bbe`/`55b2c7d`/`3657b83`）**：
- CI 首次接入撞了两轮墙并全部对症修复：① CI 的标准 Lua 5.1 不支持 `\x` 转义（spec 的 PNG 魔数改十进制转义；本地 LuaJIT/5.3+ 不报错，CI 是**兼容性哨兵**）；② luarocks 把依赖装进项目目录 `.luarocks/` 被 `luacheck .` 全仓误扫（改显式白名单 `luacheck weread spec tools main.lua _meta.lua`）。
- lint 首跑清出 **70 条历史警告**（清零），并顺带修复 **3 个真隐患**：整本书下载的脚注 CSS 引用未定义全局 `footnotes_mode` 导致始终取 PAGE 样式（与章节转换的 chapter 模式不匹配）；选书列表的 `refresh` 回调引用永远未赋值的局部 `menu`（工具栏刷新即崩）；死函数 `normalize_void_elements` 清理。
- CI 加固：`concurrency` 防过时 run 排队；`.gitignore` 补 `.luarocks/`、`.luacheck_cache`、`*.zip`；README 新增「开发与测试」节（新 spec 必须遵守 Lua 5.1 语法子集）。
- **设备部署说明**：`spec/` 与 `.luacheckrc` 属开发资产，KOReader 只加载 `main.lua` + `_meta.lua` + `weread/`；发布包已按运行时清单打包（见「开发与测试」节）。

### v5.5（2026-09-05）· 按综合评估报告 v3 修复

**适用设备**：Kindle 4 / Kindle 5（同代硬件，i.MX508 · 800MHz 单核 · 256MB RAM · 非触摸）。

**性能（K4/K5 翻页与菜单卡顿）**
- **`set("books")` 全表重写收敛（S-20）**：书籍详情、公众号缓存、章节目录、下载完成、账号解析等 8 处"改一本、写全表"的路径改为 `set_book`/`remove_book` 单记录写盘（此前每次改动会把所有书的 JSON 各重写一遍，K4 慢 flash 上 0.5-2s）。缓存目录移动、扫描导入、清空全部等批量操作保留原路径。
- **弱网节奏（S-12 + P0-1）**：连续失败 ≥4 次后上报 tick 拉长到 120s（时长不丢失，watermark 兜底）；连续失败 ≥5 次后单请求超时在 4s 基础上再降到 2s，恢复后自动还原。
- **headers 合并 O(n²) → O(n+m)（S-19）**。

**稳健性（丢进度/状态串扰/泄漏）**
- **`_books_cache` 契约化（S-02）**：`get("books")` 返回共享缓存属有意设计，已写入显式契约注释；新增 `Settings:mutate_book(book_id, fn)` 事务式修改入口与 `Settings:remove_book(book_id)` 单条移除。
- **`_G` 全局状态收口（原#2）**：新增 `weread/lib/global_state.lua`，章节跳转意图、插件对话框栈、前台屏障三处 `_G` 散槽合并为单一命名空间；对话框栈增加 16 条上限防长会话无界增长（S-21）。
- **定时器泄漏（S-05）**：阅读上报水印/上下文合并 flush、进度同步合并 flush 四处 30s 定时器保留引用，关书/停止时统一 `unschedule`（此前关书后实例最长被钉住 30s）。
- **时钟回拨守卫（S-03，风控相关）**：域逻辑仍用墙钟，但检测到时钟倒退越过 watermark 时跳过当次上报，杜绝"幽灵 30s 时长"这类服务端可观测的异常模式（读时永不丢，watermark 兜底）。
- **多设备进度（S-18）**：`pull_on_open`/`upload_on_close` 默认值翻转为 true（K4+K5 双机交替阅读场景）；老配置中显式保存的值不受影响，仅缺失的键在启动时回填。
- **JSON 沙箱白名单（S-17）**：手动登录模板沙箱补 `math` 与最小 `os`（time/date/clock）。

**隐私（顺手修复，均 ≤5 行）**
- **日志脱敏（S-01）**：HTTP 失败日志与上报拒绝日志中的响应体先经 `redact_body()` 遮蔽凭证类字段（*skey/token/ticket/api_key 等）再落 crash.log；URL query 同步剥离（S-11 的 `display_error` 也剥离）。
- **路径白名单（S-07）**：`BookStore.resolved_dir` 统一实现并校验所有书路径必须位于下载根目录内（`Content.book_resolved_dir` 委托同一实现），防手改配置把元数据读写引到任意路径。
- **Cookie key 过滤（S-08）**：`Cookie.to_header` 对 key 同样过滤控制字符。
- **死代码清理（S-13）**：删除永不启用的子进程 runner；`client.lua` 头部过时的"read-report fork subprocess"注释修正（S-21）。

**其他**
- **lipc 常驻防休眠 feature-flag（原#4）**：`LIPC_STANDBY_GUARD_ENABLED` 常量开关，便于非 Kindle 移植与问题定位。
- **测试基建（原#5）**：新增 `spec/`（cookie / settings / read_report 三个 busted 套件）、`.luacheckrc`、GitHub Actions（busted + luacheck）。
- **风控提示**：`MAX_SINGLE_REPORT_SECONDS=30`、补报 3h 上限、退避 30→60s、降级超时等常量为**风控红线**（与 web 阅读器行为对齐），调整前须评估；双设备请避免同时在线阅读同一账号（并发心跳模式）。

### v5.0（2026-08-29）

**修复**
- **快捷菜单 > 章节目录跳转位置错误 / 未跳转**（v4.5 起）：v4.5 用 `GotoLink{file="text/chapter-NNN.xhtml"}` 定位整本缓存内的章节，但 KOReader 的 crengine `onGotoLink` 只认 xpointer（`link.file` 不被处理，xpointer 为空会跳到全书第一页或直接不跳）。v5.0 改为**文档目录（TOC）定位**：整本 EPUB 的 nav 目录由插件生成、与章节目录同序一一对应，跳转走 `GotoXPointer`（精确）→ `GotoPage`（虚拟页）→ 标题匹配 → 章节序号百分比近似，四级兜底。**旧整本缓存同样修复，无需重新下载**（目录文件一直在缓存内）。另外实测确认了三个叠加根因并已修复：① KOReader 在 ReaderReady **之后**才恢复上次阅读位置（`goto page 265`），立即跳转会被恢复动作覆盖 → 跳转延迟 1 秒执行；② `openFile` 会**重建 ReaderUI 与插件实例**（旧实例销毁，日志多次 initialized 印证），跳转意图改存跨实例共享状态（`_G`，带 book_id 校验防串书），新实例打开同一本书时消费并执行跳转；③ 延迟调度使用 `self.scheduler`，但插件实例此前未设置该字段（仅注入给了子模块），onReaderReady 报 `attempt to index field 'scheduler' (a nil value)` 并中断后续初始化 → 已在实例上补设 `scheduler = UIManager`。crash.log 输出全链路日志（`chapter jump scheduled / TOC loaded / entry resolved / no target resolved / cancelled`）便于定位。
- **删书重下后同步报「无法确定当前阅读位置：catalog_unavailable」**：下载完成时把章节目录写回书记录；目录缓存缺失时回退 SQLite；手动同步遇目录缺失自动联网拉取；打开书自动同步同样恢复（R1）。
- **Back 键逐层回退穿过旧界面后才退出**：插件打开的列表/菜单（章节列表、书架、书籍菜单、书籍详情、阅读统计、搜索结果、快捷菜单）点击条目后不会自动关闭（KOReader Menu 默认行为），会持续叠在界面栈上——按 Back 会逐层回退穿过这些旧界面（包括之前打开过的其他书的章节列表），直到栈空才出现退出确认。修复 = 插件对话框统一跟踪（`_G` 栈，跨 ReaderUI 重建存活），任何"打开书/文章"动作（`openFile`）先一键关闭全部插件对话框，Back 直接到达退出确认。经逐项核实：快捷菜单各按钮本身 `dismiss_then` 先关自身、无残留；普通菜单（KOReader 主菜单 > 微信读书）条目点击后主菜单自动关闭，均无此问题。
- **自动拉取网络未就绪静默失败**（移植上游 v1.3.0 PR #130）：自动拉取遇离线/任务未启动时 15 秒后自动重试（最多 3 次，换书或新同步会取消挂起重试），不再导致阅读时长上报卡死。

**新增**
- **前台屏障（交互优先）**：翻页后 2 秒内，后台下载/预取步骤自动让路（推迟 0.5 秒重排，单任务累计推迟上限 30 秒防饿死），下载不再与翻页抢 UI/网络。上报 tick 的既有错峰（P0-2）保持独立。注：该屏障主要作用于开启「章节预下载」的阅读场景；默认配置（预取关闭、整本下载先于阅读完成）下翻页期间无后台下载，屏障空转无副作用。
- **脚注显示位置设置**（设置 → 下载设置）：**章节末尾**（默认，单份显示、不重复）／**页面底部+章节末尾**（双份显示为 CREngine 设计行为，上游 issue #8623 确认；页内脚注会把注释附加到引用页且原位置保留）。切换后需重新下载已缓存的书生效。
- **章节目录加载增强**：目录缓存缺失时回退 SQLite；快捷菜单 > 章节目录在目录缺失时自动联网恢复（不再提示"此操作需要打开普通微信读书书籍"）。
- **菜单排序修正**：`reader_menu_order.lua`（模板在插件目录内）需复制到设备 `koreader/settings/reader_menu_order.lua` 才生效；菜单 id 必须是 `weread`（不是插件目录名 `weread_K4`），否则排序不生效且日志出现 `menu id not found` 警告。

### v4.5（2026-08-26）
- **书内注释（脚注）显示**：新增「脚注显示位置」设置（设置 → 下载设置）：
  - **章节末尾**（默认）：注释集中在章节末尾，单份显示（不依赖引擎脚注机制，保证不重复）；[N] 标记跳到章末对应注释
  - **页面底部+章节末尾**：CREngine 页内脚注渲染（长注释可延伸到次页），同时章节末尾保留原位置副本——双份显示是 CREngine 的设计行为（上游全设备已知问题，见 koreader issue #8623 "EPUB3 `<aside>` footnotes rendered twice"，维护者：原位置内容必须存在且可见；唯一规范解法是出版方把脚注标记为 EPUB non-linear 片段），与上游主线 v1.2.0 行为一致
  - 注释内返回链接均可跳回正文引用处；**切换该设置只影响新下载的书，已缓存的书需重新下载生效**
- **自动同步恢复（R1 + #130）**：删书重下后，打开书自动同步（"打开时拉取进度"配置）遇到目录缺失也会自动联网恢复，不再停留在未同步状态；自动拉取遇到网络未就绪（刚唤醒/刚开书 WiFi 尚未连上）时，每 15 秒自动重试（最多 3 次，换书或新同步会取消挂起重试），不再静默失败导致阅读时长上报卡死
- **同步修复**：重新下载（删书重下）后同步报「无法确定当前阅读位置：catalog_unavailable」——下载完成时目录已写回书记录，目录缓存缺失时自动回退 SQLite，手动同步遇到目录缺失会自动联网重新拉取后再同步；快捷菜单 > 章节目录同样支持自动恢复（不再提示"此操作需要打开普通微信读书书籍"）
- **章节目录跳转修复**：有整本缓存时从章节目录选择章节，会定位到所选章节（不再停在上次阅读位置）
- **弱网优化**（自 v4.0 第二轮）：
  - 上报 tick 写盘瘦身：上下文无变化不再全量写盘；写盘 30s 合并；单本原子写
  - 翻页与上报 tick 错峰：翻页时推迟上报，连续翻页有上限兜底
  - 失败重试链瘦身：一次失败至多 1-2 个请求；失败退避上限收敛到 60s
  - 弱网超时降级：连续失败后单请求超时 8s→4s，恢复后自动还原
  - 目录写入 SQLite 延迟出 tick 关键路径；tick 耗时打点日志

### v4.0（2026-08，当前版本）

从 v3.5 升级的核心内容：**下载机制加固（方案 1-5）+ 设备识别调整 + 阅读上报保守化 + SQLite 离线索引**。

**下载机制（2026-08-20）：**
- save_catalog_cache 对齐 H-3 fix：检查 `close()` 返回值，磁盘满时不再写坏目录缓存
- 章节下载失败自动重试 1 次（弱网/CDN 瞬时错误可自愈）
- 删除 fetch_chapters_epub 死代码

**整本下载内存优化（2026-08-24）：**
- 每章下载完成后**立即落盘**到 `<缓存目录>/.dl/`（章节 XHTML + 图片资产 + 资产元数据），不再全部驻留内存
- EPUB 聚合改为**流式构建**（`save_book_epub_streamed`）：逐章从磁盘读取、边读边写 zip，峰值内存从「全书」降到「单章」
- 单章/分章下载同样走落盘路径；脚注转换逐章读盘→转换→写回

**断点续传（2026-08-24）：**
- 每完成一章写入进度文件（整本 `progress.json` / 分章 `progress-separate.json`，按模式隔离）
- 下载中断（掉电/崩溃/手动取消）后重新发起下载时**自动检测并询问**：「已完成 X/Y 章，继续还是重新下载？」
- 继续：跳过已落盘章节从断点续传，资产元数据从磁盘恢复，无需重下图片；重新下载：清旧进度从头开始
- 章节列表变化或模式/后缀不匹配时跳过恢复询问，旧进度保留不误删
- 后续审查修复（B1/B2/S1/S5）：续传重建图片命名种子避免 href 冲突；`_step` 跳过已落盘章节避免重复下载；删除全内存版 `save_book_epub` 死代码；续传 failed 列表去重

**设备识别（2026-08-23）：**
- UA 从 Edge-macOS 改为 **Edge-Windows**（`Windows NT 10.0` + `Edg/135.0.0.0`）
- 旧书 `book.app_id` 一次性迁移清除（migrations.lua `clear_stale_app_ids`），消除 UA 与 appId 不一致的风控隐患

**阅读时长上报保守化（2026-08-24）：**
- 跨会话补报上限从 24h 收紧至 **3h**（超出丢弃并记日志），避免异常积压触发风控
- 补报排水节奏从 15s 对齐到 **30s**（与真实 web 心跳一致，省电且时序更自然；时长不丢失，仅入账更慢）
- 失败退避：连续失败 30s→300s 指数退避（弱网不再 15s×4 连发风暴）

**SQLite 离线索引（library_db，2026-08-25）：**
- 新增 `library_db.lua`（books/chapters 两表、WAL、user_vid 哈希分库）：书架、书籍详情、章节目录三重离线缓存
- **离线书架**：联网失败时自动展示上次缓存的书架，不再直接报错
- **目录双存储**：章节列表同时写 catalog.json + SQLite，上报/章节列表/书籍菜单读取时文件缓存优先、SQLite 次之、联网兜底
- 优雅降级：lua-ljsqlite3 不可用或未登录时自动回退现有文件缓存链路，零破坏

### v3.5（2026-08）

修复跨会话阅读时长上报的核心缺陷：离线阅读时间在关书→重开后的处理。

**升级注意事项（从 v3.0）：**
- v3.0 旧版本可能遗留大量非阅读时间累积的 backlog（睡眠/离开时间被当作阅读时间）
- **升级后建议执行一次清除**：运行 `tools/clear_stale_backlog.lua` 或手动删除 `weread.lua` 中 `read_report.watermarks` 表
- 清除脚本会自动备份原文件，安全可回滚
- 不清除直接补报的风险：**服务器风控、阅读时长错误、电量骤降**

### v3.0（2026-08）

集中修复数据安全 bug、资源泄漏与若干健壮性问题。

**数据安全（高优先级）：**
- 修复迁移失败时章节目录被**无条件清除**导致永久丢失的问题（migrations.lua：仅缓存成功落盘后才清除内存 chapters）
- 修复缓存目录跨文件系统迁移时源文件被**无条件删除**的问题（cache.lua move_dir：仅写入成功且大小校验通过后才删源）
- 修复书籍元数据写入未检查 `close()` 返回值，磁盘满时可能写出**损坏文件**的问题（book_store.lua / content.lua）

**资源与交互：**
- 修复重复进入缓存管理/书架/上报书目选择导致**孤儿 widget** 的问题（创建新菜单前先关闭旧引用，3 处）
- 修复"书籍图片"复选框切换后**视觉状态不刷新**的问题（补 `check_callback_updates_menu` + `updateItems`）

**健壮性：**
- MD5 轮常量改为硬编码，消除 `math.sin` 跨平台精度风险（与 SHA256 常量做法一致，64 值已验证零偏差）
- 搜索 API 返回 nil 时增加类型防护，避免 pcall 外崩溃
- scan.lua 在 `pcall(fs.dir)` 前校验 fs 类型，避免 nil 索引逃逸 pcall
- `isSafeCachePath` 路径穿越防护改为循环简化，堵住嵌套 `../../` 绕过

### v2.5（2026-08）

集中修复了可靠性、数据正确性和性能问题。

**关键修复：**
- 修复了下载中异常会导致设备**永远无法休眠**的严重 bug
- 修复了睡眠/关机时间被**误报为阅读时长**的问题（整夜睡眠被上报为读了 8 小时）
- 修复了进度同步可能**永久卡死**的竞态条件
- 修复了离线阅读时长**积压不补传**的问题（离线时攒的进度现在恢复联网后自动补发）
- 修复了切换书籍时旧书上传回调**污染新书进度**的问题
- 修复了离线阅读时长跨会话恢复时被**静默丢弃**的问题（watermark 钳制逻辑与离线保留设计矛盾）
- 修复了正常上报周期的 rt 值超过服务端 30s 上限导致阅读时长**系统性少报**的问题（v2.5 调高间隔引入的回归）
- 修复了手动同步/冲突上传**阻塞 UI 线程**的问题（进度上传改走子进程异步完成回调，UI 不再冻结，结果正确送达）
- 修复了配置文件损坏（掉电/中断写入）导致插件**整体加载失败**的问题（类型守卫 + pcall 兜底）
- 修复了 busy 重试期间换书/关书后旧书**多余上传**的问题（重试预检）

**性能优化（针对 K4 硬件）：**
- 章节解码速度大幅提升（base64 实现重写，每章从数秒降到毫秒级）
- 翻页时不再每次全量重读磁盘书架数据（内存缓存）
- 整书下载不再每章重复请求网页（15 分钟缓存复用）
- 阅读报告间隔调为 45 秒、排空间隔 15 秒，减少 K4 上的网络唤醒和 fork 开销
- HTTP 超时从 15s 收窄到 8s，弱网下 UI 冻结更短

**安全加固：**
- 手动登录模板执行改为沙箱隔离，不再有任意代码执行风险
- 缓存清理从 `rm -rf` shell 调用改为纯 Lua 递归删除，消除命令注入面
- Cookie 仅经 HTTPS 传输，拒绝明文 HTTP 携带
- Cookie 值过滤控制字符，防止头注入
- 失败响应日志截断，避免个人阅读数据泄露到日志文件
- 跨域重定向清理补全自定义认证头

**代码质量：**
- 所有 KOReader 事件入口（关闭文档/翻页/挂起/恢复/快捷菜单/账号状态）加异常隔离，插件错误不再中断阅读器
- 清理死代码和无效配置项
- MP 文章写入改为原子操作，磁盘满不再静默写出截断文件
- 下载成功后打开文件失败不再误报"下载失败"
- 空章节列表直接提示，不再产生异常进度条
- 下载取消时 standby guard 正确释放，不再有泄漏窗口
- 缓存路径安全检查规范化 `..` 段，纵深防御加固

**仍未完成（后续版本计划）：**
- 下载管线子进程化（当前仍以分片调度 + 8s 超时缓解 UI 冻结）
- 图片密集书籍内存优化（流式落盘）
- 凭证加密存储（当前仍明文，请勿将设备/设置文件交给他人）
- content.lua 模块拆分、单元测试补齐

### v2.0

K4 分支的初始稳定版本，基于官方 v0.6.0 做了以下适配：

- **按键交互**：全部菜单和操作支持五向键 + 键盘，无触摸依赖
- **快捷菜单**：ScreenKB+Down 调出微信读书快捷面板（阅读时覆盖书籍地图）
- **手动登录**：USB 模板导入备用登录方式（扫码不可用时使用）
- **离线阅读时长上报**：watermark 持久化 + 挂起检测 + 联网后自动补报
- **阅读统计按键操作**：Press 切换 Tab，方向键/翻页键滚动
- **稳定性基础**：事件入口异常隔离框架、配置数据容错、flush 合并写盘
- **去 shell 化**：目录创建从 `mkdir -p` 改为 lfs 递归创建
- **菜单布局**：高频项前置，登录/关于置末尾（按键导航效率）
- **功能裁剪**：删除划线/想法、书评等触摸交互功能

### v1.0（上游主线，本分支不跟随）

上游 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin) 的 v1.0.0 版本，面向触摸设备：

- SQLite 书架库、自动更新、library_view 新视图
- ZenUI/SimpleUI 集成、fonts/icons 资源
- 划线和想法、书评功能
- 触摸手势交互

本分支不跟随 v1.0，因为上述功能依赖触摸交互或资源，不适合 K4 非触摸设备。

## 与主线 v1.0.0 的差别

| 项目 | 主线 v1.0.0 | 本分支（K4） |
|------|-------------|--------------|
| 版本号 | 1.0.0 | 0.6.0-k4-v5.6 |
| 手动登录（备用） | 无 | **有**（USB 模板导入，扫码不可用时备用） |
| 离线阅读时长上报 + 挂起检测 | 无 | **有**（离线时长持久化 + 挂起检测只丢弃睡眠时长） |
| 上报状态细粒度显示 | 无 | **有** |
| 阅读时间上报默认值 | 手动启用 | **默认启用 + 自动关联**（仅新配置） |
| 工具菜单置顶 + 隐藏触摸插件 | 无 | **有**（reader_menu_order.lua） |
| 菜单触摸门控 | 无 | **有** |
| 划线和想法 | 有 | **删除**（K4 上本就无法交互） |
| 书评 | 有 | **删除** |
| 阅读统计按键操作 | 无 | **有**（Press 切 Tab，方向键/翻页键滚动） |
| SQLite 书架库 library_db | 有 | **已移植**（v4.0：书架/详情/目录离线缓存） |
| library_view / 详情 / 目录新视图 | 有 | 未移植（纯触摸交互，不适合 K4） |
| ZenUI / SimpleUI 集成 | 有 | 未移植（触摸 launcher） |
| fonts / icons 资源 | 有 | 不带 |

## 安全提示

登录凭证（cookies、API key）存储于 KOReader 设置文件中，位于设备内部存储/SD 卡上，USB 连接可读取。请勿将设备或设置文件随意交给他人；分享日志或备份前请检查是否含凭证。后续版本计划加密存储。

## 许可证

本分支代码沿用上游 [AGPL-3.0](LICENSE) 许可证。修改、整合或再分发时须遵守 AGPL-3.0，保留版权和许可证声明。

## 开发与测试

- 单元测试：`luarocks install busted && busted spec`；静态检查：`luarocks install luacheck && luacheck weread spec tools main.lua _meta.lua`。
- CI（`.github/workflows/ci.yml`）使用**标准 Lua 5.1** 作为兼容性哨兵：新增 `spec/*.lua` 必须遵守 Lua 5.1 语法子集（禁止 `\x`/`\z` 转义、`goto`、整除 `//` 等新语法），本地 LuaJIT/5.3+ 不报错的问题会在 CI 拦下。
- 依赖以 `luarocks install --tree .luarocks` 安装或依赖 CI 的排除配置；`.luarocks/`、`.luacheck_cache` 已在 `.gitignore` 中。
- **设备部署不需要 `spec/` 与 `.luacheckrc`**：KOReader 只加载 `main.lua` + `_meta.lua` + `weread/`。发布包（`weread_K4.koplugin_v5.6.zip`）已按运行时清单打包。
