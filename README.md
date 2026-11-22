# IOS-SFP

IOS-SFP 是独立维护的 ZXTouch iOS rootless/roothide 中文分支：在触摸控制与脚本执行基础上增加设备端 AX 查询、图色工具和中文远程控制台。安装、兼容系统、Python API 和历史真机记录见 [README_old.md](README_old.md)。以下区分“源码已有功能”“真机已验证部分”和“尚未完成的 PaddleOCR 集成”，不把依赖文件已落盘等同于可安装功能。

## 项目已实现的功能

- **触摸和自动化**：Socket 6000 与 Python `zxtouch` 客户端提供点击/滑动、多点触控、切换应用、输入文字、弹框、取色/找色、运行和停止脚本、录制与回放；音量键面板、脚本浏览、录制编辑器和按键模式触发配置沿用现有 ZXTouch 分支。详见 [功能与 Python API](README_old.md)。
- **屏幕和图像**：任务 30 输出内存中的无损 PNG；原有 `image_match` 使用设备端 Accelerate，任务 33 的原生模板匹配增加多个模板、ROI、多尺度、多结果和可选 PNG 掩模。Python `zxtouch.automation` 的多图匹配另在调用方环境使用 `opencv-python`/`numpy`；此处与 iOS OCR worker 所用的 OpenCV 静态库是两套不同依赖。
- **无障碍元素**：任务 32 从前台应用或 SpringBoard 取得 AX 应用、窗口和候选元素树，返回标签、标识符、frame 等信息，并标记候选上限；任务 34 按屏幕逻辑坐标命中 AX 元素。任务 31 的扁平元素查询则需要手机上另行运行 ios-mcp 服务，不属于任务 32 的依赖。iOS 15.8.8 上已有任务 32 的桌面与设置页真机记录，见 [实测说明](README_old.md)。
- **中文远程控制台**：提供脚本编辑、截图、图色、元素树、AX 框叠加与点击、定位代码/标注图导出。`POST /api/ocr` 可显式选择 `engine: "vision"`（原任务 27）或 `engine: "paddleocr"`（PNG 截图通过独立 worker 运行 ONNX Runtime/OpenCV CPU 推理）；请求使用配对令牌。相关源码见 [控制台路由](zxtouch/zxtouch/DashboardTools.inc)和 [图像/OCR 路由](zxtouch/zxtouch/AdvancedTools.inc)。
- **PaddleOCR worker 代码与资源**：仓库含独立 `ocrworker` 的检测/识别推理源码、ONNX Runtime 1.20.1 与 OpenCV 4.10.0 的 iOS arm64 安装树、头文件、静态库、两份 PP-OCRv5 ONNX 模型、字典和配置文件；目录和校验信息见下文。顶层 [Makefile](Makefile) 检测到 ONNX Runtime 头文件后会加入 `ocrworker` 子项目。

## 尚未实现或验证的部分

- **IOS-SFP 的 PaddleOCR 端到端验收尚未完成**：已接入控制台引擎选择、worker IPC 与资源打包规则；本仓库尚无成功的 iOS 编译、签名、真实 `.deb` 内容检查、设备安装与 OCR 真机记录。参考项目 ios-mcp 的 worker 编译/单测通过不等于本项目通过。
- **模型部署已有构建规则，仍待安装包核验**：顶层 Makefile 的 `after-stage` 将 `det.onnx`、`rec.onnx`、`dictionary.json` 与 `sha256.json` 复制到 `/usr/share/zxtouch/paddleocr/`，worker 由子项目安装到 `/usr/libexec/zxtouch/`。当前 Windows 环境没有 Theos/Xcode，未产出 IOS-SFP `.deb`。
- **新改版的完整设备验收尚未完成**：iOS 15.8.8 上的 AX 查询与桌面触摸有历史实测；改版控制台的图色/元素工具、任务 33/34 和新 OCR worker 仍需用包含当前改动的 IOS-SFP 安装包验证。任务 32 是 AX 候选集合构成的树，不是完整递归 `AXChildren`/XPath 快照。

