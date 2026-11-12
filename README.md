# WeRead KOReader Plugin · K4 分支（v0.6.0-k4-v9.12）

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

1. 解压发布包（`weread_K4.koplugin-vX.zip`）——解压即得 `weread_K4.koplugin/` 文件夹；将其复制到 KOReader 的 `plugins` 目录：
   ```
   koreader/plugins/weread_K4.koplugin/
   ```
   > 注意：`weread_K4.koplugin/`（含 `_meta.lua`）必须直接位于 `plugins/` 下。若解压后 `main.lua` 散落在 `plugins/` 根部，KOReader 将找不到插件（v8.1 首个发布包即有此缺陷，已于重发中修正为包内自带顶层目录）。
2. 重启 KOReader，在菜单中找到 `工具 → 微信读书`。

> 已在 **KOReader 2026.07.1**（"Sailing Walrus" 修正版）+ Kindle 4 / Kindle 5（非触摸）实测验证。

---

## 登录

- **扫码登录**为推荐方式，扫码前需在微信读书 App 中开通微信读书 Skill 并获取 API Key。
- **不扫码也能退出**（2026-11-08 修复，未发版）：二维码弹出时屏幕会提示 `Back: cancel login  |  Menu: exit KOReader`。按 **Back** 取消本次登录（`cancel()` 递增 generation，停止 0.5s 轮询并清除临时 cookie）；按 **Menu** 先取消再广播原生 `Exit` 事件，直接退出 KOReader 回 Kindle 桌面/KUAL。**首次登录**与 **Cookie 续期**两条路径同样生效。此前 `QRMessage` 的 `AnyKeyPressed` 只关窗且吞掉 Menu，无文档时 weread-only 收敛菜单也不可达，用户不扫码只能等 300s 超时。
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
│   ├── 账号管理（账号状态 / 手动登录 / 立即续期 Cookie / 清除账号数据）
│   └── Wifi状态（勾选后显示 Wi-Fi 射频/连接状态，非互联网可达性）
├── （阅读微信读书缓存书籍时插入）
│   ├── 立即同步进度
│   └── 书籍详情
├── 已登录 · 账号名 / 微信扫码登录   （菜单末尾）
└── 关于（v0.6.0-k4-v9.12）          （菜单末尾）
```

## 阅读时长上报

> **默认启用**（v2.x 起）：全新安装后默认开启并自动关联当前书籍。如不需要可在菜单关闭。

离线时长已持久化：关书、重启、挂起唤醒后不丢失，联网后自动补报。上报状态可在 `阅读时间上报 → 上报状态` 查看。

本地另有按书按天的**阅读时长账本**（v6.0 起，官方客户端同款"先记账后上报"）：阅读统计页的「本地阅读账本」卡片展示设备已记账时长与同周期服务端确认时长，两者差距持续增大即"上报未打通"预警。

---

## 传输后端（Rust TLS，可选）

插件传输层默认 LuaSec（`weread/lib/transport.lua` 的 `M.backend = "luasec"`），支持 Rust 后端 libk4tls（rustls/ring，随包 `weread/lib/libk4tls.so`）。只有显式 `auto` / `k4tls` 才探测该库；`auto` 在库不可加载时回退 LuaSec，其余值强制 LuaSec。设备侧可在 KOReader 启动脚本 `export WEREAD_TLS_BACKEND=k4tls`，也可在「设置 → Rust TLS 后端 (k4tls)」勾选（v9.13 候选，未发版）：**菜单显式选择优先于部署侧 env**（`transport.backend_explicit`），选择持久化到 `settings.tls_backend`，`.so` 不可加载时显式提示回退而不静默。未设置 env 且未勾选时不受影响。

2026-11-10 R4 bench（K5 真机，各 10 次全连接对比）：k4tls MEAN **0.837s** vs LuaSec **0.866s**（快 3.4%，MAX 更低，10/10 成功）——评估报告 §九 R4「性能持平即换」满足。复测工具：`luajit dev/bench_tls.lua [N]`（详见报告 `~/reports/2026-11-10-K4weread-R4-bench报告-libk4tls-vs-LuaSec-K5真机.md`）。

## [版本变更日志](ChangeLog.md)

各版本的功能与修复记录见 [ChangeLog.md](ChangeLog.md)。

## 已知问题与限制

- **IPv6 解析间歇失败**：K4 无 IPv6 协议栈，DNS 偶发返回 IPv6 地址时请求会短暂失败；DNS 过滤与单次重试已让其自动恢复，离线时长不会丢失。
- **发布包**：设备包一律由 `tools/build_release.sh` 在干净、已打 tag 的提交上生成，自带顶层 `weread_K4.koplugin/` 目录与 SHA-256 校验和，请勿手工打包。
- **Wi-Fi 图标语义**：图标表示无线链路已连接（射频开启、已关联、已获取地址），不代表微信读书服务可达；强制门户场景下图标可能亮起但请求仍失败。

## 与主线 v1.0.0 的差别

| 项目 | 主线 v1.0.0 | 本分支（K4） |
|------|-------------|--------------|
| 版本号 | 1.0.0 | 0.6.0-k4-v9.12 |
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

登录凭证存储于**独立的 0600 权限凭据文件**（v8.0 起，`weread-credentials-v1` 行式格式；旧版 KOReader 设置文件中的 cookies 在升级后自动搬迁，搬迁失败时保留原路径以不丢登录态）。文件位于设备内部存储/SD 卡上，USB 连接可读取。请勿将设备或设置文件随意交给他人；分享日志或备份前请检查是否含凭证文件。

## 许可证

本分支代码沿用上游 [AGPL-3.0](LICENSE) 许可证。修改、整合或再分发时须遵守 AGPL-3.0，保留版权和许可证声明。

## 开发与测试

- 单元测试：`luarocks install busted && busted spec`；静态检查：`luarocks install luacheck && luacheck weread spec tools main.lua _meta.lua`。
- 模块映射门禁：`python3 tools/check_module_map.py` —— `module-map.json` 是「模块 → spec 覆盖」映射的唯一事实源（每模块须有 spec 或逐条写明豁免理由）；新增/删除/改名模块须在同一变更内登记，孤儿 spec 同样 fail（N-2，CI 同步执行）。测试计数以 CI 输出为准。
- mock 故障注入（B-3，v8.1 起）：`spec/mock_service_spec.lua` 需真实 `luasocket` + `luajson`（`luarocks install luasocket luajson`），运行时自动拉起 `python3 dev/mock_gateway.py`（端口可用 `WEREAD_MOCK_PORT` 覆写，默认 18473）；慢/断/空服务端行为由此获得 CI 级回归。
- CI（`.github/workflows/ci.yml`）使用**标准 Lua 5.1** 作为兼容性哨兵：新增 `spec/*.lua` 必须遵守 Lua 5.1 语法子集（禁止 `\x`/`\z` 转义、`goto`、整除 `//` 等新语法），本地 LuaJIT/5.3+ 不报错的问题会在 CI 拦下。
- **全局副作用声明**：插件加载时会把 `socket.dns.toip` patch 为 IPv4 优先解析（`weread/lib/ipv4_dns.lua`，K4 无 IPv6 栈下的 EAFNOSUPPORT 防御）——该 patch 对**整个 KOReader 进程**生效，其他插件的 HTTP 请求同样走 A 记录优先；任何异常自动回退原实现。
- 依赖以 `luarocks install --tree .luarocks` 安装或依赖 CI 的排除配置；`.luarocks/`、`.luacheck_cache` 已在 `.gitignore` 中。
- **设备部署不需要 `spec/` 与 `.luacheckrc`**：KOReader 只加载 `main.lua` + `_meta.lua` + `weread/`。发布包（`weread_K4.koplugin-v6.5.zip`）已按运行时清单打包。
