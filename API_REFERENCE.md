# IOS-SFP 接口参考

适用源码：本仓库当前 HTTP、Socket、Python 实现。本文按实际代码说明参数，不把浏览器调试页面当作脚本运行的前置条件。**覆盖范围**：项目公开的 24 个控制台 HTTP 路由、TCP 6000 的主要任务、`zxtouch.client.zxtouch` 的 42 个不以下划线开头的实例方法，以及 `automation`/`batch_scan` 对外辅助函数。这里的“42 个”包含 `disconnect`，不含构造器 `__init__` 与协议私有方法；不是 Python 标准库、iOS 系统 API 或项目所有 Objective-C 内部函数的全集。HTTP 路由源自 [`RemoteDashboardServer.m`](zxtouch/zxtouch/RemoteDashboardServer.m)、[`DashboardTools.inc`](zxtouch/zxtouch/DashboardTools.inc) 和 [`AdvancedTools.inc`](zxtouch/zxtouch/AdvancedTools.inc)；手机端 Python 源自 [`client.py`](layout/usr/share/zxtouch/python/zxtouch/client.py)、[`automation.py`](layout/usr/share/zxtouch/python/zxtouch/automation.py) 和 [`batch_scan.py`](layout/usr/share/zxtouch/python/zxtouch/batch_scan.py)。

## 1. 入口、认证与坐标

- HTTP 控制台：`http://<设备IP>:8080/`。所有 **24 条**路由（包括 `/`）都要求 URL 查询参数 `token=<配对令牌>`；令牌不匹配返回 HTTP 403、`{"ok":false,"error":"配对令牌无效。"}`。令牌放在 URL 查询串，**不是** JSON body 或 `Authorization` header。服务需在配置中启用且有令牌；见源码 `RemoteDashboardServer.m:83-97,452-503`。
- HTTP JSON POST：`Content-Type: application/json`；两个文件上传路由使用 `multipart/form-data`。普通成功响应为 HTTP 200；错误 JSON 均包含布尔字段 `ok:false` 和字符串字段 `error`，特殊状态码逐路由列出。截图、下载、首页成功时返回原始文件/HTML，而非 JSON。
- Socket：TCP `<设备IP>:6000`，Python `zxtouch(ip)` 可在手机脚本中使用 `127.0.0.1`；Socket 请求不使用 HTTP token。浏览器只是调试客户端，脚本在手机端独立连接 TCP 6000。
- **截图物理像素**：截图宽高、颜色点/搜索、模板匹配及其 ROI、Vision/PaddleOCR ROI 与结果框、`touch()` 均按截图左上角原点的像素。`region` 顺序统一为 `[x, y, width, height]`，前两项是左上角，不是右下角。`/api/status` 的 `screen.width/height` 是数值字符串。
- **AX 逻辑点**：AX `frame`、`get_element_at_point(x,y)`、`/api/ax/point` 和 `/api/ax/tap` 的输入为 iOS 逻辑点。转换到截图/触摸像素：`pixelX=pointX*screenScale`、`pixelY=pointY*screenScale`。`/api/ax/tap` 内部完成该转换；`automation.tap_element()` 同样完成转换。返回的 `screenScale` 是 number，不要再缩放找图结果。
- 命中与未命中不同：原生模板匹配成功但找不到目标时返回空 `matches` 和 `count:0`；找色可返回 `found:false`；OCR 成功但无文字返回空 `texts`。旧 `/api/image/match` 则把匹配失败视为 502。

以下示例中 `DEVICE_IP` 和 `PAIR_TOKEN` 是调用方持有的实际设备 IP、配对令牌；请求示例为结构示范，不含现成密钥。

## 2. HTTP：脚本、状态及日志

除特别注明外，下列所有 HTTP 路由均附加 `?token=<配对令牌>`，无额外公共 body 字段。

### `GET /`

无其他参数。返回控制台 HTML（`text/html`）。页面入口是 `/var/jb/Applications/zxtouch.app/index.html`；文件不可读时返回简短的 HTML 文本。源：`RemoteDashboardServer.m:332-348`。

### `GET /api/scripts`

无其他参数。返回 `{"ok":true,"scripts":[...]}`；每个 `scripts[]` 对象：`path` 为相对于 `/var/mobile/Library/ZXTouch/scripts/` 的 `.bdl` 目录路径，`name` 为不带 `.bdl` 的名称，`entry` 为 `info.plist` 中的入口文件名（缺失时 `""`），`type` 为入口文件扩展名（缺失时 `""`）。按 `name` 排序。源：`RemoteDashboardServer.m:116-142,350-354`。

### `GET /api/status`

无其他参数。返回 `{"ok":true,"status":{...}}`，`status` 各字段如下：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `running` | boolean | HTTP 服务是否运行。 |
| `serviceOnline` | boolean | TCP 6000 屏幕尺寸查询是否成功。 |
| `port` | number | HTTP 端口，默认 8080。 |
| `screen.width`, `screen.height` | string | 屏幕像素宽、高；查询失败时可能为空串。 |
| `screenScale` | number | iOS 逻辑点到截图物理像素的倍率。 |
| `orientation` | string | 设备返回的屏幕方向值，失败时为空串。 |
| `battery` | string | 设备返回的电量字段，失败时为空串。 |
| `foregroundApp` | string | 当前前台应用的 bundle ID，失败时为空串。 |
| `scriptPlaying`, `recording` | boolean | 是否正在执行脚本、录制。 |
| `lastAction`, `lastError` | string | 最近一次控制台动作、错误描述。 |
| `scriptCount` | number | 扫描出的 `.bdl` 脚本包数量。 |

源：`RemoteDashboardServer.m:282-314,356-360`。

### `GET /api/logs`、`POST /api/logs/clear`

均无其他参数、无请求 body。`GET` 返回 `{"ok":true,"logs":"..."}`，`logs` 为脚本运行输出；文件缺失返回空串，过长仅保留末尾 262144 个 UTF-16 字符并添加截断提示。`POST` 清空日志，成功 `{"ok":true}`，文件写入失败 HTTP 500 错误 JSON。日志路径 `/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output`。源：`Config.h:14`、`RemoteDashboardServer.m:316-320,362-376`。

### `POST /api/run`、`POST /api/stop`

- `/api/run` body：`path`，必填 string，为 `/api/scripts` 中的相对 `.bdl` 路径，例如 `demo.bdl`；目录必须位于脚本根目录下并实际存在。不存在返回 HTTP 404。成功或底层启动失败均为 HTTP 200 `{"ok":boolean,"result":string}`：`ok` 判断 TCP 原始响应是否以 `0` 开始，`result` 保留原始响应。
- `/api/stop` 无 body；HTTP 200 `{"ok":boolean,"result":string}`，`ok` 为底层响应以 `0` 开始。源：`RemoteDashboardServer.m:100-114,378-395`。

