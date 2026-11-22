# 2026-11-23 OCR / AX / image workbench change log

## OCR worker

- `pccontrol/PaddleOCRBridge.m`: keep one worker PID and a bidirectional socket across requests; serialize with the existing bridge lock. Spawn on first request; reset after transport/invalid JSON failure and restart on the next request. Successful requests reuse the loaded detection/recognition sessions.
- `ocrworker/main.mm`: wait indefinitely for the next framed request instead of ending the worker after 60 idle seconds. The worker retains its 512 MiB footprint guard (`_exit(75)`).
- Transport failures now include stage-specific codes: `OCR_SEND_HEADER_{TIMEOUT,CLOSED,IO}`, `OCR_SEND_BODY_{TIMEOUT,CLOSED,IO}`, `OCR_RECV_HEADER_{TIMEOUT,CLOSED,IO}`, `OCR_RECV_BODY_{TIMEOUT,CLOSED,IO}`, `OCR_HEADER_INVALID_IO`, `OCR_RESPONSE_INVALID`, `OCR_SPAWN_IO`, `OCR_SOCKETPAIR_IO`, `OCR_DUPFD_IO`. The error includes PID, process exit/signal when observed, and errno. Worker start and failure are appended to the existing ZXTouch runtime output (`/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output`); `/api/ocr` success includes `worker_pid` for repeated-call comparison.
- A received `exit=75` indicates the worker's own 512 MiB guard. `TIMEOUT` denotes the bridge's 30-second request deadline; `CLOSED` indicates a disconnected socket. If the child is still `running` when inspected, the failure message reflects that instant, not a post-mortem diagnosis.

## AX element hierarchy

- `pccontrol/AccessibilityTree.xm`: traverse actual `AXChildren` recursively when available; use CFHash+CFEqual identity deduplication and bounded depth (16), node count (2002 including the application, excluding the synthetic group), and capture budget (~3 seconds, subject to individual AX calls). Add available role/subrole/hint/description/title/enabled/focused/label fields, source and snapshot path.
- Windows and numeric candidates are discovery results, not proven AX parent-child links. They are grouped under an explicitly synthetic `AXCandidateGroup` in `root.children` to remain accessible to existing clients. `candidateSourcePath`, `candidateAttribute`, `candidateIndex`, `snapshotPath` and frame distinguish the two example elements `3015:157` and `3015:162` with identical labels. Paths identify items within one snapshot; no cross-snapshot persistent AX identity is claimed.
- `zxtouch/zxtouch/http/index.html`: AX screenshot stays in the left pane; the right pane has independently scrolling tree above selected-node attributes. Selecting a box or row highlights that exact row and scrolls it into view. Image/color tools now have a fixed left screenshot pane and separately scrolling right controls.

## Template image / alpha mask

- The standalone image chooser accepts one PNG; the separate mask input was removed. `pccontrol/MaskedTemplateMatch.mm` already uses the template's alpha channel when no separate mask is supplied: alpha 255 participates, alpha 0 is excluded. This session changed the UI caller to send no mask entry; native support for external-mask clients remains intact.
- Upload-and-match now displays match count and every returned `(x,y)`/width/height/score, shows found/not-found in the toast, and draws match rectangles on the screenshot. Refreshing the screenshot clears old match overlays. Native task 33 caps returned results at the request limit (UI requests 30), so displayed results are the returned matches, not all possible locations.

## Validation

- `python -m unittest discover -s tests -q`: 54 tests passed on Windows.
- Node `vm.Script` parsing of the dashboard inline JavaScript: passed.
- `git diff --check`: passed. No iOS build, package or device installation was performed for these edits. Device-side AX property availability, warm worker PID reuse, response timing, and template PNG alpha matching remain to be checked on the installed version.

Experience lookup receipts: global `q-e354d2a7570d`, local `q-a2ac572fc03f`; this work preserved existing unrelated working-tree modifications.

## Device follow-up: 05:28–05:38 Asia/Shanghai