## 目前进度

1. 已从 ios-mcp 云端运行下载并核验完整 ONNX Runtime/OpenCV 构建归档；把同次运行的完整 iOS runtime 安装树（205 个文件）同步至本仓库，三个 `.a` 与头文件成套匹配。
2. 已直接下载 `det.onnx` 与 `rec.onnx`；模型、配置和字典五个资源均通过 `sha256.json` 校验。
3. [ios-mcp 构建运行](https://github.com/ssoftwarepp/ios-mcp/actions/runs/45048102079) 的依赖编译与上传成功，但该项目后续 Rootless `.deb` 步骤失败；该运行没有完整 ios-mcp DEB。
4. IOS-SFP 已修正 worker 的 Clipper 路径与包标识，加入模型 `after-stage` 复制和 SpringBoard OCR IPC 桥接；控制台可选择 Vision 或 PaddleOCR。CI 已在 Rootless/Roothide 两种包上传前核对 worker 的 arm64 Mach-O 可执行头、iOS 平台标记、执行位与模型摘要。尚需在 Theos/macOS 上构建本仓库 `.deb` 并检查实际包内容及真机结果；当前未提交或推送。
5. 根据 `D:\codex_data\ajjl\hy\脚本.txt` 最终覆盖的 `FLOW`，实际入口只有 `click_zgd → scan_more`。新增 [横向批量扫描 helper](layout/usr/share/zxtouch/python/zxtouch/batch_scan.py)，组合已有模板匹配、AX 容器定位、分段横扫、按模板索引与容器相对 X 去重、回切、横向查找领取入口和关闭后消失验证。`app_timeout=8` 限制应用回切调用，`scan_timeout=45` 单独限制每批任务扫描和领取入口横扫；调用时使用实际存在的设备端 PNG 路径；MQ 的 `Attachment:` URI 与深层 XPath 不直接兼容，仓库与给定脚本目录均未找到原脚本引用的 `ys_g.png`。

## 构建后检查

在 macOS/Theos 环境执行 `make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1`，再运行 `python3 ocrworker/verify_package.py packages/实际生成的文件.deb` 检查 worker 的 arm64 Mach-O 可执行头、iOS 平台标记与执行位、四份运行资源及包内 SHA256。源码单测可运行 `python3 -m unittest discover -s tests -q`；此命令不替代真实安装包和设备 OCR 验证。

## 已取得的完整编译产物

来源：[ios-mcp Actions run 45048102079](https://github.com/ssoftwarepp/ios-mcp/actions/runs/45048102079)，提交 `7f3611da20edacbbe7c71bcac7f692a5ba6a0ed7`，macOS 15 / Xcode 16.4，iOS arm64。ONNX Runtime 1.20.1、OpenCV 4.10.0 编译成功，编译目录和安装树上传成功。整场运行随后在 Rootless `.deb` 打包步骤失败；**这不影响已上传的编译产物，但该运行没有完整 DEB**。

完整 Artifact ID `14764354086`，原始 ZIP：`D:\github_project\ios-mcp\artifacts\ios-mcp-paddleocr-complete-build-7f3611da20edacbbe7c71bcac7f692a5ba6a0ed7.zip`；171,829,574 字节，SHA256 `26dce86117ec0c0fac2177ece71192aaf563e2f2ffabef0076a98d61a5bff159`（与 GitHub Artifact digest 一致）。解包目录：`D:\github_project\ios-mcp\artifacts\complete-build-7f3611d`。三份内层 tar 和 `SHA256SUMS` 均保留并已逐项核对：

| 归档 | SHA256 | 内容 |
| --- | --- | --- |
| `onnxruntime-ios-build.tar.gz` | `7a2cfcd9957d894a8f0569e5680837cf00e3a77bb4d77fb0dbc7c0d68bfbc47d` | 完整 `ort-ios/` 构建树 |
| `opencv-ios-build.tar.gz` | `8b12d3ee8adbcb4ea545470efb914e96a5659f64dc5ef893ac96f16755d60bf3` | 完整 `cv-ios/` 构建树 |
| `runtime-ios.tar.gz` | `32f63d2e2845885f99c2de57699cd32bd3f17d0d6397371eb3774af7f8251fb2` | 安装树 `runtime/ios/`：静态库、ONNX Runtime 头文件、完整 OpenCV 安装头文件和其他安装产物 |

原始 tar 完整保留，含 macOS runner 的构建路径和符号链接。Windows 解包目录将指向文件的链接实体化，7 个指向目录的链接记录在 `directory-symlinks.json`；原始 tar 是精确保存的编译输出。CMake/Xcode 构建树中的路径仍是 runner 路径，不等同于在本机直接可重新编译的工程。

## IOS-SFP 中的运行时文件

已将**同一次运行**的 `runtime/ios/` 安装树逐文件复制到 `third_party/paddleocr/runtime/ios/`，覆盖先前运行生成的三个 `.a`，使头文件和库版本匹配；205 个文件在复制后与提取的安装树逐一核对。构建链接由 [ocrworker/Makefile](ocrworker/Makefile) 指向这里。

| 文件（相对仓库根目录） | 字节 | SHA256 |
| --- | ---: | --- |
| [`third_party/paddleocr/runtime/ios/lib/libonnxruntime.a`](third_party/paddleocr/runtime/ios/lib/libonnxruntime.a) | 24,350,216 | `6d208c91a87c32d88f00b3b0b24598e3e3593f21b5ef6764f1550ef3f310b5bb` |
| [`third_party/paddleocr/runtime/ios/opencv/lib/libopencv_core.a`](third_party/paddleocr/runtime/ios/opencv/lib/libopencv_core.a) | 3,728,136 | `23cf0b4fa662f341f9300df1d88c9da2dc20f786d442fa5607ed071dde4ae095` |
| [`third_party/paddleocr/runtime/ios/opencv/lib/libopencv_imgproc.a`](third_party/paddleocr/runtime/ios/opencv/lib/libopencv_imgproc.a) | 4,165,624 | `c79b666f813ad3fee10ebcae98b7016079098814645304881c450fb942bebf54` |

ONNX Runtime 头文件位于 `third_party/paddleocr/runtime/ios/include/`（含 `onnxruntime_cxx_api.h`）；OpenCV 的完整安装头文件树位于 `third_party/paddleocr/runtime/ios/opencv/include/opencv4/opencv2/`（含 `core.hpp` 和 `imgproc.hpp`）。顶层 [Makefile](Makefile) 以 `onnxruntime_cxx_api.h` 是否存在决定是否将 `ocrworker` 纳入构建；现在这个条件已满足。

## 模型资源与验证状态

`third_party/paddleocr/models/det.onnx`（4,826,518 字节，SHA256 `a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d`）和 `rec.onnx`（16,534,782 字节，SHA256 `da72dc72ca4dc220df0dfde68c1dedc31c58d3e76a25871122e5056227d50092`）已按 [ios-mcp 依赖锁](https://github.com/ssoftwarepp/ios-mcp/blob/7f3611da20edacbbe7c71bcac7f692a5ba6a0ed7/third_party/paddleocr/dependencies.lock.json) 直接下载并核对。`det.yml`、`rec.yml`、`dictionary.json` 已有，恢复为源文件 LF 换行后，模型目录的五个资源全部匹配 `sha256.json`；`ocrworker/models/` 中对应三个配置文件也已恢复 LF。原始静态库 ZIP 仍保留在 ios-mcp 的 `artifacts/` 目录，本仓库使用的是最新运行的整套 runtime，不再使用旧 ZIP 中的三份 `.a`。

**尚未验证 IOS-SFP 本仓库 worker 的实际编译、安装及真机 OCR**；参考项目的 worker 编译与单测通过并不等于 IOS-SFP 构建通过。没有为 IOS-SFP 提交或推送上述资源。