### `POST /api/record/start`、`POST /api/record/stop`

无 body。两者都返回 HTTP 200 `{"ok":boolean,"result":string}`；`result` 是底层响应文本。开始录制的 `ok` 判定为响应不以 `-1` 开始；停止录制判定为响应以 `0` 开始。源：`RemoteDashboardServer.m:397-411`。

### `GET /api/script`、`POST /api/script`、`POST /api/script/new`

- `GET /api/script?token=...&path=demo.bdl`：`path` 必填 string，相对 `.bdl` 路径。仅能读取 `info.plist` 的 `Entry` 指向的包内直接子文件 `.py`，要求 UTF-8 可读。成功 `{"ok":true,"path":"demo.bdl","content":"<Python源码>"}`；路径/类型错误 HTTP 400，入口读取失败 404。
- `POST /api/script` JSON：`path` 必填 string，同上；`content` 必填 string，新 Python 源码，UTF-8 编码长度最多 1048576 字节（空串允许）。成功 `{"ok":true}`；输入 HTTP 400，保存失败 500。
- `POST /api/script/new` JSON：`name` 必填 string，1..80 字符，不能是 `.`、`..`，不能含 `/`、`\`、`:`、回车或换行；`content` 必填 string，UTF-8 最多 1048576 字节。生成 `<name>.bdl/info.plist`（`Entry=main.py`、`FrontApp=""`、`Orientation="1"`）和 `main.py`。成功 `{"ok":true,"path":"<name>.bdl"}`；输入 HTTP 400，名称已存在 409，文件操作失败 500。源：`DashboardTools.inc:146-212`。

### `POST /api/assets`、`GET /api/download`

- `/api/assets` 为 multipart：`script` 必填 string，目标相对 `.bdl` 路径；`asset` 必填 file，上传的原始文件。文件名取上传名的最后一段，不能为空、`.`、`..`、`info.plist`，也不能含路径分隔符；**不限制扩展名**，最多 25 MiB。保存到脚本包根目录，同名文件先删除再复制。成功 `{"ok":true,"file":"文件名"}`；输入 HTTP 400，过大 413，复制失败 500。
- `/api/download?token=...&path=demo.bdl`：`path` 必填 string，目标相对 `.bdl` 路径；返回 `info.plist` 的 `Entry` 指向的文件，原始字节、附件下载响应；入口不存在返回 HTTP 404 JSON。此路由不进行 `.py` 编辑器的入口类型检查。源：`RemoteDashboardServer.m:323-330,413-447`。

## 3. HTTP：视觉与 AX

### `GET /api/screenshot`

无其他参数。成功 HTTP 200，`Content-Type: image/png`，body 为 PNG 二进制截图；底层失败 HTTP 502 错误 JSON。截图尺寸就是后续图色 ROI 的物理像素边界。源：`DashboardTools.inc:1-8`。

### `GET /api/ax/tree`、`POST /api/ax/point`、`POST /api/ax/tap`

- `/api/ax/tree` 无其他参数。成功 `{"ok":true,"tree":{...}}`；`tree` 有 `pid`（number，前台进程 ID）、`count`（number，节点数）、`candidateCount`（number，额外候选计数）、`limitReached`（boolean，采集触及上限）、`root`（AX 节点）。底层失败/缺失 root 为 HTTP 502。
- AX 节点常见字段：`role`（角色字符串）、`children`（子节点数组）、`frame`（`{x,y,width,height}`，逻辑点）、`identifier`、`label`、`value`、`elementType`、`windowContextId`、`source`、`snapshotPath`；除节点结构外具体属性由可用性决定，并非每个节点都有。树结合真实子节点和窗口/数字候选集合，`role:"AXCandidateGroup"` 的分组并不表示纯粹的递归 `AXChildren` 关系。源：`AccessibilityTree.xm:76-168,274-337,481-484`。
- `/api/ax/point` JSON：`x`,`y` 均必填有限 number，范围 0..10000（含边界），单位为屏幕**逻辑点**。成功 `{"ok":true,"result":{"pid":number,"x":number,"y":number,"element":AX节点}}`；无命中或底层失败 HTTP 502，格式错误 400。源：`AdvancedTools.inc:1-17`。
- `/api/ax/tap` JSON：`x`,`y` 必填有限 number、范围 `[0,10000)`，单位逻辑点；`jitter` 可选 number/boolean，默认 false；`minDelayMs` 可选 number，默认 0；`maxDelayMs` 可选 number，默认 `minDelayMs`。两项延时均须有限且满足 `0<=minDelayMs<=maxDelayMs<=2000`（毫秒）。`jitter=false` 时仍校验延时，但实际传入 0。命中点先乘 `screenScale` 再发触摸。成功 `{"ok":true,"x":原输入,"y":原输入}`；输入 HTTP 400，触摸失败 502。源：`DashboardTools.inc:23-52`。

### `POST /api/color/pick`、`POST /api/color/search`

- `/api/color/pick` JSON：`x`,`y` 必填 number、范围 `[0,10000)`，坐标会取整数，单位截图物理像素。成功 `{"ok":true,"rgb":["R","G","B"]}`，RGB **三个元素是字符串**，各值 `0..255`；输入或超界 HTTP 400，底层失败 502。源：`DashboardTools.inc:54-74`。
- `/api/color/search` JSON：`region` 必填 `[x,y,width,height]` 四个有限 number，取整后 `x,y>=0`、`width,height>0`、`x+width,y+height<=10000`；`rgb` 必填 `[R,G,B]` 三个有限 number，取整后每通道 0..255；`tolerance` 可选 number，默认 0，取整后 0..255。颜色比较每通道在 `[rgb-tolerance,rgb+tolerance]`（截断至 0..255）。未找到成功响应 `{"ok":true,"found":false}`；找到为 `{"ok":true,"found":true,"x":"像素坐标","y":"像素坐标","rgb":["R","G","B"]}`，坐标与通道均为字符串。输入 HTTP 400，底层错误 502。源：`DashboardTools.inc:76-115`。

### `POST /api/image/match`（旧单图接口）

JSON：`path` 必填 string，相对 `.bdl` 包；`template` 必填 string，该包内单个 `.png`/`.jpg`/`.jpeg` 文件名；`threshold` 可选 number，`(0,1]`，缺失或不在范围时重置为 `0.8`。底层固定最多尝试 2 次、缩放因子 `0.8`，不支持 ROI、掩模、多个命中或独立模板库。成功 `{"ok":true,"frame":{"x":"...","y":"...","width":"...","height":"..."}}`；四个 frame 值是数字字符串、单位物理像素。输入 HTTP 400，文件缺失 404，底层匹配失败 502。源：`DashboardTools.inc:117-144`。

### `POST /api/image/templates`（上传独立模板）

multipart 的 `asset` 必填 file：PNG 文件，文件名需满足上文素材安全名称规则并以 `.png` 结尾；文件大小 **1..25 MiB**。保存到设备 `/var/mobile/Library/ZXTouch/templates/`，同名文件原子覆盖。成功 `{"ok":true,"name":"模板.png"}`；文件名 HTTP 400，空文件/超限 413，写入失败 500。此接口不需要 `script`。源：`AdvancedTools.inc:19-40`。

### `POST /api/image/matches`（原生多模板）

JSON 请求的每个参数如下：

| 参数 | 类型 / 默认 | 作用 |
| --- | --- | --- |
| `templates` | 必填 array，1..12 项 | 每项 `{ "name":"图片.png", "script":"可选脚本包.bdl" }`。`name` 必填安全 PNG 文件名；`script` 省略时从独立模板目录读取，填写时从对应脚本包读取。数组索引就是结果 `index`，从 0 开始。 |
| `masks` | 可选 array，默认无掩模 | 与 `templates` 等长；每项为 `null`（该模板不过滤像素）或同上 `{name,script?}` PNG。掩模 alpha=255 的像素参与计算，其余跳过。 |
| `snapshot` | 可选 string，默认实时截图 | 独立模板目录中已有的 PNG 文件名。填入时以该图代替实时截屏，用来测试“同一帧裁剪后找图”；不接受路径。 |
| `region` | 可选四数字数组，默认全图 | `[x,y,width,height]`，物理像素；负起点截到 0，右/下边界截到截图尺寸，截取后区域必须非空。 |
| `threshold` | 可选 number，默认 0.85 | 分数阈值，`0<threshold<=1`。 |
| `maxResults` | 可选整数，默认 30 | 返回的非重叠命中上限，`1..100`；优先保留分数高的命中。 |
| `minScale` | 可选 number，默认 1 | 起始模板倍率，范围 `0.25..3`，不大于 `maxScale`。 |
| `maxScale` | 可选 number，默认 1 | 结束模板倍率，范围 `0.25..3`，不小于 `minScale`。 |
| `steps` | 可选整数，默认 1 | 从最小到最大倍率采样的尺度数，`1..9`；为 1 时仅使用 `minScale`。 |

成功 `{"ok":true,"result":{"matches":[{"index":0,"x":120,"y":240,"width":48,"height":48,"scale":1.0,"score":0.97}],"count":1,"width":750,"height":1334}}`：`x/y/width/height` 和顶层 `width/height` 都是截图物理像素的 **number**；`score` 为 0..1，`scale` 是模板倍率，`count` 等于 `matches` 数量。HTTP 层检查类型和文件，数值范围由设备端校验；输入 HTTP 400、文件缺失 404、底层匹配失败 502。**此接口是原生 RGB 找图，没有 `gray` 参数**；Python OpenCV 的 `gray` 是另一套实现。源：`AdvancedTools.inc:42-104`、`MaskedTemplateMatch.mm:41-204`。

### `POST /api/ocr`

JSON：`region` 可选四数字数组 `[x,y,width,height]`，默认 `[0,0,0,0]`；每项有限 number、范围 0..10000（含），单位截图物理像素；宽高为零时按引擎的全屏语义处理。`engine` 可选 string，取 `vision`（默认，iOS Vision）或 `paddleocr`（本机 worker）。

- Vision 成功：`{"ok":true,"texts":[{"text":"字","x":"100","y":"200","width":"30","height":"18"}]}`。框四项是 **string**，像素坐标；无文本是 `texts:[]`。Vision 此 HTTP 路由使用默认的准确模式、无自定义词、无纠错。
- PaddleOCR 成功：`{"ok":true,"texts":[{"text":"字","x":100,"y":200,"width":30,"height":18,"confidence":0.94}],"engine":"paddleocr","provider":"...","worker_pid":123}`。`x/y/width/height` 和 `confidence` 是 number；`provider` 为引擎提供者字符串，`worker_pid` 为 worker 进程 ID。
- 输入 HTTP 400、截图/识别失败 502；非 SpringBoard 服务的编译分支请求 PaddleOCR 返回 503。PaddleOCR ROI 必须落在实际截图内。源：`AdvancedTools.inc:106-146`、`PaddleOCRBridge.m:166-182,228-239`。

HTTP 示例（配对令牌以命令行环境变量提供）：

```bash
curl --get --data-urlencode "token=$PAIR_TOKEN" "http://$DEVICE_IP:8080/api/status"
curl --get --data-urlencode "token=$PAIR_TOKEN" "http://$DEVICE_IP:8080/api/screenshot" --output screen.png
curl -X POST "http://$DEVICE_IP:8080/api/image/matches?token=$PAIR_TOKEN" -H 'Content-Type: application/json' -d '{"templates":[{"name":"button.png"}],"region":[0,0,750,1334],"threshold":0.9,"maxResults":5}'
curl -X POST "http://$DEVICE_IP:8080/api/ocr?token=$PAIR_TOKEN" -H 'Content-Type: application/json' -d '{"engine":"paddleocr","region":[0,0,0,0]}'
```

## 4. Socket 6000 协议

请求以 UTF-8 文本发送，末尾 `\r\n`；构造方式为 `str(task) + ';;'.join(str(arg) for arg in args) + '\r\n'`。**任务号与第一个参数紧挨着，不额外加 `;;`**。例如 `271;;0,,0,,0,,0;;;;0;;0;;;;0;;\r\n` 是任务 **27** 的 OCR 子任务 **1**，不是任务 271。普通成功响应以 `0` 开头、字段用 `;;` 隔开并以 CRLF 结束；错误为 `-1;;原因\r\n`。Python 普通响应解码为 `(True,list[str])` 或 `(False,str)`。源码：`datahandler.py:1-26`、`SocketServer.xm:123-155`、`Task.xm:30-47`。

| 任务 | 请求参数 | 成功响应 |
| --- | --- | --- |
| 30 截图 | 无；发送 `30\r\n` | `0;;image/png;;N\r\n` + 精确 `N` 字节 PNG。 |
| 31 平面元素 | 无；手机端 ios-mcp 服务需响应 | `0;;application/json;;N\r\n` + `N` 字节 JSON-RPC 结果；客户端解出 `elements` 平面数组。 |
| 32 AX 树 | 无 | `0;;application/json;;N\r\n` + `N` 字节 `{pid,count,candidateCount,limitReached,root}`。 |
| 33 原生多图 | 一个参数：UTF-8 JSON 的 Base64 文本，键 `templates` 为 1..12 个设备端 PNG **绝对路径**；其余键 `masks`、`screenshot`（设备端 PNG 绝对路径）、`region`、`threshold`、`maxResults`、`minScale`、`maxScale`、`steps` 同 HTTP 多图参数；`masks` 与模板等长且允许 `null` | `0;;application/json;;N\r\n` + `N` 字节 JSON `{matches,count,width,height}`。 |
| 34 AX 坐标命中 | 一个参数：Base64(UTF-8 JSON `{"x":逻辑点,"y":逻辑点}`) | `0;;application/json;;N\r\n` + `N` 字节 JSON `{pid,x,y,element}`。 |
| 35 结束进程 | 一个参数：应用 Bundle ID（不得含 `;;` 和控制字符）；例如 `35com.apple.Preferences\r\n` | `0;;N\r\n`，`N=1` 为确认退出、`N=0` 为已安装但未运行；失败 `-1;;原因\r\n`。 |
| 42 已安装应用 | 无 | `0;;application/json;;N\r\n` + JSON `{apps:[{bundleId,name,type}]}`，包含系统与用户安装应用。 |
| 43 读取剪切板 | 无 | 定长 JSON `{text:字符串}`，支持空文本和换行。 |
| 44 清除应用数据 | Bundle ID | 定长 JSON `{bundleId,removedEntries}`；失败 `-1;;原因\r\n`。 |
| 45 前台进程名 | 无 | 定长 JSON `{name:可执行文件名}`；SpringBoard 返回 `SpringBoard`。 |
| 46 设置剪切板 | Base64 编码的 UTF-8 文本 | `0\r\n`；失败 `-1;;原因\r\n`。 |
| 27/1 Vision OCR | 第一个参数 `1`，然后 `region`、`custom_words`、`minimum_height`、`recognition_level`、`languages`、`auto_correct`、`debug_image_path` | 普通文本响应 `0;;text,,x,,y,,width,,height;;...\r\n`。 |
| 27/2 OCR 语言 | 第一个参数 `2`，然后 `recognition_level` | 普通文本响应，可用语言字符串列表。 |

长度帧必须先读取完整 CRLF 头，再读取 **恰好 N 字节**；后续二进制负载不能按换行切割。任务 31 依赖设备本机 ios-mcp `8090/mcp`；任务 32/34 不依赖该外部服务。详细协议源：`Task.xm:315-490`、`client.py:17-84,484-555`。

## 5. 手机端 Python `zxtouch` 客户端

导入及连接：

```python
from zxtouch.client import zxtouch
from zxtouch.automation import find_img_all, locate_elements, tap_element