- Direct authenticated HTTP tests at the supplied device address (token omitted from logs): `/api/status` reported `foregroundApp=com.apple.springboard`, 750×1334 physical pixels, scale 2. `/api/ax/tree` succeeded but the game-page `次神：光之觉醒` nodes were not present because SpringBoard was foreground. Real in-game semantic properties for candidates `3015:178` and `3015:179` are therefore not yet observed.
- `/api/ocr` succeeded for both engines on the SpringBoard screenshot: full frame `[0,0,750,1334]` returned 4 Vision and 42 PaddleOCR text items; the 100×100 region `[200,400,100,100]` returned one text item from each. Repeated PaddleOCR requests returned the same PID (48427); runtime log recorded the worker start and no failure. This confirms device OCR APIs operate for the tested page, not that OCR on the game screen or browser interaction has been verified.
- Used the live PNG screenshot to upload a cropped image and call `/api/image/matches`: the native matcher returned results for the full frame, including an exact score-1 hit at `(250,586)` for a crop originally taken at `(250,700)`; a restricted rectangle around the original crop returned zero. The frame changed between capture and matching, so missing a match within an outdated ROI is expected. This directly motivated a dedicated find-image region rather than reusing the crop/OCR region. The test uploaded `device-crop-probe.png` into the device's standalone template directory.
- Source changes after the successful private build: AX `WebAccessibilityObjectWrapper` nodes now optionally expose returned `AXRoleDescription`, `AXDOMIdentifier`, `AXURL`, `AXPlaceholderValue`; the dashboard tree title displays candidate index, size and position directly. The image workbench has a separate find-image rectangle (drag mode and numeric X/Y/width/height, full-screen reset); OCR results show engine, count, worker PID and persistent errors directly below the OCR button. The existing device build does not contain these latest edits.
- Local validation: 55 Python tests passed; dashboard inline JavaScript parses with Node `vm.Script`; changed-file diff whitespace check passed. No build or device installation was performed for this follow-up.
- Experience lookup receipts: global `q-e70d471646c7`, local `q-e67753fba8d2`.

## Game-screen follow-up: 06:06 Asia/Shanghai

- Device `/` serves the updated dashboard with the dedicated search region. The current foreground app is `com.yy.kiwi`. Direct game-screen OCR: Vision returns two full-screen texts, PaddleOCR 39; both return zero inside `[200,400,100,100]`, confirming a zero-hit ROI need not indicate an API failure.
- Reproduced game-screen template drift: a 48×48 crop from `(250,700)` matched on a subsequent live capture around `(249,583)` at 0.858, while the old tight region `[240,690,68,68]` returned zero. The dashboard now uploads its displayed screenshot as a PNG for optional same-frame matching via the existing native task 33, defaulting to that frame; live matching remains selectable and remains the default for existing script clients.
- Fixed a dashboard AX render `ReferenceError`: `f` is now declared before its first interpolation. OCR progress/error/zero-result state remains in the result pane, with the selected region shown for zero hits.
- Local validation: 55 Python tests, Node `vm.Script`, and changed-file diff whitespace checks pass. This follow-up is source-only until built and installed.
- Experience lookup receipts: global `q-e9bcf570a9df`, local `q-449d54098677` (no matches).

## Degenerate OCR box: 06:16 Asia/Shanghai

- A game-screen request produced `OCR_RESPONSE_INVALID: PaddleOCR: invalid detected text crop`. Detection clamps each quad corner to screenshot boundaries; a pathological contour may collapse to zero width or height. Filter degenerate/nonfinite boxes before recognition and skip empty crop results instead of aborting the full page.
- Source-oriented regression asserts all three guards. Local Python tests: 56 passed; inline dashboard JS syntax and changed-file whitespace checks pass. Worker fix takes effect only after installing a newly built package.

## Match coordinate and OCR visibility: 06:27 Asia/Shanghai

- Captured a 750×1334 screenshot and cropped a 48×48 template at `(250,700)`. Searching the *same* uploaded PNG still returned `(249,584)` at threshold 0.85; `1334 - 700 - 48 = 586` exposes a vertical mirror, not a scale mismatch or motion between frames. Removed the extra CGContext Y flip in `zxRGBA` so screenshot/template search and returned coordinates share the displayed top-left-origin convention. Before rebuilding the native matcher, this fix cannot be validated by the device API; the device still runs the preceding build.
- The installed game-screen `/api/ocr` responded successfully to direct requests: Vision full-screen 4 and small ROI 1; PaddleOCR full-screen 55 and small ROI 0. This does not establish that the browser click visibly rendered a result. The dashboard now mirrors OCR progress, count and errors into a visible panel-header status while keeping detailed text in the scrollable list. Added zero-result/error UI assertions and RGBA orientation source assertions.
- 56 local Python tests, Node `vm.Script` parsing and changed-file whitespace checks pass. No commit, push or build in this follow-up. Experience receipts: `q-aef7cb164c16`, `q-32bbb3912113` (no matches).
