# Do: architecture

```
 Spotlight ─┐                 ┌──────────────── AppController (MainActor) ────────────────┐
 doapp://  ─┼─ start(task) ──▶│ ModelController ── download/verify ── MageVLRuntime (actor)│
 Try it    ─┘                 │ IslandController ◀── AgentEvent stream ── AgentSession      │
                              │ CursorOverlayController ◀── ActionVisualizer ── MacEnvironment
                              │ EscapeMonitor (CGEventTap)                                 │
                              └────────────────────────────────────────────────────────────┘
```

## Triggering

`DoTaskIntent` (App Intents) is surfaced to Spotlight through `DoAppShortcuts`. It has one
`String` parameter, so in Spotlight you type **Do**, pick the action, and type the task. The
intent runs in-process (`openAppWhenRun = false`; macOS launches Do in the background if
needed), calls `AppController.start(task:)`, and returns immediately.

Every other entry point (the `doapp://run?task=` URL scheme, the window's *Try it* box, and in
V2 a menu bar item) calls the same `start(task:)`. A V2 menu bar item that opens Spotlight
with the intent preselected has no public API; the URL scheme and a custom panel are the
supported paths.

## The model port (`Packages/DoKit/Sources/MageVL`)

Mage-VL-Cowork = **Mage-ViT** (24-layer pre-norm ViT, 16 px patches, 3-D RoPE with a 4:6:6
T:H:W split, 2×2 patch merger) + **Qwen3-4B-Instruct-2507** (plain 1-D RoPE). The 4-bit MLX
build quantizes the language model (affine, group 64) and keeps the vision tower in bf16.

The Swift port mirrors mlx-vlm 0.7.11's `mage_vl` and reproduces the upstream quirks the weights
were trained with: an interleaved rotation `(x1,x2)→(-x2,x1)`, a `concat([freqs, freqs])`
frequency table, and RoPE positions in the processor's 2×2 merge-block order.

`mage-cli parity` (see README) checks every stage against Python on a real prompt:

| Stage | Result |
| --- | --- |
| Prompt text (AgentHistory + QwenChatTemplate vs HF `apply_chat_template`) | identical (4,692 chars) |
| Token IDs incl. image-pad expansion | identical (2,635) |
| Preprocessed pixels (CoreGraphics vs PIL bicubic) | mean \|Δ\| 0.003 |
| Vision features | cosine 0.998 |
| Final-token logits | cosine 0.9992, identical top-5 |

Embeddings, RoPE tables and the pre-norm match bit-for-bit, and one encoder layer fed identical
inputs agrees to 2e-5. The residual vision difference is bf16 rounding amplified over 24 layers:
in Python alone, a 0.1% input perturbation moves the encoder output further (cosine 0.98) than
the Swift↔Python gap does. Greedy decoding on a 2-step agent prompt gives the same click from
both implementations ((599, 216) Swift vs (597, 216) Python).

### Runtime

`MageVLRuntime` is an actor on its own serial queue (inference is long synchronous Metal work).
It renders the conversation with an exact Swift port of the checkpoint's Qwen3 chat template,
tokenizes with swift-transformers, expands each `<|image_pad|>` to the image's visual-token
count, and:

- **Prompt cache.** Keeps the previous turn's KV cache and reuses the longest common prefix.
  Prefixes are compared per token *and* per image ID, since two different screenshots of the
  same size have identical pad tokens. Steps 2–3 of a task reuse ~75% of the prompt.
- **Vision cache.** Memoises visual tokens per screenshot ID, so screenshots that stay in the
  3-image window are encoded once.
- Prefills in 1,024-token chunks, then hands the last token to mlx-swift-lm's `TokenIterator`
  for sampling (temperature 0.7, top-p 0.8 by default: the reference OSWorld configuration).

Measured on an M4 / 16 GB: a cold first turn with a 1512×982 screenshot (1,457 visual tokens,
2,635 total) prefills in ~9 s (Python mlx-vlm: 9.5 s), and decoding runs at ~30 tok/s. Screenshots
are capped at 1920×1080 worth of pixels (the training resolution) by default; *Settings ▸
Screenshot detail ▸ Faster* trades precision for speed.

