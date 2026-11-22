# IOS-SFP iOS ARM64 OCR runtime

This directory is the complete `runtime/ios/` install tree from [ssoftwarepp/ios-mcp Actions run 45048102079](https://github.com/ssoftwarepp/ios-mcp/actions/runs/45048102079), commit `7f3611da20edacbbe7c71bcac7f692a5ba6a0ed7`. It contains matching ONNX Runtime 1.20.1 and OpenCV 4.10.0 static libraries, headers and installed OpenCV resources. All 205 source files were checked after copying. `ocrworker/Makefile` uses this directory as `PADDLE_DEPS`.

| Relative path | Bytes | SHA256 |
| --- | ---: | --- |
| `lib/libonnxruntime.a` | 24,350,216 | `6d208c91a87c32d88f00b3b0b24598e3e3593f21b5ef6764f1550ef3f310b5bb` |
| `opencv/lib/libopencv_core.a` | 3,728,136 | `23cf0b4fa662f341f9300df1d88c9da2dc20f786d442fa5607ed071dde4ae095` |
| `opencv/lib/libopencv_imgproc.a` | 4,165,624 | `c79b666f813ad3fee10ebcae98b7016079098814645304881c450fb942bebf54` |

The ORT headers are under `include/` and the OpenCV install headers under `opencv/include/opencv4/opencv2/`. The complete original Artifact is at `D:\github_project\ios-mcp\artifacts\ios-mcp-paddleocr-complete-build-7f3611da20edacbbe7c71bcac7f692a5ba6a0ed7.zip` (SHA256 `26dce86117ec0c0fac2177ece71192aaf563e2f2ffabef0076a98d61a5bff159`). The full ONNX Runtime and OpenCV build trees and the runtime tarball, not just selected libraries, are retained in `D:\github_project\ios-mcp\artifacts\complete-build-7f3611d`. Models are stored separately under `third_party/paddleocr/models/`; see the repository root [README](../../../../README.md) for their hashes and validation status.
