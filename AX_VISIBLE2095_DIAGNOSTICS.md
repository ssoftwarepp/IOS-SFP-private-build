# visible2095 C 接口与诊断契约

## 目标与验证边界

`legacy` 保留原有层级遍历；`visible2095` 独立通过 C AX 接口创建 application、读取 2095 数组及数组内节点属性，不再调用 `+uiApplicationWithPid:`、`-uiElementsWithAttribute:` 或 `-objectWithAXAttribute:`。只使用 2095 中的元素构建新轨道，不并入 3015，不按框的上下位置删节点，不按相同 label 合并。

设备旧版反馈 `stage=application-method` 已证明类方法入口在该次运行环境不成立。C 轨道编译通过、故障注入通过与真实设备采集成功是不同验证层级；2095 是否排除当前页面遮挡节点仍以真机对比为准。

## 接口

```python
from zxtouch.client import zxtouch

phone = zxtouch("127.0.0.1")
try:
    tree = phone.get_element_tree(mode="visible2095", budget_ms=12000, timeout=20)
    print(tree["sourceCounts"])
    print(tree["diagnostics"])
finally:
    phone.disconnect()
```

- `mode`：`legacy`（默认）或 `visible2095`。
- `budget_ms`：100..30000 整数，默认 3000，可由调用方配置。
- HTTP：`GET /api/ax/tree?mode=visible2095&budgetMs=12000&token=<配对令牌>`。
- TCP task 32：`3212000;;visible2095\r\n`；预算紧跟任务号。
- `count` 包含 application 根，`candidateCount` 为实际返回节点数，`sourceCounts.2095` 为原始列表长度；三者口径不同。
- `sourceCounts.3015` 为原始 3015 数组长度；读取失败、非数组或预算跳过时为 `null`，具体原因见诊断。
- C runtime 候选按 AXRuntime、两个 Accessibility framework 路径、`/usr/lib/libAccessibility.dylib` 顺序查找符号；诊断报告每个路径的加载结果和原始动态链接错误。

## 预置阶段与稳定代码

错误域 `ZXTouchAX`。整次失败消息将 `stage`、`errorCode`、`pid`、`axStatus`、`attribute`、`nodeIndex` 放在开头，后跟完整 JSON 诊断。失败还写 SpringBoard 系统日志；Python / HTTP 的原始错误文本保留这些字段。

| 代码 | 阶段 | 处理 |
| --- | --- | --- |
| 100 | `budget-validate` | 参数不是有限 0.1..30 秒；整次失败 |
| 101 | `foreground-pid` | AXFrontBoard 与前台应用回退均无有效 PID；整次失败 |
| 102 | `runtime-load` | 全部 AXRuntime/Accessibility 框架候选加载失败；记录每个路径及 dlerror；整次失败 |
| 103 | `symbol-create` | 两个 C 创建函数均缺失；整次失败 |
| 104 | `symbol-copy` | `AXUIElementCopyAttributeValue` 缺失；整次失败 |
| 105 | `symbol-value-type-id` | `AXValueGetTypeID` 缺失；整次失败 |
| 106 | `symbol-value-type` | `AXValueGetType` 缺失；整次失败 |
| 107 | `symbol-value-get` | `AXValueGetValue` 缺失；整次失败 |
| 108 | `application-create` | C 创建函数返回空；整次失败 |
| 110 | `visible-copy-2095` | AX 返回非零或空值；整次失败 |
| 111 | `visible-type-2095` | 2095 返回非 CFArray；整次失败 |
| 112 | `visible-budget-2095` | 预算在首次 2095 请求前已耗尽；整次失败 |
| 120 | `node-element-type` | 数组成员类型与 application 类型不同；跳过成员，计数并采样 |
| 121 | `node-frame-copy` | 属性 2003 读取错误或缺失；跳过节点 |
| 122 | `node-frame-type` | 属性 2003 不是矩形 AXValue；跳过节点 |
| 123 | `node-frame-decode` | AXValue 解码失败；跳过节点 |
| 124 | `node-frame-finite` | 矩形含 NaN/Inf；跳过节点 |
| 130 | `node-build` | 非空 2095 全部成员无有效节点且未触及预算；整次失败，保留节点错误样本 |
| 140 | `json-serialize` | 快照 JSON 序列化失败；整次失败 |
| 190 | 当前活动阶段 | Objective-C 异常；整次失败，保留异常名称/原因 |
| 201 | `frontboard-load` / `frontboard-symbol` | PID 快速入口缺失；记录后继续前台应用回退 |
| 202 | `symbol-requesting-client` | 可选 `__AXSetRequestingClient` 缺失；继续并记录 |
| 203 | `symbol-associate` | 可选 `_AXAddAssociatedPid` 缺失；继续并记录 |
| 204 | `symbol-timeout` | 可选 `AXUIElementSetMessagingTimeout` 缺失；继续并记录预算仅能在调用之间检查 |
| 205 | `messaging-timeout` | 设置单次 AX 消息超时返回非零；记录原始状态，继续 |
| 210 | `count-copy-3015` | 3015 读取错误或空值；数量为 null，继续 |
| 211 | `count-type-3015` | 3015 非 CFArray；数量为 null，继续 |
| 212 | `count-budget-3015` | 预算跳过 3015；数量为 null，标记截断 |
| 220 | `node-activation-copy` / `node-activation-decode` | 2007 可选激活点不可用；使用 frame 中心，保留原因 |
| 221 | `node-traits-copy` / `node-traits-type` | 2004 traits 不可用；返回空 traits，省略 enabled |
| 222 | `node-label-copy` / `node-label-type` | 2001 label 不可用；省略 label |
| 223 | `node-value-copy` / `node-value-type` | 2006 value 不可用；省略 value |
| 224 | `node-hint-copy` / `node-hint-type` | 2002 hint 不可用；省略 hint |
| 230 | `node-budget` | 预算在节点处理中耗尽；返回此前完整节点，当前不完整节点不返回 |
| 231 | `candidate-limit` | 达到 2000 个候选检查上限；返回部分节点 |

