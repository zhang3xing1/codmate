# Overview 索引与缓存重构任务清单

背景与目标
- 采用 “Spotlight 式” 首次全量索引 + 持续增量索引，降低启动/刷新 CPU 与内存占用，稳定供给 Overview、Sessions 列表、Timeline。
- 单次解析产出全部指标（tokens/active time/messages/tools/thinking 等），落地统一缓存，避免二次扫描。
- UI 先读缓存，后台按需补齐；未可见范围不触发解析。

非目标
- 不改 CLI 生成的日志格式；仅消费现有文件。
- 不在此阶段实现全文检索或大规模 UI 重设计。

核心数据模型（单条 Session 缓存字段）
- sessionId, source(cli 类型), project, cwd/path
- title/comment (含 codmate 自写字段)
- createdAt, updatedAt, duration, activeTime
- message counts: user/assistant/tool/reasoning/other
- tokens: input/output/cache_read/cache_creation/total
- thinking/tool 调用次数，resume flags，hasTerminal/hasReview 等
- errors/版本：schemaVersion, parseError, file mtime/size/hash

存储方案
- SQLite（推荐）：表 `sessions` 主键 sessionId，索引：project, updatedAt, createdAt, source；可选 `aggregates` 物化表或视图。
- 记录 schemaVersion，支持迁移；解析失败记录错误并附 mtime/size，未变更不重复重试。

索引管线
- 阶段 1：超轻量枚举（path + mtime + size），立即返回缓存命中值供 UI 渲染。
- 阶段 2：增量解析队列（并发=max(2, cpu/2)，Claude 可单独更低），仅处理缓存缺失或 mtime/size 变化的文件；单次解析产出全部字段，批量写 SQLite（事务）。
- 阶段 3：聚合预热，仅针对当前可见 scope（All/项目/日期），SQL 聚合推送 UI；全量聚合放后台。

操作范围（scope）定义
- All：全部 session。
- Project：某项目或多选项目的 session。
- Date 范围：当天或日历选中范围（Created/Last Updated 两种维度）。
- 可见范围=当前 UI 选中的 scope；后台刷新仅覆盖可见范围。

刷新触发与范围控制
- 启动/前台：只做阶段 1 + 当前 scope 的增量解析，不全库重扫。
- Cmd+R：仅刷新当前可见 scope；无 scope 变化不扫其他项目/日期。
- 文件监控：事件去抖（~500–1000ms），仅处理变更文件；无变更不触发解析。
- CodMate 内部写入（改 title/comment/project）：直接更新缓存记录，不触发文件解析。

Claude/Codex/Gemini 解析策略
- 一次流式解析：逐行读取 usage/timestamps/counters，避免 mmap 全量；Claude 超大文件使用小 chunk + 早停。
- tokens/active time/messages 同步产出并写缓存；totalTokens>0 视为稳定值，除非 mtime/size 变。

Overview 聚合
- SQL 层完成 `SUM(tokens) / SUM(duration) / COUNT(messages)` 等聚合，Swift 侧仅接收结果。
- 每个 scope 保持内存快照，接收缓存增量事件（insert/update/delete）。

输入输出路径（事实来源）
- Codex 会话：`~/.codex/sessions/**/*.jsonl`
- Claude 会话：`~/.claude/projects/**/*.jsonl`
- Gemini/其他：各自 CLI 日志路径（保持现有扫描范围）。
- CodMate 自写：`~/.codmate/notes/*.json`（title/comment），项目元数据。

缓存文件位置（建议）
- SQLite/LSM 文件：`~/.codmate/sessionIndex-v2.db`（新版本号），避免覆盖旧缓存；落地后通过 schemaVersion 管理。

性能/健壮性护栏
- 并发：总并发=max(2, cpu/2)；Claude 并发单独限流（如 min(2, cpu/4)）。
- 写入：批量事务写 SQLite；失败文件标记，mtime 变更前不重试。
- 退避：外部 usage API 失败指数退避，避免启动时重试风暴。