phone = zxtouch("127.0.0.1")
png = phone.screenshot()
tree = phone.get_element_tree()
hits = phone.match_templates(["/var/mobile/Library/ZXTouch/templates/button.png"],
                             region=[0, 0, 750, 1334], threshold=0.9)
phone.disconnect()
```

`zxtouch(ip)`：`ip` 必填，可转为字符串的设备地址；连接 TCP 6000。连接错误是 Python `OSError`。实例方法中通常的 `tuple` 返回形态为 `(success:bool, payload:list[str]|dict|str)`：普通 Socket 调用失败时返回 `(False,错误字符串)`；下列 PNG/JSON 长度帧方法则直接返回对象或抛 `RuntimeError`、`ConnectionError`、JSON 解码异常。普通 Socket 方法没有统一超时参数；AX 节点查询方法有独立的 `timeout`（秒）参数，默认 10 秒。

### 5.1 触摸、应用与脚本

| 方法签名 | 用途及每个参数与返回值 |
| --- | --- |
| `touch(type,finger_index,x,y)` | **发送一次触点动作**，按下、移动或抬起；它不是一次完整的点击。`type` 必填触摸事件类型：`1` 按下、`2` 移动、`0` 抬起；`finger_index` 必填触点序号，常用 `1`；`x,y` 必填截图物理像素坐标，发送时乘 10 编码。发送后立即返回 `None`，不读响应。 |
| `touch_with_list(touch_list)` | **一次发送多个触点动作**，可组合点击或轨迹。`touch_list` 必填列表，每项包含 `type`、`finger_index`、`x`、`y`，意义同 `touch`；同一次指令发送多事件并返回 `None`，不读响应。原实现用整数格式化每项的 `x*10,y*10`，传入整数像素最直接。 |
| `switch_to_app(bundle_identifier)` | **请求启动指定 App 并切换到前台**；已运行时切到前台。`bundle_identifier` 必填应用 bundle ID 字符串（如 `com.apple.Preferences`）。返回普通 `(bool,list[str]|str)`；目前任务 11 对启动函数的返回码不作检查，因此 `(True,[])` 只代表设备接受了指令，不能证明 App 已进入前台；用 `get_foreground_app()` 或 `/api/status` 的 `foregroundApp` 再确认。 |
| `kill_process(bundle_id)` | **按安装应用的 Bundle ID 结束进程**。例如 `com.apple.Preferences`；通过 FrontBoard 按 Bundle ID 请求退出，并核对 SpringBoard 的运行状态；确认退出返回 `(True,1)`，本来未运行返回 `(True,0)`；失败 `(False,错误字符串)`，非法标识抛 `ValueError`。 |
| `get_installed_apps()` | **列出系统与用户安装应用**；返回 `{apps:[{bundleId,name,type}]}`，通过 `bundleId` 操作应用。失败抛 `RuntimeError`。 |
| `clear_app_data(bundle_id)` | **结束应用并清除其数据容器内容**（保留容器登记元数据），返回 `{bundleId,removedEntries}`；失败抛 `RuntimeError`，非法标识抛 `ValueError`。不清除 App Group 数据。 |
| `get_foreground_process_name()` | **读取前台应用的可执行文件名**；返回字符串；SpringBoard 前台返回 `SpringBoard`，失败抛 `RuntimeError`。应用操作仍使用 Bundle ID。 |
| `show_alert_box(title,content,duration)` | **在手机界面弹出系统提示框**。`title` 标题、`content` 文案（均字符串）、`duration` 显示时长（秒）；返回普通 tuple。 |
| `run_shell_command(command)` | **在手机端调用 `/bin/sh -c` 执行命令**。`command` 必填 Shell 命令字符串。返回普通 tuple；任务 13 目前始终回 `0`，不透出命令 stdout、stderr 或退出码，所以 `(True,[])` 不等于 Shell 命令成功。源：`Task.xm:110-115`。 |
| `prompt_input(title="ZXTouch",message="",placeholder="",default_value="")` | **弹出带文本框的系统对话框并读取用户输入**。`title` 输入框标题；`message` 提示文本；`placeholder` 占位文本；`default_value` 初始文本。成功 `(True,输入文字)`，失败 `(False,错误字符串)`。 |
| `start_touch_recording()` / `stop_touch_recording()` | **开始记录设备触摸动作 / 结束录制**；均无参数；返回普通 tuple。 |
| `accurate_usleep(microseconds)` | **让设备端任务按微秒计时暂停后再回复**。`microseconds` 必填等待时长，单位微秒；返回普通 tuple。 |
| `play_script(script_absolute_path)` | **让设备的脚本运行器执行脚本包**，不是启动 App。`script_absolute_path` 必填手机端 `.bdl` 脚本包绝对路径；返回普通 tuple。 |
| `force_stop_script_play()` | **强制停止当前由 ZXTouch 运行的脚本**，不会结束该脚本操控的 App；无参数；返回普通 tuple。 |
| `disconnect()` | **断开本 Python 客户端与手机 TCP 6000 的连接**，不停止设备服务或脚本；无参数；返回 `None`。 |

### 5.2 运行 App、结束 App、网络请求

这三项需要区分 **ZXTouch 自带方法**、**Python 标准库** 与 **HTTP 控制台**：`switch_to_app()` 是项目自带的启动/切前台入口；源码已有按 Bundle ID 结束进程的 `kill_process(bundle_id)`，以及 `get_installed_apps()`、`clear_app_data(bundle_id)`，也没有 `http_get()` / `http_post()` 之类专用网络方法，也没有通用的设备端网络请求 Socket 任务。`POST /api/run` 运行的是 `.bdl` 脚本，不是 App；`POST /api/stop` 停止的是脚本，不是 App；控制台提供的 HTTP 路由是接收请求的服务端接口，不是供脚本向任意网址发请求的客户端接口。

**读取前台 App**：`get_foreground_app()` 不接收参数；返回 `(True,bundle_id)` 或 `(False,错误字符串)`。设备端查询前台应用并提取 bundle ID；查询不到应用 ID 时回退到 `com.apple.springboard`。不依赖 HTTP 控制台或配对令牌，直接通过 TCP 6000 运行状态子任务读取。源码：`client.py:394-403`、`DeviceInfo.xm:63-72`。

**启动或切换 App**：`switch_to_app(bundle_identifier)` 将应用包标识传给 SpringBoardServices `SBSLaunchApplicationWithIdentifier`。已有进程会被调到前台；未运行时由系统尝试启动。设备任务当前忽略系统函数的返回码，统一写入 `0` 回包，因此 Python 的 `(True,[])` 仅表示任务已被处理，不能作为应用实际在前台的证明；随后调用 `get_foreground_app()` 对比 bundle ID。源码：`client.py:115-126`、`Process.xm:7-21`、`Task.xm:56-61`。

**按 Bundle ID 管理应用**：已安装列表、终止、剪切板线程行为与 `ios-mcp` 对照；`ios-mcp` 只提供数据容器路径查询，没有清数据接口，本项目清数据前必须确认退出。`get_installed_apps()` 枚举系统和用户安装应用，返回应用的 `bundleId`、`name`、`type`。`kill_process(bundle_id)` 通过任务 35 向 `FBSSystemService` 发出 Bundle ID 终止请求，核对 `SBApplication.isRunning` 由真变假后返回 `(True,1)`；本来未运行返回 `(True,0)`，超时、运行态不可读、标识不存在或终止请求失败均返回 `(False,错误字符串)`。`clear_app_data(bundle_id)` 通过任务 44 定位应用数据容器，先终止并等待进程退出，再删除容器内应用文件，保留容器目录和登记元数据；不清理 App Group 容器。`get_foreground_process_name()` 取前台应用可执行文件名；实际指定应用操作仍使用 Bundle ID。`run_shell_command()` 仍不提供 Shell 命令退出码。

```python
from zxtouch.client import zxtouch

