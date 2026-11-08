# GoGoGadget — What Should Happen Next (Engineering & Product Roadmap)

> Canonical copy also written to [`/Users/mac/gogogadget/NEXT_STEPS.md`](file:///Users/mac/gogogadget/NEXT_STEPS.md).

**Date:** 2026-11-01  
**Baseline Commit:** `0cc7510` (`230/230` tests passing, `83.75%` line / `90.02%` function coverage, `~/.gadget/miner.db` migrated to `v3` and compacted from `598.27 MiB` $\rightarrow$ `234.40 MiB`)

---

## Executive Diagnosis: Where We Actually Stand

After two full multi-agent audit and remediation rounds, the **core engine, storage layer (`v3` SQLite + external-content FTS5 + tiered retention), bitemporal feedback loops (Loops A–D), and test/benchmark harnesses** are solid and verified against real hardware and adversarial edge cases.

However, inspecting the live machine state (`/Users/mac/.gadget/daemon-status.json`, `launchctl`, `~/.zshrc`, and `src/miner/cli.ts`) reveals why `gogogadget` is not yet functioning as an always-on ambient prosthetic in your day-to-day life:

1. **The last spoken utterance in your live `daemon-status.json` is literally `"remind me how to load the dashboard"`.**  
   Having to remember a localhost port (`http://127.0.0.1:4321` or `43110`) and open a browser tab defeats the entire premise of an ambient, zero-friction prosthetic. Skypanel needs to live in a native macOS floating non-activating `NSPanel` / Menu Bar app with a global hotkey and auto-slide-in when a card transitions to `PENDING`.
2. **Neither the daemon nor the Skypanel server is managed by `launchd` (`LaunchAgents`), and `cli.ts` currently leaves `enableScreen`, `enableClipboard`, and `enableKeyboard` off by default.**  
   `daemon-status.json` shows `pid 28000` stopped ticking yesterday (`2026-10-31T11:21:59Z`). Furthermore, in [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts#L211-L253), `enableClipboard`, `enableKeyboard`, and `enableScreen` check `=== true`, while [`src/miner/cli.ts`](file:///Users/mac/gogogadget/src/miner/cli.ts#L254-L261) (`npm run mine -- daemon`) only passes `enableAudio`, leaving screen, clipboard, and keyboard capture disabled unless explicitly wired in `cli.ts`.
3. **Your live database has only `3` `zsh_hook` rows and `0` `chrome` / `messages` rows (`git` is 92% of all rows).**  
   [`capture/zsh/gadget-hook.zsh`](file:///Users/mac/gogogadget/capture/zsh/gadget-hook.zsh) is not installed in `~/.zshrc`, so your real terminal commands, exit codes, and `rg`/`grep`/`git log` seeks are never entering `~/.gadget/capture/zsh.jsonl`. Without live `zsh_hook` and `chrome` events, **Path B (Proactive Episode/Seek Anticipation)** is starved of real daily triggers.
4. **Synchronous `execFileSync` sensory polling blocks the daemon loop and drops spoken words between 3.5s audio chunks.**  
   In [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts#L225-L292), `watchKeysBurst`, `captureScreenAndOcr`, and `recordAudioClip` + `whisper-cli` run sequentially and synchronously on the main thread, reloading the Whisper model from disk on every tick and leaving a 2–5 second deaf window between audio clips.

---

## Priority 1 — Immediate Operational Wiring (Day 1: Make It Actually Run 24/7)

### 1.1 Fix `cli.ts` Daemon Flags & Unify Daemon + Web Server Lifecycle
- **Problem:** [`src/miner/cli.ts`](file:///Users/mac/gogogadget/src/miner/cli.ts#L254-L261) constructs `new AmbientCatalogDaemon(cfg, { intervalMs, enableAudio, audioClipSec, keyWatchSec, once, retention: !once })` without setting `enableScreen: !args.includes("--no-screen")`, `enableClipboard: !args.includes("--no-clipboard")`, and `enableKeyboard: !args.includes("--no-keyboard")`.
- **Action:**
  1. Pass `enableScreen`, `enableClipboard`, and `enableKeyboard` (default `true` in `cli.ts` unless `--no-*` is passed, keeping library defaults `false` for unit tests).
  2. Have `runProactiveBriefUpdate()` in [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts#L528-L632) also call [`runFunctionalSpine()`](file:///Users/mac/gogogadget/src/triggers/spine.ts#L98-L293) (or upsert `PROACTIVE_SEEK` cards into `skypanel_cards`), because right now `runProactiveBriefUpdate()` only writes `.gadget/brief.md` and never populates `skypanel_cards` with Path B proactive cards unless `/api/skypanel/evaluate` is hit over HTTP.

### 1.2 Gate Screen OCR Behind `OpenChronicleEventDispatcher` *Before* Running Vision OCR
- **Problem:** In [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts#L253-L278), `captureScreenAndOcr()` takes a screenshot and runs Apple `Vision.framework` OCR on *every* tick, and only *afterwards* feeds `this.screenDispatcher.ingestNotification(...)` (ignoring its boolean return value).
- **Action:**
  1. Query frontmost app + window title + perceptual/dHash first via `macos_sensory` (`< 2 ms`).
  2. Ask `this.screenDispatcher.ingestNotification(...)` whether the 4-timer state machine (`debounceMs`, `dedupIntervalMs`, `minCaptureGapMs`, `sameWindowDedupMs`) permits capture.
  3. Only invoke `VNRecognizeTextRequest` OCR when the dispatcher returns `dispatched: true`. This cuts idle CPU/GPU wakeups by ~85%.

### 1.3 Install the Zsh Hook, Periodic Session/Chrome Sync, and `launchd` Service
- **Problem:** `~/.gadget/miner.db` has only `3` `zsh_hook` events and `0` `chrome` events because [`capture/zsh/gadget-hook.zsh`](file:///Users/mac/gogogadget/capture/zsh/gadget-hook.zsh) isn't sourced in `~/.zshrc`, and `AmbientCatalogDaemon` only tails `.gadget/capture/*.jsonl` without incrementally syncing `antigravity_session`, `codex_session`, `chrome` History, or `Calendar.app` / `Messages.app`.
- **Action:**
  1. Add a `npm run mine -- install` command that:
     - Appends `source /Users/mac/gogogadget/capture/zsh/gadget-hook.zsh` (idempotently) to `~/.zshrc`.
     - Installs and loads `~/Library/LaunchAgents/com.gogogadget.runtime.plist` running both the Skypanel server (`127.0.0.1:43110`) and the ambient daemon with `KeepAlive: true` and `RunAtLoad: true`.
  2. Add an incremental 60-second background sync inside `AmbientCatalogDaemon` that ingests new `antigravity_session` / `codex_session` transcript lines, recent `chrome` visits (via safe SQLite backup copy), and local `Calendar.app` / `Messages.app` (`~/Library/Messages/chat.db` read-only) events.

---

## Priority 2 — Continuous Low-Overhead Audio & Native macOS TCC App Bundle (Days 2–4)

### 2.1 Replace 3.5-Second Cold-Start `whisper-cli` Polling with Continuous VAD Streaming
- **Problem:** Spawning `ffmpeg` for 3.5s and then spawning `whisper-cli` from scratch on every daemon tick drops speech during the transcription gap and reloads the `ggml` model every few seconds.
- **Action:**
  1. Use an always-resident audio stream with lightweight RMS / Silero VAD (Voice Activity Detection) in `macos_sensory` (or `whisper-stream` / persistent `whisper-server` over a local Unix domain socket `~/.gadget/whisper.sock`).
  2. Only run Whisper inference when voice energy crosses the VAD threshold, with a 500ms pre-roll ring buffer so trigger prefixes (`"Hey Gadget"`, `"Note to self"`, `"Remind me"`, `"Lock it in"`) at the very start of an utterance are never clipped.

### 2.2 Package `GoGoGadget.app` (Signed macOS Menu Bar + Non-Activating Floating `NSPanel`)
- **Problem:**
  1. macOS TCC (Screen Recording, Accessibility, Input Monitoring, Microphone, Full Disk Access for `chat.db`) attaches permissions to a signed `.app` bundle with a stable `CFBundleIdentifier` (`com.gogogadget.app`), not to bare CLI sub-processes.
  2. A browser tab (`127.0.0.1:43110`) is invisible when you're working in Xcode, Cursor, or Terminal.
- **Action:**
  1. Build a ~250-line Swift native host (`src/macos/GoGoGadgetApp.swift`) compiled into `/Applications/GoGoGadget.app`:
     - **Menu Bar item (`NSStatusItem`)** showing live capture health, active spoken slots count, and privacy pause toggle (`Pause Capture for 15m`).
     - **Floating HUD (`NSPanel` with `.nonActivatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`)** pinned to the top-right beneath the menu bar that stays hidden (`0 px`) when `0` cards are `PENDING`, and smoothly slides in (`48 px` compact 2-row strip) without stealing keyboard focus when a card surfaces.
     - **Global keyboard shortcuts**: `⌥Space` to toggle/expand the active Skypanel card, `⌥↩` to execute the recommended mode (`Mode 1: Native App` or `Mode 2: Action Agent`), `⌥⌫` to dismiss (feeding Loop A `DISMISSED` directly).

---

## Priority 3 — Android Companion & Cross-Device Continuity (Days 5–7)

### 3.1 Wire the Android Companion APK (`~/.gadget/android-companion-apk`) Over Tailscale / Local TLS
- **Problem:** The codebase already supports cross-device spoken-slot deduplication ([`deduplicateSpokenSlotAcrossDevices`](file:///Users/mac/gogogadget/src/triggers/cosmo_spoken_slots.ts#L310-L395)), mobile viewport geometry (`GET /api/skypanel?surface=mobile` at `390x844`), and `android.jsonl` SMS/utterance ingestion, and `~/.gadget/android-companion-apk` exists on disk, but live phone $\leftrightarrow$ Mac transport is not running continuously.
- **Action:**
  1. Add an authenticated local/Tailscale ingestion endpoint (`POST /api/companion/ingest` with a mode-`0600` pre-shared bearer token stored in `~/.gadget/companion-token`, explicitly scoped in `guard_no_send.mjs` as inbound-only local/Tailscale listener).
  2. Have the Android companion app stream spoken trigger slots and inbound SMS continuation events directly to the Mac's `EventStore` and render the `surface=mobile` Skypanel WebView / native Compose sheet on the phone.

---

## Priority 4 — Closing the Loop on Phase 0 / Phase 1 Evaluation & Calibration (Week 2)

### 4.1 Re-Run Real Episode Labeling & Calibrate `CalibratedAnticipator` Weights on Live Usage
- **Problem:** [`/Users/mac/.gadget/STATUS.md`](file:///Users/mac/.gadget/STATUS.md) shows the last Phase 0 report was generated on `2026-10-29` (`12/25` real seeking before the seek-detection fixes landed). Once `~/.zshrc` hook and Chrome history sync have run for 48–72 hours of real work:
- **Action:**
  1. Run `npm run mine -- report` and label 25 fresh episodes in the Skypanel **Review Queue** (which writes directly into the SQLite `review_records` and `evidence_feedback` tables).
  2. Run `npm run mine -- replay` to verify that **Loop A (`card_feedback_tokens`)** and **Loop C (`evidence_feedback`)** measurably improve precision and MRR on your actual work episodes, not just synthetic multi-day fixtures.
  3. Fit the logistic weights in [`CalibratedAnticipator`](file:///Users/mac/gogogadget/src/runtime/anticipator.ts) via Platt scaling against your labeled `review_records` table once `>= 50` real card outcomes (`DISPATCHED` vs `DISMISSED`) have accumulated.

---

## Summary Checklist (Ordered by Highest Leverage)

| # | Milestone | Key Files | Expected Impact |
| :-: | :--- | :--- | :--- |
| **1** | Enable screen/clipboard/keyboard in `cli.ts` daemon & gate OCR behind `OpenChronicleEventDispatcher` | [`src/miner/cli.ts`](file:///Users/mac/gogogadget/src/miner/cli.ts), [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts) | Live sensory capture actually runs in `daemon` mode with ~85% lower idle OCR CPU usage |
| **2** | Wire `runProactiveBriefUpdate` $\rightarrow$ `skypanel_cards` (`PROACTIVE_SEEK`) | [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts), [`src/triggers/spine.ts`](file:///Users/mac/gogogadget/src/triggers/spine.ts) | Path B proactive cards surface automatically on daemon ticks without waiting for manual HTTP `/evaluate` calls |
| **3** | `npm run mine -- install` (`~/.zshrc` hook + `launchd` plist + 60s Chrome/Session/Calendar incremental sync) | [`capture/zsh/gadget-hook.zsh`](file:///Users/mac/gogogadget/capture/zsh/gadget-hook.zsh), [`src/runtime/daemon.ts`](file:///Users/mac/gogogadget/src/runtime/daemon.ts) | Always-on background execution across reboots; real terminal failures & browser seeks populate `miner.db` |
| **4** | Continuous VAD + resident Whisper socket (`~/.gadget/whisper.sock`) | [`src/media/macos_sensory.swift`](file:///Users/mac/gogogadget/src/media/macos_sensory.swift), [`src/media/stt.ts`](file:///Users/mac/gogogadget/src/media/stt.ts) | Zero clipped trigger prefixes, `< 400 ms` STT latency, no cold model reloads every 3.5 seconds |
| **5** | Native signed `/Applications/GoGoGadget.app` (`NSStatusItem` + non-activating floating `NSPanel` + global hotkeys) | `src/macos/GoGoGadgetApp.swift` | Solves macOS TCC permission persistence and replaces browser-tab hunting with a true ambient top-right HUD |