`axStatus` 为 C AX 调用的原始返回码；未调用 AX 或错误不来自 AX 时为 `null`。未涉及属性/节点时分别为 `null`。空的 2095 数组是有效空结果，不使用 130。

## 诊断字段

`diagnostics.schemaVersion=2`，`diagnostics.backend="c-ax"`。

- `stage`：最近活动阶段；成功为 `complete`，失败为实际阶段。
- `stages[]`：运行库、符号、PID、客户端、application、数组、节点汇总与序列化的检查点，包含 `stage`、`state`、`elapsedMs`、阶段专属字段；`state` 是 `ok`、`failed`、`warning`、`partial`。
- `runtimeCandidates[]`：框架路径、是否加载及错误；`symbols`：每个符号是否找到；`createSymbol`：使用的创建函数。
- `pidSource`：PID 来源；`pid`：实际请求进程。
- `attributeStats`：按 2095/3015/2003/2007/2004/2001/2006/2002 统计 attempted、ok、empty、axError、typeError、invalid、budgetSkipped。
- `issuesTotal`：全部异常/降级数；`issueCounts`：按 code/stage/AX status 聚合；`issues[]`：最多 32 个样本，含节点索引、属性、AX 状态、CF 类型等；`issuesTruncated` 明确样本是否截断。
- `examinedCount`、`returnedCount`、`skippedCount`：处理成员数、返回节点数及类型/坐标错误跳过数。
- `limitReason`：`budget` 或 `candidate-limit`，未触及上限为 null。
- `queueWaitMs`：进入主队列等待时间；`captureMs`：实际抓取用时；`elapsedMs`：包括初始化和序列化在内的总时间。
- `messagingTimeoutAvailable`、`lastMessagingTimeoutSeconds`：是否可设置远端消息超时以及最近设置值。

每个节点字段按其原始类型验证；可选字段缺失通过 attributeStats 记录，不当作空字符串/false。异常或错误类型仍有具体 issue。原始数组计数不会改成返回节点数量。

## 预算行为

进入主队列前建立唯一 deadline，主队列排队时间计入该预算并单列报告；PID 查找、各框架加载、符号解析、客户端配置、application 创建及每次 AX 属性读取前均检查剩余预算，不为每个节点重置预算。JSON 序列化不属于远端采集预算。每次 AX 属性读取前，把可用的 messaging timeout 设置为 `min(0.5 秒, 剩余时间)`。C 远端调用不可取消；单个 C API 调用发生阻塞时，截止只能在该调用返回后识别，故预算不是严格实时上限。新入口不持锁等待主队列，避免同步主队列与采集锁互锁。

预算耗尽时保留此前完整节点及原始计数，`limitReached=true`、`limitReason="budget"`。3015 尚未读取则为 null 并附 212。读取到非空 2095 但尚未完成第一个节点时，可返回根节点及截断诊断；不得将其说成 2095 没有元素。

## 验证和故障注入

## 当前验证记录

本节只记录实际运行结果；未运行项保持未验证，不能从契约测试或构建成功推断。

| 检查 | 证据/结果 |
| --- | --- |
| Python 协议与分阶段诊断契约 | 旧账号公开 `main` 基线的隔离 worktree（含 AX 客户端/任务协议依赖）运行 `python -m unittest discover -s tests -q`：98 tests，OK。Windows checkout 的 OCR 字典与 manifest 曾不匹配；与公开 main 原始内容及其 manifest 比较后，在隔离 worktree 对齐未改字典的字节，再全量通过。 |
| 原生 AX stub 故障注入 | 未运行；仓库当前未配置 Apple SDK 的原生 test harness。 |
| macOS Xcode、Rootless、Roothide 构建 | 提交当前源码后由 GitHub Actions 实测，记录 run URL、SHA 和 steps。 |
| 两份下载产物 C 轨道标志 | 构建成功后下载并做文件/归档检查，记录两个包哈希。 |
| 真机 2095 与遮挡页对照 | 待安装构建产物后验证；本地静态检查和 CI 构建不算设备证据。 |

设备待验证项不得以本地测试通过或构建成功替代。