## The agent loop (`Packages/DoKit/Sources/DoCore/Agent`)

A faithful port of Microsoft's `MAGEHybridAgent` harness:

- **System prompt.** Verbatim `MAGE_HYBRID_SYSTEM_PROMPT`, generated from the reference
  source and pinned by SHA-256 in a test.
- **Working memory.** The 3 most recent steps keep full responses; up to 3 most recent
  screenshots stay visible, older ones become `[This screenshot has been collapsed.]`; earlier
  steps fold into `Previous actions:` lines, pairwise-merged once the history gets long.
- **Observation after each step.** A `bash` step is answered with its merged output
  (truncated at 5,000 chars). A `computer_use` step is answered with a fresh screenshot.
- **Parsing.** `<think>`, the `Action:` line, and up to 15 `<tool_call>` blocks of a single
  tool family, with the reference's fallbacks for malformed output.
- **macOS adaptation.** The policy was trained on Ubuntu desktops, so the instruction carries a
  one-line note that this is macOS with Command-key shortcuts and BSD tools. Outside terminal
  apps, standard Ctrl shortcuts are also translated to ⌘.

## Acting on the Mac (`DoCore/Platform`)

| Concern | Implementation |
| --- | --- |
| Seeing | ScreenCaptureKit, 1 px per point, cursor hidden, **Do's own windows excluded** |
| Coordinates | `x/999·(width−1)` in points on the captured display (reference mapping) |
| Pointer | CGEvent glides, clicks with click-state for double/triple, pixel-precise drags |
| Scroll | pixel scroll-wheel events in steps; \|999\| = one screen |
| Keys | layout-aware (`UCKeyTranslate`) so shortcuts work on non-QWERTY layouts |
| Typing | Unicode keyboard events (any script), Return/Tab for `\n`/`\t` |
| Shell | `zsh -lc` via `posix_spawn` in its own process group, stdin on `/dev/null`, 300 s timeout that kills the whole group |
| Safety | risky commands (`rm -r`, `sudo`, `curl … \| sh`, `git push`, installs, …) wait for approval in the island |

Every synthetic event is tagged (`eventSourceUserData`), so the Escape tap can tell Do's
keystrokes from the user's.

## The island

`IslandController` hosts a non-activating panel above the menu bar. `DisplayCutout` chooses the
style:

- **Notch** (MacBook Pro/Air): a black shape grows out of the notch, with the spinner and ✕ in
  the ears beside the camera and the rotating status line below it.
- **Dynamic Island** (touchscreen MacBook Pro, Oct 2026): the same layout as a fully rounded
  capsule around the cutout. These Macs are recognised by a cutout plus a built-in HID touch
  digitizer (IORegistry, no permission prompt). *Why not the system Dynamic Island?* Apple's
  ActivityKit is iOS/iPadOS-only. On the Mac, Live Activities come from iPhone/iPad apps and
  there is no API for a Mac app to start one. `IslandStyle` is the seam where a native backend
  would plug in if Apple adds one.
- **Floating** pill under the menu bar on displays without a cutout.

The panel is click-through except over the island itself, and fully click-through while the
agent is performing input, so its synthetic clicks always reach the app underneath.

## The cursor

`CursorOverlayController` draws Do's own pointer in a full-screen, click-through overlay. It
glides to each target before the real event fires (the environment awaits the animation),
ripples on clicks (twice for double-click, orange for right-click), trails a dashed line while
dragging, morphs into a scroll indicator with flowing chevrons, and labels typing, key chords,
shell commands, waiting, and thinking.

## Stopping

`EscapeMonitor` is a session-level `CGEventTap` active only while Do works. The first Escape
arms ("Stop now — press Escape again", 3 s window). The second cancels the run's task, which
cancels decoding, shell commands (process-group kill) and input (held buttons and modifiers
are released). The user's Escapes are swallowed while armed so they don't also reach the app
being driven.

## Not yet done / next

- Menu bar item and custom task panel (V2).
- Native Dynamic Island once macOS exposes an API.
- Speed: KV-cache quantization, smaller screenshot budgets per step, speculative decoding.
- Evaluate the 8-bit / bf16 builds: the 4-bit build's grounding is noticeably less precise.
