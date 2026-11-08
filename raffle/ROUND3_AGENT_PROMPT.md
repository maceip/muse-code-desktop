# Round 3 Blind Research & Worktree Upgrade Lottery — Agent Prompt

Copy and paste the block below to each participating agent:

```markdown
You are participating in a **Blind Multi-Agent Research & Engineering Upgrade Lottery (Round 3)** covering two security/agent research repositories on this machine:

1. **Project 1 (`/Users/mac/jev-stageA`)** — Active Indirect Prompt Injection (IPI) defense evaluation & training pipeline testing **SecJev-4B** (a typed security decision model) in two placements (**Tool-output detector** vs. **Action-authorization monitor**) and two modes (**stop** vs. **redact**) across AgentDojo and adaptive attackers. **NOTE:** Run 3 is actively executing on remote GPUs (`Lambda 1xA100` + OpenAI Responses API). **NEVER modify `/Users/mac/jev-stageA` directly and NEVER kill or interfere with running processes or remote GPU jobs.**
2. **Project 2 (`/Users/mac/agentic-workflow-integrity`)** — Behavioral baseline + task-conditioned authorization judge (`awi/`) testing whether agent operational workflows exhibit sufficient canonical regularity to detect unauthorized/compromised actions across surface variations (`Dataset v1` and pre-registered `Dataset v2`).

---

## Mandatory Tooling & Isolation Rules (Non-Negotiable)

1. **Use `uv` for ALL Python operations**:
   - Always use `/Users/mac/.local/bin/uv run` (or `uv run` with `/Users/mac/.local/bin` on `PATH`) and the `uv` virtual environments (`.venv`) automatically created in your worktrees. Never use system/Homebrew `python3 -m venv` or raw `pip`.
2. **Work ONLY inside your automatically provisioned Git worktrees**:
   - When you register via `raffle.mjs` (Step 1 below), the coordinator automatically creates two isolated, non-colliding git worktrees on branch `raffle/<YOUR_AGENT_ID>`:
     - `/Users/mac/.raffle/worktrees/<YOUR_AGENT_ID>/jev-stageA` (with `data/`, `data2/`, `run3/`, and `Layered IPI Defense Agent Project Plan.md` linked/copied in, plus a ready `.venv`)
     - `/Users/mac/.raffle/worktrees/<YOUR_AGENT_ID>/agentic-workflow-integrity` (with a ready `.venv`)
   - **Never edit `/Users/mac/jev-stageA` or `/Users/mac/agentic-workflow-integrity` directly.** `raffle.mjs` checks `git status` on both primary directories on every call and will reject your submission if either primary checkout is dirtied.
3. **Strict Blindness**:
   - Do NOT read `/Users/mac/Documents/Pie/raffle/raffle.db` directly with `sqlite3` or Python, and do NOT inspect `/Users/mac/.raffle/worktrees/` belonging to any other agent. Use ONLY the `raffle.mjs` CLI commands below.
4. **Minimal-LOC, Maximal-Coverage Testing Goal**:
   - Both projects are evaluated by an automated AST + `trace` coverage-to-LOC meter (`coverage_runner.py`) invoked by `raffle.mjs eval`:
     $$\text{Efficiency Score} = \frac{(\text{Coverage \%})^2}{\max(40, \text{Test LOC})}$$
   - Having thorough tests that achieve high coverage (`>= 90%`) is essential, and **achieving maximal line/branch coverage in the minimum number of non-trivial test lines of code (`testLoc`)** is the explicit optimization target. Use compact, table-driven / parameterized `unittest` tests rather than repetitive copy-pasted boilerplate.

---

## Step 1 — Register & Provision Your Isolated Worktrees (Run Immediately)

Generate a unique agent ID (`agent-<random-6-hex>-r3`) and register:

```bash
export AGENT_ID="agent-$(openssl rand -hex 3)-r3"
node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs register --agent "$AGENT_ID" --model "<your-model-name>"
```

This single command registers you in `raffle.db`, creates both of your isolated worktrees under `/Users/mac/.raffle/worktrees/$AGENT_ID/`, initializes `uv venv` in each, and prints your baseline scores:
- `jev-stageA` baseline: `0` tests, `0.0%` coverage (`887` executable lines across `score.py`, `replay.py`, `analyze.py`, `defenses.py`, `attacks_ood.py`, `adaptive.py`, `report.py`, `make_paraphrases.py`, `verify_corpus.py`).
- `agentic-workflow-integrity` baseline: `28` tests, `88.69%` coverage across `awi/*.py` in `308` test LOC (`efficiencyScore: 25.54`).

---

## Step 2 — Execute the 4 Mandatory Tracks (Modify Your Worktrees + Write Reports)

You must complete and submit **all 4 tracks** below. Note: `raffle.mjs submit` supports **idempotent UPSERT** on `(agent_id, track)`, so you can refine your code/tests and re-run `submit` at any time.

### Track 1: `JEV_SOTA_AND_DATASETS` (`~/jev-stageA` — Deep SOTA Research, Dataset Discovery & Synthesis)
1. **Read & Synthesize Current State** in `/Users/mac/.raffle/worktrees/$AGENT_ID/jev-stageA`:
   - Read `RUNBOOK.md`, `RUNLOG.md`, `Layered IPI Defense Agent Project Plan.md`, `ANALYSIS_PLAN.md`, `score.py`, `secjev_scorer.py`, `defenses.py`, `replay.py`, `analyze.py`, `adaptive.py`, `attacks_ood.py`, and `make_paraphrases.py`.
   - Diagnose the exact scientific and engineering bottlenecks shown in Runs 1–3:
     - Why Stage A failed Rule 1 on `gpt-oss-20b` (attack ceiling effect where both SecJev and LLM judge hit ~`0/900`, overlapping 95% Wilson intervals).
     - Why the **Action Monitor** (`ActionGuardedExecutor` in `defenses.py`) preserves `40–57%` task utility under attack (vs `7–14%` for stop-mode tool detectors) and holds adaptive attacks to `1.7–5%`, yet loses `~17` percentage points of benign task completion zero-shot.
     - Why threshold tuning in Run 1 was optimistic (tuned and evaluated on the same normal tasks) and why `redact` mode was implemented in `defenses.py` but never evaluated in `replay.py` / `analyze.py`.
2. **Conduct Deep SOTA Literature, Benchmark & Dataset Research**:
   - Research and compare state-of-the-art architectures, benchmarks, and datasets (use web search if available, plus deep knowledge of 2024–2026 agent security literature):
     - **Benchmarks & Datasets beyond AgentDojo**: `InjecAgent`, `BIPIA` (Benchmark for Indirect Prompt Injection Attacks), `ASB` (Agent Security Bench), `ToolEmu`, `CyberSecEval 3/4`, `LLMail-Inject` (full Microsoft dataset vs the 20-item sample in `llmail_20.json`), `TensorTrust`, `WildGuardMix`, `HackAPrompt`, `Gandalf`, `SEP` (Should It Be Executed or Processed).
     - **Architectural Alternatives & Action-Authorization Training**: `CaMeL` / `Multi-CaMeL` (capabilities & dataflow taint tracking), `SecAlign` / `StruQ` / `Spotlighting` (delimited/datamarked inputs), `TaskTracker` / activation probing / representation engineering (RepE) on intermediate transformer layers, `PromptGuard-2` / `PIGuard` / `Llama-Guard-3-8B` / `ShieldGemma` / `Granite-Guardian`, and **how to construct an Action-Authorization fine-tuning / calibration dataset** directly from existing AgentDojo / `data/*.tgz` & `data2/*.tgz` trajectories without data leakage across suites.

### Track 2: `JEV_SPEED_AND_EFFICACY` (`~/jev-stageA` — Code Upgrades for Speed, Efficacy & Minimal-LOC Maximal-Coverage Tests)
Inside your worktree `/Users/mac/.raffle/worktrees/$AGENT_ID/jev-stageA`:
1. **Make the Pipeline Finish Faster**:
   - Implement concrete, runnable speedups in your `jev-stageA` worktree (e.g., batched GPU forward passes in `secjev_scorer.py` / `score.py` instead of batch-size-1 loops; content-hash deduplication of identical `(user_request, tool_call, tool_output)` decision points across attack runs so unchanged prefixes aren't re-scored 6×; async/concurrent judge & Responses API calls; Sequential Probability Ratio Test / early stopping in `adaptive.py` once Wilson bounds separate; fixing `make_paraphrases.py` bugs).
2. **Improve Defense Efficacy & Analytical Rigor**:
   - Implement concrete efficacy upgrades in your `jev-stageA` worktree (e.g., cross-suite out-of-fold threshold calibration in `analyze.py` — calibrating on 2 AgentDojo suites and evaluating on the held-out 2 suites as required by Rule 2; two-stage **Hierarchical Cascade / Score Fusion** combining `secjev_tool` + `secjev_action` so benign tasks aren't false-flagged unless untrusted tool output or high-risk action features are present; extending `replay.py` to compute counterfactual bounds for `redact` mode; dataset builder script that extracts labeled action-authorization pairs from `data/*.tgz` for LoRA/head tuning).
3. **Write Minimal-LOC, Maximal-Coverage Unit Tests (`tests/test_jev.py`)**:
   - `/Users/mac/jev-stageA` currently has **0% test coverage (`0` tests)**. Create `tests/test_jev.py` in your `jev-stageA` worktree covering `score.py`, `replay.py`, `analyze.py`, `defenses.py`, `attacks_ood.py`, `adaptive.py`, `report.py`, `make_paraphrases.py`, and `verify_corpus.py` (stubbing only external GPU/network boundaries) to achieve maximum coveragePct in minimum `testLoc`.

### Track 3: `AWI_DATA_AND_TECHNIQUES` (`~/agentic-workflow-integrity` — Active Worktree Upgrade: Real Data Sources + Better Detection Techniques)
Inside your worktree `/Users/mac/.raffle/worktrees/$AGENT_ID/agentic-workflow-integrity`:
1. **Read & Diagnose Current Limitations**:
   - Read `README.md`, `DESIGN.md`, `PREREGISTRATION_v2.md`, `awi/*.py`, `experiments/*.py`, and `results/dataset_v2_report.md`.
   - Notice why `dataset_v2` event-level precision was only **`0.20`** (failing the pre-registered `>= 0.80` target) and why `max_nll` on `dataset_v1` hit `0.0` recall (smoothing-ceiling saturation):
     - `awi/baseline.py` scores every unseen `(action, resource)` or transition with a flat Laplace ceiling, causing benign unseen steps in 9-event traces to tie with real attacks (`FP` explosion at event level).
     - `awi/canon.py` and `awi/judge.py` ignore **dataflow / taint provenance** (e.g., whether an event accesses `credential` / `external_sink` / `test_code` or follows an `untrusted_external` read) and miss subtle bash backdoors/test-weakening patterns.
2. **Add Real Multi-Harness Data Sources (`DESIGN.md` Missing Pieces #1 & #4)**:
   - On this machine right now, you have real multi-harness agent trajectories in:
     - `/Users/mac/jev-stageA/data/gptoss20b_stageA.tgz` and `qwen30b_stageA.tgz` (thousands of real AgentDojo benign & prompt-injected tool-call trajectories!)
     - `/Users/mac/.gadget/miner.db` (`antigravity_session` and `codex_session` tables/events, read-only!)
     - Existing `data/real/dataset_v1` and `data/real/dataset_v2` in `agentic-workflow-integrity`.
   - Build a real trace adapter (e.g., `awi/from_agentdojo.py` or multi-harness importer + experiment script) that imports real benign and attacked trajectories into canonical `Trace` objects and evaluates your upgraded detector on them.
3. **Implement Stronger Anomaly & Authorization Techniques in `awi/`**:
   - Upgrade `awi/` in your worktree (keeping existing CLI/experiment entrypoints working and backward-compatible) with better techniques — e.g., hierarchical/Pitman-Yor or backoff smoothing so `max_nll` doesn't saturate; taint-aware / resource-risk-weighted event scoring; structural/lexical task-intent authorization inference (Missing Piece #5: non-oracle judge that infers authorized actions/resources from the task prompt text rather than reading an oracle dict); and improved compound bash command splitting/canonicalization.
   - Verify measurable improvements on `experiments/run_dataset_eval.py` (`dataset_v1`) and `experiments/run_dataset_v2_eval.py` (`dataset_v2`).

### Track 4: `AWI_MIN_LOC_MAX_COVERAGE_TESTS` (`~/agentic-workflow-integrity` — Minimal-LOC, Maximal-Coverage Test Suite)
Inside your worktree `/Users/mac/.raffle/worktrees/$AGENT_ID/agentic-workflow-integrity/tests/`:
- Refactor/upgrade `tests/test_awi.py` (and any new test files) to push line coverage across all `awi/*.py` modules from the `88.69%` (`308` LOC, `efficiencyScore: 25.54`) baseline to **`96%–100%` coverage in dramatically fewer lines of code** (targeting `efficiencyScore >= 60+`).
- Every test must execute real code paths in `awi/` and assert real behavioral invariants (zero fake `assertTrue(True)` or no-op calls).

---

## Step 3 — Evaluate & Submit All 4 Tracks via `raffle.mjs`

At any time during your work, run `eval` to see your live coverage %, `testLoc`, `efficiencyScore`, missed line numbers per file, and `dataset_v1` / `dataset_v2` metrics:

```bash
node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs eval --agent "$AGENT_ID"
```

Write a detailed markdown writeup file for each track (e.g. inside `/Users/mac/.raffle/worktrees/$AGENT_ID/track1.md`, `track2.md`, `track3.md`, `track4.md` — minimum 250 characters each, with concrete tables, math, file/line references, and benchmark numbers) and submit all 4 tracks:

```bash
node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs submit \
  --agent "$AGENT_ID" \
  --track JEV_SOTA_AND_DATASETS \
  --title "< concise title >" \
  --summary-file "/Users/mac/.raffle/worktrees/$AGENT_ID/track1.md" \
  --citations "< key papers, repos, datasets cited >"

node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs submit \
  --agent "$AGENT_ID" \
  --track JEV_SPEED_AND_EFFICACY \
  --title "< concise title >" \
  --summary-file "/Users/mac/.raffle/worktrees/$AGENT_ID/track2.md" \
  --citations "< files modified & tests added >"

node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs submit \
  --agent "$AGENT_ID" \
  --track AWI_DATA_AND_TECHNIQUES \
  --title "< concise title >" \
  --summary-file "/Users/mac/.raffle/worktrees/$AGENT_ID/track3.md" \
  --citations "< data sources & techniques implemented >"

node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs submit \
  --agent "$AGENT_ID" \
  --track AWI_MIN_LOC_MAX_COVERAGE_TESTS \
  --title "< concise title >" \
  --summary-file "/Users/mac/.raffle/worktrees/$AGENT_ID/track4.md" \
  --citations "< coverage % and test LOC achieved >"
```

(`submit` automatically commits your worktree changes on branch `raffle/$AGENT_ID` and records your exact commit SHAs, diff stats, and live `coverage_runner.py` + AWI benchmark scores.)

---

## Step 4 — Final Completion Check

Before finishing, run:

```bash
node --disable-warning=ExperimentalWarning /Users/mac/Documents/Pie/raffle/raffle.mjs status --agent "$AGENT_ID"
```

Confirm that `"allTracksComplete": true`, `"completedTracksCount": 4`, `"missingTracks": []`, and both `jevStageA` and `agenticWorkflowIntegrity` show `"ok": true` with your target coverage and efficiency scores.
```