phone = zxtouch("127.0.0.1")
try:
    launch_reply = phone.switch_to_app("com.apple.Preferences")
    print("launch command reply:", launch_reply)
    print("foreground app:", phone.get_foreground_app())
    success, exited = phone.kill_process("com.apple.Preferences")
    print("app exited:", success, exited)
finally:
    phone.disconnect()
```

这里启动和结束应用都使用 `"com.apple.Preferences"` 这一 **Bundle ID**；前台进程名 `Preferences` 只用于展示。手机本地和远程 Python 客户端均通过 TCP 任务操作手机进程。

**网络请求**：手机端 Python 脚本可直接使用 Python 标准库 `urllib.request`。`url` 是目标 HTTP(S) 地址；`data` 是请求体原始 bytes，缺省为 GET，设置后下例显式用 POST；`Content-Type` 指明 JSON；`timeout` 是网络超时秒数；响应的 `status` 是 HTTP 状态码、`read()` 返回原始响应 bytes。该 API 与 ZXTouch TCP 6000 无关：

```python
import json
from urllib.request import Request, urlopen

request = Request(
    "https://example.com/api/events",
    data=json.dumps({"event": "task_complete", "count": 1}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urlopen(request, timeout=10) as response:
    print(response.status, response.read().decode("utf-8"))
```

若从电脑通过控制台读取设备状态，请求的是已有的 `GET /api/status?token=...`；这与脚本向外部服务发送网络请求是两个方向。

### 5.3 截图、图色与原生找图

- `screenshot()`：**截取当前设备屏幕**；无参数，返回原始 **PNG bytes**；头格式/类型/长度错误 `RuntimeError`，连接提前关闭 `ConnectionError`。源：`client.py:58-84`。
- `pick_color(x,y)`：**读取截图指定像素的 RGB 颜色**。`x,y` 必填截图物理像素坐标；返回 `(True,{"red":str,"green":str,"blue":str})` 或 `(False,错误字符串)`。
- `search_color(region,red_min,red_max,green_min,green_max,blue_min,blue_max,pixel_to_skip=0)`：**在指定矩形中寻找首个符合 RGB 三通道范围的像素**。`region` 必填 `(x,y,width,height)` 物理像素；`red_min/red_max`、`green_min/green_max`、`blue_min/blue_max` 分别为 R/G/B 的最小和最大通道值（0..255）；`pixel_to_skip` 为每次取样跳过的像素数，默认 0（逐像素）。找到时 `(True,{"x":str,"y":str,"red":str,"green":str,"blue":str})`；设备错误 `(False,str)`。`region` 不是四项时报 `RuntimeError`。源：`client.py:233-276`。
- `image_match(template_path,acceptable_value=0.8,max_try_times=2,scaleRation=0.8)`：**在当前屏幕中定位一张模板并返回它的矩形**；旧任务 21。`template_path` 必填设备上单张模板路径；`acceptable_value` 通过阈值；`max_try_times` 最大尺度尝试次数；`scaleRation` 每轮模板缩放倍率（拼写是源码原名）。成功 `(True,{x:str,y:str,width:str,height:str})`；失败 `(False,str)`。与任务 33 的分数、ROI、掩模能力不同。源：`client.py:202-218`。
- `match_templates(templates,*,masks=None,region=None,threshold=0.85,max_results=30,min_scale=1,max_scale=1,steps=1)`：**在手机端对当前屏幕做多模板、多倍率、可掩模找图**；只抓当前屏，不使用网页。`templates` 必填 1..12 项设备端 PNG **绝对路径**；`masks` 可选对应掩模路径或 `None`，数组须等长；`region` 可选四项像素 ROI，默认全图；负起点按 0 截断，右/下边界截到截图尺寸，最终区域须非空；`threshold` 范围 `(0,1]`；`max_results` 1..100；`min_scale/max_scale` 倍率范围 0.25..3；`steps` 1..9。返回 JSON 解码后的 `{matches,count,width,height}` 字典，结果字段与 HTTP 多图相同；协议/底层错误抛 `RuntimeError`，短包 `ConnectionError`。本地参数由服务端最终校验。源：`client.py:503-533`。

### 5.4 AX 与 OCR

- `get_ui_elements(timeout=10)`：**从设备本机 ios-mcp 取得平面无障碍元素快照**；`timeout` 为整次请求的最大等待秒数，必须是大于零的有限数字，默认 10。请求任务 31，返回 ios-mcp 平面响应字典（包含 `elements` 数组）；任务失败或服务不存在时抛 `RuntimeError`。`find_elements(*,text=None,type=None,clickable=None,snapshot=None,timeout=10)` **从任务 31 的平面快照中筛选元素**；`text` 是精确匹配文字、`type` 是精确匹配元素类型、`clickable` 是精确匹配布尔状态，省略 (`None`) 表示不筛；`snapshot` 可传已取得的平面字典或数组，默认重新抓取并使用 `timeout`。若传入 `snapshot`，该参数不参与已有数据的本地筛选。任务 31 与任务 32 是两种不同来源。源：`client.py:494-511,576-581`、`ax.py:43-51`。
- `get_element_tree(timeout=10)`：**读取当前前台 App 的 AX 树和候选元素集合**；`timeout` 为整次请求最大等待秒数，默认 10；请求任务 32，返回 `{pid,count,candidateCount,limitReached,root}` 字典；缺少 `root`、头错误或底层失败抛 `RuntimeError`。`find_tree_elements(*,identifier=None,label=None,value=None,role=None,tree=None,timeout=10)` **按 AX 属性遍历并筛选树节点**；四个筛选项分别对 AX 节点同名字段精确相等，`None` 不筛，`tree` 默认新抓树并使用 `timeout`；传入已有 `tree` 则直接筛选且不使用超时参数；结果是前序遍历节点列表，重复标签保留。源：`client.py:545-574`。
- `get_element_at_point(x,y,timeout=10)`：**命中给定屏幕位置下的 AX 元素**，只查询、不点击。`x,y` 必填 AX **逻辑点**坐标；`timeout` 为整次查询最大等待秒数，默认 10；返回 `{pid,x,y,element}` 字典，底层失败抛 `RuntimeError`。源：`client.py:529-533`。

三种 AX 设备查询共用超时语义：`timeout` 必须为有限正数（单位秒），无效值抛 `ValueError` 且不发送请求；在发送/读取响应头和完整 JSON 数据的整次过程中共用同一截止时间。超时抛 `TimeoutError` 并关闭当前 TCP 连接；下一次查询需新建 `zxtouch("127.0.0.1")` 实例，避免旧设备响应被误认为下一次查询结果。服务端 AX 树内部另有 3 秒单次遍历预算、最多 4 次采集尝试及单条 AX 消息 0.5 秒超时；客户端 `timeout` 限制的是等待设备完整响应的总时长。
- `ocr(region,custom_words=[],minimum_height="",recognition_level=0,languages=[],auto_correct=0,debug_image_path="")`：**使用 iOS Vision 从当前屏幕区域识别文字及位置**。`region` 必填 `(x,y,width,height)` 物理像素；`custom_words` 是提示识别的词语字符串列表，默认空；`minimum_height` 是相对于图像高度的最小文字高度，空串/非正数由 Vision 设为 `1/32`；`recognition_level` 为 0 准确、1 快速；`languages` 为优先级排序的识别语言列表，空列表表示系统默认；`auto_correct` 为 0 不纠错、1 纠错；`debug_image_path` 是设备端调试图输出路径，空串不输出。成功 `(True,[{"text":str,"x":str,"y":str,"width":str,"height":str},...])`，设备失败 `(False,str)`，ROI 数量错误抛 `RuntimeError`。本方法使用 iOS Vision，不调用 PaddleOCR worker。源：`client.py:419-462`、`TextRecognizer.xm:26-105`。
- `get_supported_ocr_languages(recognition_level)`：**查询 iOS Vision 当前识别模式支持的语言列表**。`recognition_level` 必填 0 准确/1 快速，用于查询该模式的可用语言；返回普通 `(bool,list[str]|str)`。源：`client.py:464-482`。

### 5.5 文字、键盘与设备信息

| 方法签名 | 用途及参数与返回值 |
| --- | --- |
| `show_toast(toast_type,content,duration,position=0,fontSize=0)` | **在手机屏幕上显示短暂悬浮文字提示**。`toast_type` 必填 toast 样式编号，`toasttypes.py` 定义 0 隐藏、1 错误、2 警告、3 消息、4 成功；`content` 必填文字；`duration` 必填显示时长；`position` 默认为 0 顶部，1 底部、2 左侧、3 右侧；`fontSize` 默认为 0，使用默认字号。返回普通 tuple。 |
| `show_keyboard()` / `hide_keyboard()` / `paste_from_clipboard()` | **分别弹出软键盘、收起软键盘、将剪贴板文本粘贴到当前输入位置**；均无参数；返回普通 tuple。 |
| `get_text_from_clipboard()` | **读取手机系统剪贴板的文本**；无参数；成功 `(True,字符串)`，失败 `(False,错误字符串)`。定长 JSON 回包保留空文本、换行与 `;;`。 |
| `set_clipboard_text(text)` | **将文本写入手机系统剪贴板**。`text` 必须是字符串（允许空字符串），UTF-8 Base64 编码发送；返回普通 tuple。 |
| `insert_text(text)` | **向当前聚焦的输入框逐字插入文本**；字符 `\b` 会发送删除一个字符。`text` 必填字符串。代码逐字符读取并忽略每次指令的失败回包，最终总是返回 `(True,"")`，所以不能以该返回值确认实际输入完成。源：`client.py:329-345`。 |
| `move_cursor(offset)` | **移动当前文本输入光标**。`offset` 必填相对光标字符位移，负数左移、正数右移；返回普通 tuple。 |
| `get_screen_size()` | **查询设备截图宽、高**；无参数；成功 `(True,{"width":str,"height":str})`，数值字符串单位物理像素。 |
| `get_screen_orientation()` | **查询屏幕当前方向编号**；无参数；成功 `(True,方向数值字符串)`。 |
| `get_screen_scale()` | **读取 iOS 点到像素的屏幕倍率**；无参数；成功 `(True,倍率字符串)`，`float(倍率)` 用于 AX 逻辑点转像素。 |
| `get_foreground_app()` | **读取当前前台 App 的 bundle ID**；无参数。发送设备信息任务 25 的运行状态子任务 32，成功 `(True,"com.apple.Preferences")`，设备错误 `(False,错误字符串)`。SpringBoard 前台或查询不到应用 ID 时设备返回 `com.apple.springboard`；同一响应中的脚本运行/录制状态由此方法忽略。源：`client.py:394-403`、`DeviceInfo.xm:63-72`。 |
| `get_device_info()` | **读取设备名称、系统版本、型号和设备标识信息**；无参数；成功 `(True,{"name":str,"system_name":str,"system_version":str,"model":str,"identifier_for_vendor":str})`。 |
| `get_battery_info()` | **读取充电状态和电量**；无参数；成功 `(True,{"battery_state":str,"battery_level":str,"battery_state_string":str})`；状态值 0 未知、1 未插电、2 充电、3 已满。 |

这些方法来源于 `client.py:220-233,280-417`；设备失败均按普通 Socket tuple 返回。

## 6. Python 自动化辅助（进程内执行）

这些函数直接在调用方 Python 进程运行，不是 HTTP 路由；`automation.find_img_all` 需要该 Python 环境安装 `opencv-python` 和 `numpy`，与设备端原生任务 33 无关。

### AX、颜色

- `locate_elements(tree,*,identifier=None,label=None,value=None,role=None,element_type=None,window_context_id=None)`：**按属性从 AX 树中找出所有符合条件的节点**。`tree` 为任务 32 的整树或 AX 根节点；其余六项分别精确筛选节点的 `identifier`、`label`、`value`、`role`、`elementType`、`windowContextId`；默认 `None` 表示不筛。按前序返回节点列表，保留重名结果。源：`automation.py:20-33`。
- `tap_element(device,*,index=0,tree=None,identifier=None,label=None,value=None,role=None,element_type=None,window_context_id=None,delay=0.05,inset_pixels=2)`：**定位 AX 节点，在其内部选点并发送按下/抬起动作**。`device` 为 `zxtouch` 实例；`index` 是匹配节点的 **0 起始**序号；`tree` 缺省时重新抓 AX 树；六个筛选同 `locate_elements`；`inset_pixels` 默认 2，源码实际在转换屏幕倍率之前应用，是 **AX 逻辑点内缩量**，每轴最多对应宽/高的三分之一；`delay` 默认 0.05，但当前实现没有使用。函数在内缩矩形随机选一个点，不固定点按中心；乘 `get_screen_scale()` 得到物理坐标再触摸，返回 `{x:物理像素浮点数,y:物理像素浮点数,node:原节点}`。节点未命中抛 `LookupError`，无有效 frame 抛 `ValueError`。源：`automation.py:36-65`。
- `find_color(device,rgb,region,tolerance=0)`：**按给定 RGB 和每通道容差扫描设备屏幕区域**。`device` 为 `zxtouch`；`rgb` 是三个 0..255 整数 `[R,G,B]`；`region` 是物理像素 `(x,y,width,height)`；`tolerance` 是每通道允许误差 0..255，默认 0。返回颜色命中的 `{x,y,red,green,blue}`（值为设备返回字符串），无命中/设备失败时返回 `None`；颜色/容差格式错误抛 `ValueError`。源：`automation.py:68-79`。

### OpenCV 灰度/彩色多图

`find_img_all(screen_bytes,templates,*,region=None,similarity=0.8,min_scale=0.5,max_scale=1.5,steps=5,gray=True,max_results=100)`：**在调用方 Python 进程中用 OpenCV 对已取得的图像做多模板、多倍率匹配并返回所有保留的命中**，不触发新的设备截屏。

| 参数 | 说明 |
| --- | --- |
| `screen_bytes` | 必填可解码截图二进制，例如 `device.screenshot()` 的 PNG bytes。 |
| `templates` | 必填调用方文件系统中的图片路径序列；与原生 `match_templates` 的“设备端绝对路径”相区别。 |
| `region` | 可选 `(x,y,width,height)` 物理像素，默认全截图；越界/非正尺寸抛 `ValueError`。 |
| `similarity` | 匹配分数阈值 `(0,1]`，默认 0.8。 |
| `min_scale`, `max_scale` | 模板最小/最大倍率，均须正且最小不大于最大，默认 0.5/1.5。 |
| `steps` | 倍率采样数 1..50，默认 5。 |
| `gray` | 是否将模板和截图转换为灰度，默认 `True`；设 `False` 保持彩色 OpenCV 比较。仅此 Python OpenCV 函数支持此开关。 |
| `max_results` | 最多返回结果 1..1000，默认 100。 |

结果按 `score` 降序，列表项 `{index:从0起模板序号,score:五位小数,x:像素,y:像素,w:像素,h:像素}`；重叠程度达到较小框面积 50% 时去重，未命中返回 `[]`。参数/图片无效 `ValueError`，缺依赖 `ImportError`，读取模板失败 `OSError`。`find_img_best(screen_bytes,templates,**options)` **只取上述匹配结果中分数最高的一项**，复用上述所有同名可选参数，但强制 `max_results=1`，返回首项或 `None`；不要在 `options` 再传 `max_results`。`find_screen_images(device,templates,**options)` **从设备截图后在调用方进行 OpenCV 找图**；先调用 `device.screenshot()` 一次，再把同名选项传给 `find_img_all`，返回同样的列表。源：`automation.py:82-160`。

```python
from zxtouch.client import zxtouch
from zxtouch.automation import find_img_all

phone = zxtouch("127.0.0.1")
try:
    matches = find_img_all(phone.screenshot(),
                           ["/var/mobile/Library/ZXTouch/templates/button.png"],
                           region=(0, 0, 750, 1334), similarity=0.9,
                           min_scale=1, max_scale=1, steps=1, gray=True)
    print(matches)
finally:
    phone.disconnect()
```

### 批量横向扫描 `scan_batch`

`scan_batch(device,*,short_templates,container,region,claim_template,close_template,target_app,entry_template=None,entry_region=None,entry_verify_template=None,entry_verify_region=None,long_templates=(),edge_x=None,edge_tolerance=20,threshold=0.92,step=180,swipe_y=None,swipe_duration=0.28,pause=0.45,max_segments=60,scan_timeout=45,max_hits=5,dedupe_pixels=12,short_dwell=17,long_dwell=62,app_timeout=8,verify_timeout=6,verify_interval=0.2,claim_region=None,close_region=None,clock=time.monotonic,sleep=time.sleep)`。

**用途**：按短任务、长任务优先顺序横向遍历任务容器；找到任务后点击、等待、回切目标 App、横向寻找领取按钮、点击关闭并验证图像消失。函数内部使用任务 33 找图、任务 32 AX 树和触摸指令，不需要浏览器。返回状态码用于区分完整遍历、超时及各个验证步骤失败。

| 参数 | 说明 |
| --- | --- |
| `device` | 必填，已连接的 `zxtouch` 实例。 |
| `short_templates`、`long_templates` | 前者必填，后者默认空 tuple；设备端短/长任务 PNG 绝对路径列表，至少一组非空，每组最多 12 张；先扫短任务。 |
| `container` | 必填 callable，接收 `device.get_element_tree()` 的整棵树，返回含 AX 逻辑点 `frame` 的横向容器节点。 |
| `region` | 必填 `(x,y,width,height)` 扫描及滑动范围，物理像素，宽高正数。 |
| `claim_template`、`close_template` | 必填设备端 PNG 路径，分别为领取按钮、关闭按钮模板。 |
| `target_app` | 必填要回切到的应用 bundle ID。 |
| `entry_template` | 可选入口按钮 PNG 路径，默认 `None` 跳过入口步骤。 |
| `entry_region` | 可选入口按钮查找 ROI；默认 `None` 全屏。 |
| `entry_verify_template` | 可选入口点击后验证出现的 PNG；默认 `None` 不验证。 |
| `entry_verify_region` | 可选入口验证 ROI；默认全屏。 |
| `edge_x` | 可选 `(左边界,右边界)`，容器 `frame.x` 转换后的物理像素边缘阈值；默认 `None` 依靠容器 X 停滞判断。 |
| `edge_tolerance` | 默认 20，传递给内部扫描边界逻辑；领取回扫分支当前接收该值但不使用。 |
| `threshold` | 默认 0.92，设备原生任务 33 的找图阈值。 |
| `step` | 默认 180，横向每次滑动的物理像素距离。 |
| `swipe_y` | 可选滑动 Y 物理像素；默认容器 AX frame 垂直中点乘屏幕倍率。 |
| `swipe_duration`、`pause` | 默认 0.28 秒、0.45 秒；每次滑动耗时、滑后等待。 |
| `max_segments` | 默认 60，每轮最多扫描的滑动段数；领取回扫最多迭代 `max_segments+1` 次。 |
| `scan_timeout` | 默认 45 秒；每批扫描、领取按钮回扫分别使用的超时。 |
| `max_hits` | 默认 5；最多处理的任务命中次数。 |
| `dedupe_pixels` | 默认 12 物理像素；按模板 `index` 和容器相对 X 距离去重。 |
| `short_dwell`、`long_dwell` | 默认 17、62 秒；点击短/长任务后等待时长。 |
| `app_timeout` | 默认 8 秒；回切 `target_app` 调用的耗时上限。 |
| `verify_timeout`、`verify_interval` | 默认 6、0.2 秒；等待入口/关闭图出现或消失的超时、轮询间隔。 |
| `claim_region`、`close_region` | 领取/关闭按钮找图 ROI；默认 `None` 全屏。 |
| `clock`、`sleep` | 默认 `time.monotonic`、`time.sleep`；分别提供秒单位单调时钟与秒单位睡眠函数。 |

返回字典至少含 `status`（状态字符串）、`count`（已点击任务个数）；`status` 可为 `entry_not_found`、`entry_verify_failed`、`scan_timeout`、`app_switch_failed`（另含 `detail`：回切失败的原始详情）、`claim_not_found`、`close_not_found`、`close_verify_failed`、`complete`、`hit_limit`。空模板/每组超过 12 张/非法区域抛 `ValueError`；容器缺失抛 `LookupError`；屏幕倍率查询失败抛 `RuntimeError`；底层 socket、模板查询及回调函数的其他异常直接传播。源：`batch_scan.py:11-214`。

## 7. 调用与值类型速查

| 场景 | 输入坐标 | 返回坐标 | 是否灰度 | 资源位置 |
| --- | --- | --- | --- | --- |
| HTTP `/api/ax/point` / `/api/ax/tap` | 逻辑点 | AX frame 逻辑点 | 不适用 | 手机 AX。 |
| HTTP `/api/color/*`、`/api/image/matches`、`/api/ocr` | 截图物理像素 | 截图物理像素；旧文本接口坐标为 string | 原生多图 RGB | 手机独立模板目录或 `.bdl` 包。 |
| Python `match_templates()` | 截图物理像素 | 截图物理像素 number | 原生 RGB | 手机 PNG 绝对路径。 |
| Python `find_img_all(gray=True)` | 截图物理像素 | 截图物理像素 int | 默认灰度，可选彩色 | Python 运行进程可读取的图片路径。 |
| Python `tap_element()` | AX frame 逻辑点 | 返回触摸物理像素 | 不适用 | 手机 AX。 |

旧 README 中对任务 30 的 JPEG 表述和对 AX 树“完全递归 AXChildren”的表述与现行代码不一致；以本文所列的 PNG 响应及混合候选树结构为准。接口与示例按照源码核对；设备端效果取决于已安装的构建版本。
