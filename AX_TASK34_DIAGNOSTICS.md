# Task34 AX point direct-hit diagnostics — build preparation

Marker: `AXPOINT-20261128-03/task34/v4`. Source baseline commit `5712cdbe447c91b1edcf340aee4054e396111882`; rootless/roothide package version is `1.0.2-sfp13-axpoint20261128`. This identifies the prepared build inputs; neither a completed package build nor a target-device repair is claimed.

## Foreground PID repair (2026-11-28)

Task34 now follows the existing tree PID fallback: focused PID, foreground application PID, foreground `processState` PID, then SpringBoard self PID only when the foreground object is absent or identifies `com.apple.springboard`. Every selected PID passes the existing live-process check. This repairs the missing processState branch that could report 3405 while tree capture succeeded. Desktop fallback, direct native hit testing, deadlines and ownership are preserved. Device validation remains pending.

## Invalid application-root hit recovery (v3)

Device v2 evidence: PID 42117, application root creation nonnull, direct hit status -25202 after 124ms. PID repair is effective; direct hit remains failed. v3 preserves the same direct function and float ABI. Only when application direct hit returns -25202, and AXUIElementCreateSystemWide is exported by the selected runtime, v3 creates a system-wide root and performs one direct native hit with the same point. No WithParams cast, traversal, frame containment or fabricated element is used. Both attempts share the original deadline. Failed nonnull outputs, application root and system root are released. Diagnostics contain applicationHitStatus, systemHitStatus, systemRootSymbol, systemRootAvailable, systemRootTried and hitRoot. Missing optional symbol or null system root leaves the original error intact. System-wide hits can identify overlays from other processes; the top-level pid continues to identify the selected foreground process, not a verified hit-owner PID. Root fallback is an implementation candidate, not a claimed target-device repair.

## WithParams native hit investigation (v4)

Device v3 evidence: pid 43868, app direct -25202 and system-wide direct -25202, selected AXRuntime; both roots existed and completed in 64ms. v4 preserves the app direct path. On app direct -25202 it resolves the optional AXRuntime `AXUIElementCopyElementAtPositionWithParams` symbol from the same image. It calls system-wide WithParams(root, out, 1, x, y) when its root exists, then application WithParams(root, out, 1, x, y) if the preceding attempt failed or returned no element. Failed nonnull outputs are released before another call. Each call checks the same deadline and sets messaging timeout based on remaining budget. Diagnostics report per-root WithParams status, availability, tried flags and hit mode. The actual mobile ABI and target-device success remain unverified; native fixture tests cover only synthetic calls.

## Exact native operation

Task34 alone resolves `AXUIElementCreateApplication`, falling back to `_AXUIElementCreateAppElementWithPid` when absent, and calls exact `AXUIElementCopyElementAtPosition(application, &element, (float)x, (float)y)`. AXRuntime and the two known Accessibility image paths are the only AX candidates. FrontBoard image is a separate PID helper. The optional WithParams entry has a separate typed function pointer and flags=1; no traversal or frame-containment substitute is used. iOS SDK stub / sibling mobile source support the candidate; target-device export and typed mobile call remain WAITING.

`PointCapture.inc` has a private runtime table, one process-lifetime pin per successfully opened image (maximum four), and no request-path `dlclose`. `RTLD_DEFAULT` is not used. No Task34 write to the legacy `zx*` function table. The actual selected create/image and raw signed hit AX status are included in bounded diagnostics. Main-queue capture owns the application, returned hit element, and each CopyAttributeValue output in separate `@finally`/per-attribute release; a nonzero hit status with a nonnull element still releases the element. No AXChildren enumeration is involved.

## Deadline and ownership

The point request uses continuous `mach_continuous_time` converted to monotonic nanoseconds: `Dq=T0+750ms`, work cutoff `Dw=T0+2750ms`, response decision `D=T0+3000ms`. Created/setup/Queued never reaching Running before Dq report 3411, even if D timer is scheduled first. Once Running, expiry reports 3412. Each remote AX request gets `min(500ms, remaining-to-Dw - 20ms)` after confirming remaining exceeds 25ms; completion cannot claim success after D. The fixed budget includes first loader initialization and main-queue delay. Synchronous main-thread callers get 3415 rather than a main-thread wait. One nonblocking permit permits at most one live/waiting/late Task34 operation; other requests get 3414. Timers and blocks hold or briefly strongify the heap context, never caller stack or socket. The caller is the only wire owner; on timeout a native call already in progress is not canceled. The last setup/main/completion block to exit releases the permit, never the timer/caller.

## Wire format

Success: `0;;application/json;;<UTF-8 byte length>\r\n` followed by at most 65536 bytes of JSON containing `pid`, `x`, `y`, real `element`, marker and diagnostics. Failure: one `-1;;<bounded localizedDescription>\r\n` line; diagnostics JSON at most 32768 UTF-8 bytes, full error header at most 65536 bytes, fallback static code 3417 line on malformed framing or invalid bytes. Diagnostic strings are bounded and semicolons, CR/LF, U+2028/U+2029 are escaped; the Python point-specific reader measures the first CRLF line (not any following buffered packet), retains the next packet after a normal error, and closes the connection for oversize/malformed framing. Other tasks retain existing helper defaults.

## Codes

`3400` point validation; `3401` runtime load; `3402` create resolution; `3403` direct hit resolution; `3404` copy resolution; `3405` foreground PID; `3406` application creation; `3407` raw native hit status; `3408` hit returned null; `3409` leaf construction; `3410` JSON encoding; `3411` pre-Running queue deadline; `3412` Running deadline; `3413` AX messaging timeout setup; `3414` busy; `3415` main-thread caller; `3416` Objective-C exception; `3417` protocol/size; `0` success.

## Verification boundaries

The complete Python regression suite passed: `python -B -m unittest discover -s tests -v`, 125 tests in 1.608 seconds, exit 0 / OK (CP2-C rerun; Task34 point protocol/source-contract cases included). These results cover the tested source snapshot; Python mocks and source assertions do not execute mobile AX or establish its ABI.

The prepared macOS workflow runs the existing Python suite, then compiles and executes `tests/native/task34_leaf.mm` and `tests/native/task34_deadline.mm` with clang++ C++17, ARC, blocks, Foundation and CoreGraphics. The leaf fixture exercises the production leaf builder and bounded JSON fallback; the deadline fixture exercises shared deadline arithmetic. They are synthetic fixtures, not live mobile AX calls, and are not yet executed in this preparation checkpoint. iOS arm64/arm64e compilation and both package variants also remain pending until the build runs.

Target-device export availability, selected-entry typed mobile ABI, actual foreground/SpringBoard direct-hit results, runtime ownership and deadline behavior remain WAITING for real-device evidence. No device was installed or called in this checkpoint. README.md/readme.md collide by case in this Windows checkout; neither is edited or included in the 12-file upload whitelist. Existing dictionary content, external helpers and local evidence/log files are also excluded. The build helper uploads only those 12 UTF-8 text paths with LF line endings onto the exact diagnostic parent tree, preserving every other legacy entry byte-for-byte. Build artifact metadata will be verified without downloading artifact archives; the user downloads the packages.