验收口径（每步完成需满足）
- 功能等价：UI 展示与现状一致或更优，无数据缺失。
- 性能：启动/前台自动刷新时 CPU/内存明显低于现状；全量索引仅首次发生。
- 准确性：tokens/active time/messages 统计与手工解析一致（包含 Claude 样本 5,845,124）。
- 稳定性：无崩溃；坏文件不导致无限重试；无无谓全库重扫。

验证与指标
- 样本文件：Claude 期望 tokens=5,845,124（现有参考）；Codex/Gemini 各选 1–2 个大文件验证。
- 启动阶段 CPU/内存曲线下降；首次全量索引耗时可接受且仅一次。
- UI：All/Project/日历范围均显示非零 tokens/active time；刷新不触发全库重扫。

任务拆解（按顺序执行，逐步验证）
1) 设计并落地 SQLite schema + 迁移钩子；实现缓存读写 API（无业务改动）。
2) 重构 SessionIndexer 管线为阶段 1/2/3，接入缓存读写；UI 仍读旧模型（无需改视图），功能等效：
   - 阶段 1：枚举 + 缓存命中返回；无解析。
   - 阶段 2：增量解析 + 批量写缓存；只处理缓存缺失或 mtime/size 变更。
   - 阶段 3：仅对当前 scope 做 SQL 聚合并推 UI；全量聚合放后台。
3) 接入一次解析产出全字段的 parser（Claude/Codex/Gemini）：
   - Claude 流式逐行读取 usage/timestamps，输出 tokens/active time/messages；超大文件 chunk+早停；并发单独限流。
   - Codex/Gemini 复用现有 token_count/usage 解析，一次产出所有字段。
   - 写入缓存后不再做二次 token/activeTime 扫描。
4) 改造 refresh 触发与范围控制：
   - 启动/前台/文件监控事件去抖；仅刷新当前 scope；Cmd+R 也只刷新当前 scope。
   - CodMate 内部修改元数据直接更新缓存，不触发文件解析。
5) Overview 聚合改为 SQL + 内存快照：
   - SQL 完成 SUM/COUNT，Swift 仅接收结果；内存快照跟踪 insert/update/delete。
   - 验证 All/Project/日历统计一致性。
6) 性能护栏落地：
   - 并发限流（总并发=max(2,cpu/2)，Claude 单独限流）。
   - 失败文件标记与重试条件；写入批量事务；usage API 退避。
7) 验证与回归：
   - 样本对比（Claude 5,845,124 tokens 等）；启动能耗下降；缓存命中不重扫。

决策更新
- 全文检索：已有 rg，当前阶段不引入 FTS/索引分表。
- Tokens 存储：持久化分项（input/output/cache_read/cache_creation/total），为后续细颗粒度统计做储备。
- 变更判定：mtime+size 足够，不引入 hash（除非后续场景证明不足）。
- 缓存迁移：放弃旧 JSON 缓存迁移，首次全量依赖重新解析构建 SQLite 缓存。
- 首次全量 UI 提示：首次索引时展示骨架屏/刷新按钮旋转等轻量状态指示，提示缓存正在构建。

2025-12-04 差异对齐与统一策略（新增）
- 统一接口：抽象 xSessionProvider 协议（枚举/增量/缓存键/来源标签/timeline-enrich），Codex/Claude/Gemini 同一入口，上层不再来源特判。
- 统一变更检测与缓存：Claude/Gemini 引入 mtime+size（可含文件数/总 size）轻量检测，SQLite + 内存同策略命中；未变更不重解析、tokens 不重算。
- 统一刷新流程：冷启动先加载缓存→填 UI；增量刷新统一入口按来源策略调度（可保留 Codex 轻量预热，但主增量同批次）。延迟增量仅补差，不阻塞 UI。
- 统一 token 汇总：Codex/Gemini 继续尾扫/汇总；Claude 在 provider 内累加 usage，total 写缓存；0-token 稳定态可缓存，不反复扫描。
- 统一日志/指标：cache hit/miss、枚举/解析/增量耗时、来源/计数、延迟合并起止同一口径，便于回归分析。
- 预期收益：Workspace/Project Overview 以及项目/日期组合过滤均走缓存摘要过滤聚合，准确且响应快；冷启动/切换不触发全量重扫，三来源可观测性与维护成本下降。
