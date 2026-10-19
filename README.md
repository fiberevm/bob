# Bob

A native macOS developer workspace and AI agent harness written in Swift, with a SwiftUI/AppKit interface and a WebKit browser. The app has no third-party package dependencies; an optional local decision worker uses MLX.

See the [reference](docs/reference.md) for provider connections, local decision setup, features, tool safety, and architecture.

## Build and run

Requires macOS 14+ and Xcode's Swift toolchain (Swift 5.10+).

```sh
make run      # Build and open the current project in Bob
make build    # Build only: .build/Bob.app (ad-hoc signed)
make release  # Build an optimized app
make test     # Run native tests
```

Open `Package.swift` in Xcode to develop the app. Ordinary builds do not download model weights or build MLX. **Agent tool execution requires Clef and macOS 15+**; follow the [local decision setup](docs/reference.md#local-decisions) on Apple Silicon, then rebuild. Shell tools execute directly on your Mac, not in a workspace sandbox; low/medium-risk calls run automatically, while high/critical-risk calls require confirmation.

## Bob vs. Codex size and memory

**Observed live resident memory (RSS), not a controlled benchmark.** Snapshot captured October 19, 2026 at 11:18:40 PDT on macOS 26.6.2, Apple M4 Max, 64 GiB RAM. Bob was version 0.1.0 (build 1). The comparison installation was **`/Applications/ChatGPT.app`**, version 26.1007.21159 (build 20052), with Codex-named helpers—not a verified standalone `Codex.app`.

| Metric | Bob (excluding Clef) | ChatGPT.app / Codex-labelled processes | Bob reduction |
| --- | ---: | ---: | ---: |
| On-disk app bundle, excluding Clef components | 12.91 MiB | 1.62 GiB | 99.22% smaller |
| Main-process RSS | 126.6 MiB | 249.6 MiB | 49.26% less |
| Main + bundle-executable descendant RSS | 126.6 MiB (1 process) | 2.60 GiB (98 processes) | 95.24% less |
| Other descendant RSS, shown separately | None | 389.1 MiB (34 processes) | — |

Disk sizes were measured separately on October 19, 2026 at 11:32 PDT using `du -sk` (allocated disk space, not download size). Bob’s 12.91 MiB is a subtotal of the existing bundle after subtracting `Contents/Helpers` (`BobDecision` and `mlx.metallib`), the Clef/Transformers/Crypto resource bundles, and `DecisionModel.json`; it is not a separately built Clef-free app. Model weights live outside the app and are excluded. The full installed Bob bundle, including those packaged Clef components but not external weights, occupied 154.35 MiB; the comparison bundle occupied 1,659.38 MiB.

Percent reductions use `(comparison − Bob) / comparison × 100`, calculated from unrounded KiB values. These are size and memory reductions, **not speedups**; no timing benchmark was run.

The bundle-process RSS totals include task runtimes, not just UI helpers: the comparison included Node/REPL processes, Codex renderers, services, and CLI processes. Non-bundle descendants are separate in the last row. Bob's **Clef / `BobDecision` worker and its subtree, including its model, are excluded**; these figures are not Bob's total memory requirement with local inference enabled. Measurement-process ancestry and descendants were also excluded, retaining the app roots.

RSS was collected with `ps -axo pid=,ppid=,rss=,comm=` and grouped by process ancestry and executable bundle path. KiB values were converted using 1,024 KiB per MiB and 1,048,576 KiB per GiB. Workloads and session counts were not matched or held idle. Summed RSS can count shared pages more than once and is not macOS physical footprint; this snapshot does not establish a general memory ratio or performance advantage.
