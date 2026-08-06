local I18n = {}

local zh = {
    ["WeRead"] = "微信读书",
    ["WeRead · Sync reading progress"] = "微信读书·同步阅读进度",
    ["Bookshelf"] = "书架",
    ["Search"] = "搜索",
    ["Settings"] = "设置",
    ["Sync progress now"] = "立即同步进度",
    ["Book details"] = "书籍详情",
    ["Previous"] = "上一页",
    ["Next"] = "下一页",
    ["%1%"] = "%1%",
    ["Renew cookie now"] = "立即续期 Cookie",
    ["Progress management"] = "进度管理",
    ["Pull progress on open"] = "打开时拉取进度",
    ["Upload progress on close"] = "关闭时上传进度",
    ["Reading progress sync"] = "阅读进度同步",
    ["Use WeRead progress"] = "使用微信读书进度",
    ["Keep KOReader progress"] = "保留 KOReader 进度",
    ["WeRead's two progress sources disagree for \"%1\".\n\nKOReader: %2%\nSelected cloud position: %3%\n\nChoose which position to keep."] = "《%1》的两个微信读书进度来源不一致。\n\nKOReader：%2%\n选中的云端位置：%3%\n\n请选择要保留的位置。",
    ["Reading progress differs for \"%1\".\n\nKOReader: %2%\nWeRead: %3%\n\nChoose which position to keep."] = "《%1》的阅读进度不一致。\n\nKOReader：%2%\n微信读书：%3%\n\n请选择要保留的位置。",
    ["Progress uploaded to WeRead: %1%"] = "进度已上传到微信读书：%1%",
    ["Progress upload failed:\n%1"] = "进度上传失败：\n%1",
    ["KOReader and WeRead are already at the same position."] = "KOReader 与微信读书已经处于同一位置。",
    ["Jumped to WeRead progress: %1%"] = "已跳转到微信读书进度：%1%",
    ["Kept the current KOReader position."] = "已保留当前 KOReader 位置。",
    ["Could not fetch WeRead progress:\n%1"] = "无法获取微信读书进度：\n%1",
    ["Could not jump to WeRead progress:\n%1"] = "无法跳转到微信读书进度：\n%1",
    ["Could not determine the current reading position:\n%1"] = "无法确定当前阅读位置：\n%1",
    ["Cloud progress is in \"%1\", but this chapter has not been downloaded.\n\nDownload and open it now?"] = "云端进度位于《%1》，但该章节尚未下载。\n\n是否立即下载并打开？",
    ["Download target chapter"] = "下载目标章节",
    ["Download settings"] = "下载设置",
    ["Book images"] = "书籍图片",
    ["Public account article images"] = "公众号文章图片",
    ["Chapter prefetch"] = "章节预下载",
    ["Automatically prefetch next chapter"] = "自动预下载下一章",
    ["Due to network conditions, automatic prefetching may cause a few seconds of delay when you start reading a new chapter. Enable it?"] = "由于网络原因，自动预下载可能会导致开始阅读新章节时卡顿几秒钟。是否开启？",
    ["Show prefetch notifications"] = "显示预下载提示",
    ["Downloading public account article images may significantly increase download time. Continue?"] = "下载公众号文章图片可能会显著延长下载时间，是否继续？",
    ["Confirm"] = "确认",
    ["Account management"] = "账号管理",
    ["Account status"] = "账号状态",
    ["Clear account data"] = "清除账号数据",
    ["QR login"] = "扫码登录",
    ["Getting login QR code..."] = "正在获取登录二维码……",
    ["QR login cancelled."] = "扫码登录已取消。",
    ["QR login failed:\n%1"] = "扫码登录失败：\n%1",
    ["The QR code has expired. Please try again."] = "二维码已失效，请重新扫码。",
    ["The verification code has expired. Please try again."] = "验证码已失效，请重新扫码。",
    ["Incorrect verification code."] = "验证码不正确。",
    ["Unknown login response"] = "未知登录响应",
    ["Enter the four-digit verification code shown on your phone."] = "请输入手机上显示的四位验证码。",
    ["Verification code required"] = "需要验证码",
    ["Verify"] = "验证",
    ["The verification code must contain four digits."] = "验证码必须为四位数字。",
    ["Verifying login..."] = "正在验证登录……",
    ["Verification timed out. Please try again."] = "验证请求超时，请重试。",
    ["Completing WeRead login..."] = "正在完成微信读书登录……",
    ["Unknown account"] = "未知账号",
    ["Not logged in"] = "未登录",
    ["Logged in · %1"] = "已经登录 · %1",
    ["WeRead login successful.\n\nAccount: %1\nCookie: %2\nOfficial API key: %3"] = "微信读书登录成功。\n\n账号：%1\nCookie：%2\n官方 API Key：%3",
    ["No official API key was returned. This account has not enabled WeRead Skill.\n\nOpen WeRead app → Me → Settings → WeRead Skill → Get API Key, then scan again."] = "未返回官方 API Key，说明当前账号尚未开通微信读书 Skill。\n\n请打开微信读书 App → 我 → 设置 → 微信读书 Skill → 获取 API Key，生成后重新扫码登录。此次登录未保存任何凭证。",
    ["%1 failed:\n%2"] = "%1 失败：\n%2",
    ["No network connection. Please connect Wi-Fi and try again."] = "当前没有网络连接，请连接 Wi-Fi 后重试。",
    ["No items."] = "没有条目。",
    ["Cancel"] = "取消",
    ["Please scan the QR code to log in first."] = "请先微信扫码登录。",
    ["Renew cookie"] = "续期 Cookie",
    ["WeRead cookie renewed."] = "微信读书 Cookie 已续期。",
    ["configured"] = "已配置",
    ["missing"] = "缺失",
    ["Account: %1\nLogin method: %2\nCookie: %3\nOfficial API key: %4\nCache directory:\n%5"] = "账号：%1\n登录方式：%2\nCookie：%3\n官方 API Key：%4\n缓存目录：\n%5",
    ["Clear WeRead cookie and API key? Cached books will remain."] = "清除微信读书 Cookie 和 API Key？已缓存书籍会保留。",
    ["Clear"] = "清除",
    ["WeRead account data cleared."] = "微信读书账号数据已清除。",
    ["Load bookshelf failed:\n%1"] = "加载书架失败：\n%1",
    ["Load bookshelf failed:\n%1\n\nIf other account features still work, use Search to find and download books."] = "加载书架失败：\n%1\n\n如果其他账号功能仍然正常，可以使用“搜索”查找并下载书籍。",
    ["Untitled"] = "未命名",
    ["Done"] = "已读完",
    ["WeRead Bookshelf"] = "微信读书书架",
    ["Your WeRead shelf is empty."] = "微信读书书架为空。",
    ["Loading bookshelf..."] = "正在加载书架...",
    ["%1 chapters"] = "%1 章",
    ["Not loaded"] = "未加载",
    ["Loading chapter list..."] = "正在加载章节目录...",
    ["Load chapters failed:\n%1"] = "加载章节失败：\n%1",
    ["Chapter %1"] = "第 %1 章",
    ["Chapter"] = "章节",
    ["Cached"] = "已缓存",
    ["%1 words"] = "%1 字",
    ["Chapter list"] = "章节目录",
    ["Refresh chapter list"] = "刷新章节目录",
    ["Chapter list refreshed: %1 chapters"] = "章节目录已刷新：%1 章",
    ["No chapters."] = "没有章节。",
    ["Select chapters to download"] = "选择章节下载",
    ["Download selected chapters"] = "下载已选章节",
    ["[Action] Refresh chapter list"] = "【操作】↻ 刷新章节目录",
    ["[Action] Select chapters to download"] = "【操作】✓ 选择章节下载",
    ["[Download] Selected chapters (%1)"] = "【下载】已选 %1 章",
    ["Selected"] = "已选择",
    ["Download chapter and read"] = "下载本章并阅读",
    ["Open cached book"] = "打开已缓存书籍",
    ["Download full book"] = "下载全书",
    ["Download all %1 chapters as one EPUB?"] = "将全部 %1 章下载为一个 EPUB？",
    ["Download %1 selected chapter(s)?"] = "下载选中的 %1 个章节？",
    ["A book with many chapters may take a long time. Prefer single- or multi-chapter downloads when possible."] = "书籍章节较多时，全书下载可能耗时很长。建议优先使用单章或多章下载。",
    ["Download text only"] = "仅下载正文",
    ["Download"] = "下载",
    ["EPUB"] = "EPUB",
    ["Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"] = "已下载 %1 章。\n\n书籍已保存：\n%2\n\n现在阅读？",
    ["Downloaded %1 chapters."] = "已下载 %1 章。",
    ["Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"] = "已下载 %1 章，%2 章失败。\n\n书籍已保存：\n%3\n\n现在阅读？",
    ["Close"] = "关闭",
    ["Not cached"] = "未缓存",
    ["No actions."] = "没有可用操作。",
    ["No cached file."] = "没有已缓存文件。",
    ["Download failed:\n%1"] = "下载失败：\n%1",
    ["Another download is already in progress."] = "已有下载任务正在进行。",
    ["Prefetching next chapter: %1"] = "正在预下载下一章：%1",
    ["Next chapter prefetched: %1"] = "下一章预下载完成：%1",
    ["Next chapter prefetch failed: %1"] = "下一章预下载失败：%1",
    ["Network is not connected"] = "网络未连接",
    ["No chapters were downloaded."] = "没有成功下载任何章节。",
    ["No readable chapter found"] = "没有可阅读的章节。",
    ["Read now"] = "立即阅读",
    ["Pull progress"] = "拉取进度",
    ["Remote progress: %1%"] = "远端进度：%1%",
    ["Search WeRead"] = "搜索微信读书",
    ["Search failed:\n%1"] = "搜索失败：\n%1",
    ["Search: %1"] = "搜索：%1",
    ["No search results."] = "没有搜索结果。",
    ["Paste WeRead reader URL"] = "粘贴微信读书阅读链接",
    ["Parse"] = "解析",
    ["Parse reader URL"] = "解析阅读链接",
    ["Unknown title"] = "未知书名",
    ["Reader HTML loaded, but bookId was not found."] = "阅读页 HTML 已加载，但没有找到 bookId。",
    ["Reader URL parsed.\nBook: %1\nbookId: %2"] = "阅读链接解析完成。\n书名：%1\nbookId：%2",
    ["The current document is not a WeRead cached book."] = "当前文档不是微信读书缓存书籍。",
    ["This action requires an open WeRead book."] = "此操作需要当前打开普通微信读书书籍。",
    ["Parse a WeRead reader URL before testing progress sync."] = "测试进度同步前，请先解析一个微信读书阅读链接。",
    ["Upload"] = "上传",
    ["Sync progress"] = "同步进度",
    ["WeRead progress synced."] = "微信读书进度已同步。",
    ["Progress request sent, but response did not include succ=1."] = "进度请求已发送，但响应里没有 succ=1。",
    ["Books"] = "书籍",
    ["%1 books"] = "%1 本书",
    ["Public Accounts"] = "公众号",
    ["%1 accounts"] = "%1 个公众号",
    ["Public Account"] = "公众号",
    ["Loading articles..."] = "正在加载文章列表...",
    ["Load articles failed:\n%1"] = "加载文章列表失败：\n%1",
    ["No articles."] = "没有文章。",
    ["Article"] = "文章",
    ["Download article and read"] = "下载文章并阅读",
    ["Downloading article: %1"] = "正在下载文章：%1",
    ["Refresh article list"] = "刷新文章列表",
    ["Reading time report"] = "阅读时间上报",
    ["Enable reading time report"] = "启用阅读时间上报",
    ["Select target book"] = "选择目标书籍",
    ["Not configured"] = "未配置",
    ["Report status"] = "上报状态",
    ["Report book: %1\nStatus: %2"] = "上报书籍：%1\n状态：%2",
    ["Running"] = "运行中",
    ["Stopped"] = "已停止",
    ["Offline"] = "离线",
    ["Suspended"] = "已暂停",
    ["Waiting for progress"] = "等待进度验证",
    ["Waiting"] = "等待中",
    ["Error"] = "错误",
    ["Reported: %1 times, last: %2"] = "已上报：%1 次，最近：%2",
    ["Pending (offline): %1 min"] = "待补报（离线）：约 %1 分钟",
    ["Draining offline backlog: %1 min"] = "补报中（离线待补）：约 %1 分钟",
    ["Last error: %1"] = "最近错误：%1",
    ["Only report when reading"] = "仅在阅读时上报",
    ["Select a book to report reading time"] = "选择一本书用于上报阅读时间",
    ["Target book set: %1"] = "已设置目标书籍：%1",
    ["Loading bookshelf..."] = "正在加载书架...",
    ["Downloading: %1"] = "正在下载：%1",
    ["Downloading chapter %1/%2: %3"] = "正在下载章节 %1/%2：%3",
    ["Downloading images · chapter %1/%2"] = "正在下载图片 · 章节 %1/%2",
    ["Processing chapter %1/%2"] = "正在处理章节 %1/%2",
    ["Processing footnotes · chapter %1/%2"] = "正在处理脚注 · 章节 %1/%2",
    ["Building EPUB..."] = "正在生成 EPUB……",
    ["%1 footnote reference(s) could not be resolved and were kept as original links."] = "%1 个脚注引用无法解析，已保留原始链接。",
    ["%1 chapter(s) kept their original footnote markup after validation fallback."] = "%1 个章节的脚注转换未通过校验，已保留原始内容。",
    ["Downloading images: %1"] = "正在下载图片：%1",
    ["Please select a target book"] = "请先选择目标书籍",
    ["Download cancelled"] = "下载已取消",
    ["Cancel download"] = "取消下载",
    ["WeRead could not refresh the public-account credential. Please scan the QR code again."] = "无法自动刷新公众号凭证，请重新扫码登录。",
    ["Cache management"] = "缓存管理",
    ["Cache cleanup"] = "缓存清理",
    ["Cache directory"] = "缓存目录",
    ["Cache directory: %1"] = "缓存目录：%1",
    ["Download directory set to:\n%1"] = "下载目录已设置为：\n%1",
    ["Download directory set to:\n%1\nExisting downloads stay in the old location."] = "下载目录已设置为：\n%1\n已下载的内容仍保留在原位置。",
    ["Download directory changed. Move %1 cached book(s) to the new location?"] = "下载目录已更改。是否将 %1 本已缓存的书籍移动到新位置？",
    ["Move"] = "移动",
    ["Keep"] = "保留",
    ["Moving cached books..."] = "正在移动已缓存的书籍……",
    ["Moved %1 book(s) to:\n%2"] = "已将 %1 本书籍移动到：\n%2",
    ["Moved %1 book(s). %2 skipped (target already exists), %3 failed. These stay in the old location."] = "已移动 %1 本书籍。%2 本已跳过（目标已存在），%3 本失败。这些仍保留在原位置。",
    ["Scan and match local books"] = "扫描并关联本地书籍",
    ["Scanning local cache..."] = "正在扫描本地缓存……",
    ["Scan complete. %1 added, %2 updated."] = "扫描完成。新增 %1 项，更新 %2 项。",
    ["Scanning requires the official API key to match folders against your WeRead shelf."] = "扫描需要配置官方 API key，以便与微信读书书架匹配。",
    ["Found %1 new and %2 outdated item(s) in the new directory. Import them?"] = "在新目录中发现 %1 项新增内容、%2 项待更新内容。是否导入书库？",
    ["Import"] = "导入",
    ["Skip"] = "跳过",
    ["Imported %1 new and %2 updated item(s)."] = "已导入 %1 项新增内容，更新 %2 项。",
    ["Cannot use this directory: %1"] = "无法使用该目录：%1",
    ["Invalid path."] = "路径无效。",
    ["Directory does not exist and could not be created."] = "目录不存在且无法创建。",
    ["Directory is not writable."] = "目录不可写。",
    ["Clear cache for \"%1\"?"] = "清除「%1」的缓存？",
    ["Clear all cache"] = "清除所有缓存",
    ["Clear all cache? Downloaded books and articles will be deleted."] = "清除所有缓存？已下载的书籍和文章将被删除。",
    ["[Cleanup] Clear all cache (%1)"] = "【清理】清除所有缓存（%1）",
    ["Clear all public account cache"] = "清除全部公众号缓存",
    ["[Cleanup] Clear all public account cache (%1)"] = "【清理】清除全部公众号缓存（%1）",
    ["Clear all public account cache? Downloaded articles and cached article lists will be deleted."] = "清除全部公众号缓存？已下载的文章和缓存的文章列表将被删除。",
    ["Public account cache cleared"] = "公众号缓存已清除",
    ["Cache cleared"] = "缓存已清除",
    ["No cached items"] = "没有缓存内容",
    ["%1 files, %2"] = "%1 个文件，%2",
    ["Author"] = "作者",
    ["Translator"] = "译者",
    ["Publisher"] = "出版社",
    ["Publication date"] = "出版时间",
    ["Category"] = "分类",
    ["Word count"] = "字数",
    ["w words"] = "万字",
    ["Rating"] = "评分",
    ["%1 (%2 ratings)"] = "%1（%2 人评价）",
    ["Introduction"] = "简介",
    -- K4 fork: book-reviews feature removed; its translation keys are dropped.
    ["Loading book info..."] = "正在加载书籍信息...",
    ["Book info"] = "书籍信息",
    ["Clear book cache"] = "清除本书缓存",
    ["Sort"] = "排序",
    ["Sort by"] = "排序方式",
    ["Filter"] = "筛选",
    ["Filter by"] = "筛选条件",
    ["All"] = "全部",
    ["Only show finished books"] = "仅显示已读完书籍",
    ["Only show unfinished books"] = "仅显示未读完书籍",
    ["Only show downloaded books"] = "仅显示已下载书籍",
    ["Only show not-downloaded books"] = "仅显示未下载书籍",
    ["Finished"] = "已读完",
    ["Unfinished"] = "未读完",
    ["Downloaded"] = "已下载",
    ["Not downloaded"] = "未下载",
    ["%1 \u{25BE}"] = "%1 \u{25BE}",
    ["Last read time (newest first)"] = "最后阅读时间（最新优先）",
    ["Last read time (oldest first)"] = "最后阅读时间（最早优先）",
    ["Title A-Z"] = "书名 A-Z",
    ["Title Z-A"] = "书名 Z-A",
    ["Default order"] = "默认顺序",
    ["Reading progress"] = "阅读进度",
    ["Auto-associate"] = "自动关联",
    ["Auto: %1"] = "自动：%1",
    ["Auto-associate with WeRead book"] = "自动关联微信读书书籍",
    ["Manually set report book"] = "手动设置上报书籍",
    ["Current book is not from WeRead, reading time not reported"] = "当前书籍非微信读书书籍，不上报阅读时间",
    ["WeRead · Quick menu"] = "微信读书·快捷菜单",
    ["WeRead · Bookshelf"] = "微信读书·书架",
    ["WeRead cached"] = "已下载书目",
    ["No cached WeRead content"] = "暂无已下载书目",
    ["Total cache: %1"] = "缓存合计：%1",
    ["Close book"] = "关闭书籍",
    ["You have reached the last chapter."] = "已经是最后一章了。",
    ["WIP"] = "开发中",
    ["About (v%1)"] = "关于（v%1）",
    ["WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nThis branch (K4 non-touch adaptation) is derived from official v0.6.0 and developed independently:\nhttps://github.com/dororo42/weread_K4.koplugin\n\nUpstream project (AGPL-3.0):\nhttps://github.com/finlater/weread.koplugin"] = "WeRead 插件 v%1\n\n免责声明：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者概不负责。请遵守微信读书的用户协议和相关法律法规。\n\n本分支（K4 非触摸适配）基于官方 v0.6.0 独立发展：\nhttps://github.com/dororo42/weread_K4.koplugin\n\n上游项目（AGPL-3.0）：\nhttps://github.com/finlater/weread.koplugin",
    ["QR code login"] = "微信扫码登录",
    ["Unknown"] = "未知",
    -- Reading statistics
    ["Reading statistics"] = "阅读统计",
    ["This week"] = "本周",
    ["This month"] = "本月",
    ["This year"] = "本年",
    ["Overall"] = "全部",
    ["Week"] = "周",
    ["Month"] = "月",
    ["Year"] = "年",
    ["Total"] = "总",
    ["Loading reading statistics..."] = "正在加载阅读统计……",
    ["No reading records for this period."] = "本周期暂无阅读数据。",
    ["Total reading time"] = "累计阅读",
    ["%1 days read"] = "阅读 %1 天",
    ["Daily average %1"] = "日均 %1",
    ["Text reading %1%"] = "文字阅读 %1%",
    ["↑ %1% vs previous"] = "较上期 ↑ %1%",
    ["↓ %1% vs previous"] = "较上期 ↓ %1%",
    ["Reading time trend"] = "阅读时长趋势",
    ["Most-read books"] = "读书排行",
    ["Reading preferences"] = "阅读偏好",
    ["Categories"] = "偏好分类",
    ["Preferred time"] = "偏好时段",
    ["Favorite authors"] = "偏好作者",
    ["Favorite publishers"] = "偏好出版社",
    ["‹ Previous"] = "‹ 上一周期",
    ["Next ›"] = "下一周期 ›",
    ["< 1 min"] = "不足 1 分钟",
    ["%1 h %2 min"] = "%1 小时 %2 分钟",
    ["%1 h"] = "%1 小时",
    ["%1 min"] = "%1 分钟",
    -- Manual login
    ["Manual login"] = "手动配置登录",
    ["Configuration guide"] = "配置说明",
    ["Generate template"] = "生成配置模板",
    ["Import now"] = "立即导入",
    ["Template generated at:\n%1\n\nConnect via USB, edit the file,\nthen restart KOReader or use \"Import now\"."] = "配置模板已生成：\n%1\n\n通过 USB 连接 Kindle，编辑该文件，\n然后重启 KOReader 或使用\"立即导入\"。",
    ["Failed to generate template: %1"] = "生成模板失败：%1",
    ["Manual login imported successfully."] = "手动登录凭证已成功导入。",
    ["No manual login file found.\nGenerate a template first."] = "未找到手动登录文件。\n请先生成配置模板。",
    ["Template not filled in.\nEdit the file and replace YOUR_xxx placeholders."] = "配置模板尚未填写。\n请编辑文件并替换 YOUR_xxx 占位符。",
    ["Manual login file has invalid format.\nPlease check the Lua syntax."] = "手动登录文件格式无效。\n请检查 Lua 语法。",
    ["Import failed: %1"] = "导入失败：%1",
    [ [[Manual login guide:

1. Select "Generate template" to create
   weread_manual_login.lua in settings dir

2. Connect Kindle via USB and edit:
   koreader/settings/weread_manual_login.lua

3. Fill in credentials (replace YOUR_xxx):
   api_key  — WeRead API Key
   wr_skey  — WeRead Cookie
   wr_vid   — WeRead user ID
   wr_rt    — Refresh token (optional)
   name     — Your nickname (optional)

4. How to get credentials:
   a. Open https://weread.qq.com in browser
      Login with WeChat QR
   b. Press F12
      Application → Cookies → weread.qq.com
   c. Copy wr_skey, wr_vid, wr_rt values
   d. API Key:
      WeRead App → Me → Settings
      → WeRead Skill → Get API Key

5. Save file and restart KOReader
   Plugin auto-imports and deletes template

6. Or select "Import now" (no restart needed)]] ] = [[手动配置登录说明：

1. 选择"生成配置模板"
   将在设置目录创建 weread_manual_login.lua

2. USB 连接 Kindle，编辑文件：
   koreader/settings/weread_manual_login.lua

3. 填写凭证（替换 YOUR_xxx）：
   api_key  — 微信读书 API Key
   wr_skey  — 微信读书 Cookie
   wr_vid   — 微信读书用户 ID
   wr_rt    — 刷新令牌（可选）
   name     — 昵称（可选）

4. 获取凭证：
   a. 浏览器打开 https://weread.qq.com
      微信扫码登录
   b. 按 F12
      Application → Cookies → weread.qq.com
   c. 复制 wr_skey、wr_vid、wr_rt
   d. API Key：
      微信读书 App → 我 → 设置
      → 微信读书 Skill → 获取 API Key

5. 保存后重启 KOReader
   插件自动导入并删除模板文件

6. 或选择"立即导入"（无需重启）]],
}

function I18n.language()
    local lang
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language")
    end
    return lang or "en"
end

function I18n.is_zh()
    return tostring(I18n.language()):lower():match("^zh") ~= nil
end

function I18n.tr(text)
    if I18n.is_zh() then
        return zh[text] or text
    end
    return text
end

return I18n
