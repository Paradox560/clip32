# Efficiency and security assessment — 2026-11-07

Three parallel reviews covered clipboard capture/storage, runtime/UI efficiency, and security. The app has a small native foundation, but large histories still expose storage and search bottlenecks. Five bounded fixes are prepared locally; this assessment does not establish that the app is free of security vulnerabilities.

## Scope and environment

- Baseline: `6fd3ebee95d32800969a6a0762e812b54615ab29`, version 1.1.1.
- Changes: local branch `codex/efficiency-security-audit`; not installed, committed, pushed, or released during this assessment.
- Host: Apple silicon, macOS 14.3, Apple Swift 5.9.2. Optimized builds compiled for both arm64 and x86_64.
- Reviewed source, dependencies, build/install/DMG scripts, and process counters. Tests used temporary directories, synthetic data, named pasteboards, and mocked paste events. The user's clipboard contents and saved history were not read.
- This was a source review and targeted measurement exercise, not a penetration test or a controlled long-duration energy test.

## Measurements

| Measurement | Result | Interpretation |
| --- | --- | --- |
| Existing universal app bundle | About 3.6 MiB | Small native package; no third-party package dependencies or bundled web runtime |
| Existing process physical footprint | About 79 MB | Short observation of the installed baseline, with history size and window visibility uncontrolled |
| Existing process CPU | 1.7–3.2% across five two-second samples | Not a clean idle benchmark; no before/after CPU reduction is claimed |
| Main-thread stack sample | 241 of 253 samples waiting in the run loop | Most sampled time was waiting; some SwiftUI layout/display activity appeared |
| 2 MiB single-line title generation | 137.36 ms → 0.014 ms | Same release-optimized synthetic fixture before/after the display fix |
| 256 KiB single-line title generation | 17.20 ms → 0.023 ms | Display work no longer scales with the entire plain-text payload |

The process sample reported a lifetime peak footprint of about 525 MB with an unknown preceding workload. This does not establish a leak. The 512 MiB history limit bounds retained payload, not process memory: decoding, encoding, snapshots, and image handling require additional memory. Explicit autorelease pools did not materially improve the smaller synthetic storage cases tested.

## Fixes prepared

1. **Bound display-text work.** Titles previously split complete multi-megabyte strings on the main thread. Plain-text/URL display extraction now reads at most 16 KiB across the first 32 items, producing up to 140 title characters and 800 preview characters. Saved content and full-text search remain complete. RTF-only entries still use Apple's full importer. Seven regression tests cover large text, Unicode, whitespace, invalid UTF-8, multi-item copies, and RTF fallback.

2. **Remove permanent permission polling.** Settings and Setup no longer own one-second timers that can remain active while their windows are retained. App activation, opening windows, and relevant actions refresh permissions. Unchanged status no longer sends unnecessary published updates. Three tests verify refresh behavior, including zero notifications for 100 unchanged refreshes.

3. **Honor additional transient clipboard markers.** Added `de.petermaurer.TransientPasteboardType`, whose omission was reproduced with a synthetic pasteboard. Six supported confidential/transient marker types now have capture-exclusion coverage. The legacy `Pasteboard generator type` string is included defensively; this macOS version rejects it as an item UTI, so it is not counted as a reproduced bypass. Marker behavior follows the [NSPasteboard marker specification](https://nspasteboard.org/).

4. **Reject stale direct-paste requests.** Restoring an entry records the pasteboard change count. Direct paste checks that receipt before activation, during the focus wait, and immediately before dispatch. Seven mocked tests cover changed contents, cancellation, focus changes, trust, terminated targets, and success. Cross-review also removed the failure callback that reopened/toggled history and could steal focus after cancellation. Feedback is retained for the user's next visit. A destination's later clipboard read cannot be atomically bound to the earlier check, so a smaller residual race remains.

5. **Remove interrupted-save snapshots.** Startup and subsequent saves remove strictly named, current-user-owned regular `.history-UUID.tmp` files. Cleanup pins the directory descriptor, refuses a symlink at that directory path, does not follow entry symlinks, and never deletes recursively. Three tests cover startup/Clear cleanup and preservation of unrelated files, directories, symlinks, and corrupt canonical history. Startup and Clear fixtures failed before the change.

## Remaining priorities

| Priority | Finding and evidence | Recommended work |
| --- | --- | --- |
| P2 | Every persisted mutation encodes and replaces the entire archive. Ten pin toggles on a 16 MiB synthetic history wrote approximately 168 MB of logical archive data, averaging 6.7 ms per write on this host. Writes are asynchronous and overlapping saves coalesce, but amplification grows with payload. | Separate immutable entry payloads from small mutable metadata, or use system SQLite. Include archive migration, crash recovery, and deletion tests. |
| P2 | Search repeatedly extracts RTF text and recomputes filtered entries during view updates/navigation. A synthetic scan of 256 RTF-only entries, approximately 30 KiB each, took about 135 ms. | Cache parsed search text and filtered results with bounded memory and explicit invalidation. Preserve full-text search semantics. |
| P3 | Paused capture still checks pasteboard change count every 0.4 seconds. | Stop polling while paused and restore the existing baseline behavior when resuming. |

Native menu-bar operation, an event-driven global hotkey, lazy history rows, and a bounded thumbnail cache are appropriate foundations. Full-archive writes and RTF parsing are the largest remaining measured optimization opportunities.

## Security boundaries and verification

History remains plaintext in an owner-only directory/file (0700/0600). This does not protect contents from other processes running as the same user, administrators, backups, or filesystem snapshots. Unmarked secrets can still be captured; privacy markers depend on the copying application. Accessibility remains necessary for direct paste.

No application-runtime network client, shell execution, remote-content renderer, or third-party package dependency was found in the reviewed source. Rich text and images rely on Apple parsers. The installed baseline is ad-hoc signed with hardened runtime; Developer ID signing and notarization remain outstanding distribution requirements.

The combined suite passed **54/54 tests**: 22 history, 7 presentation, 2 clipboard privacy/receipt, 3 temporary-file cleanup, 10 login-item, 7 paste-service, and 3 permission-refresh tests. Optimized arm64 and x86_64 builds passed. `git diff --check` passed. The new [presentation benchmark](../../Scripts/Benchmarks/ClipboardPresentation.swift) includes reproduction commands. CPU/energy improvement after the local fixes has not been measured in a controlled running-app comparison.
