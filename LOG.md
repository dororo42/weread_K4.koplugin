
## 2026-11-15 09:45 — k4tls 详细审查完成（用户拍板「重新设计和评估，不是直接冻结」）

- **审查范围**：全部源码逐文件精读（lib/transport/http/tls/url/codes/auxv/build/Cargo + k4tls.lua），以 7 次 K4 segfault 为靶心沿五层展开。报告：`~/reports/k4tls_架构与编码详细审查报告-20261115.md`。
- **结论**：未发现可直接解释 segfault 的确定性缺陷；发现 2 个真实缺陷——🟡-1 `blob_len` 无界扫描（lib.rs:262，NUL 完整性依赖，建议 ABI 加显式长度字段）、🟡-2 `k4tls_free_response` 无 catch_unwind（lib.rs:237，F-12 注释承认的 deferred）；1 个架构债——同步 FFI 阻塞宿主 UI 主线程（QR 迟钝根源，重设计核心 = perform 分段化）；1 个 K4 特有风险面——DNS worker 常驻线程 × 宿主 fork（crash 前 lipc-wait-event 伴生现象唯一结构吻合线索）；5 项 🟢 优化。审查通过项清单（指针生命周期/HTTP 边界/注入防御/K4 兼容）一并在报告记录。
- **重新设计路线 R1-R5**（报告 §五）：R1 修复两 🟡（一次 ABI 批次）→ R2 perform 分段化消除 UI 阻塞（K4 启用前提）→ R3 四项专项测试 → R4 决定性实验（**K5 复现 K4 场景** + K4 fork 压力实验）→ R5 分级启用（K5 先行，K4 等 R2）。启用门槛=专项验证+用户拍板，取代「冻结」与「直接翻闸」。
- **同批交付**：QR 提示条按用户二次拍板精简为仅限时句（01c3ab2 已部署 K4，spec 锚定用例随文案更新，Back/Menu 图例删除、按键功能代码不动）。
