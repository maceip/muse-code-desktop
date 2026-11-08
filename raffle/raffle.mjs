#!/usr/bin/env node
/**
 * Round 3 Blind Research & Worktree Upgrade Lottery Coordinator (`raffle.mjs`)
 *
 * Improvements over Rounds 1 & 2:
 * 1. Automatic collision-free git worktree + `uv venv` provisioning on `register`.
 * 2. All Python operations run strictly via `/Users/mac/.local/bin/uv` (`uv venv` / `uv run`).
 * 3. Built-in deterministic AST + `trace` coverage-to-LOC efficiency evaluator (`eval`).
 * 4. Focused 4-track structure with idempotent UPSERT on `(agent_id, track)` + auto-commit of worktree changes.
 * 5. Primary checkouts (`/Users/mac/jev-stageA` and `/Users/mac/agentic-workflow-integrity`) are guarded read-only.
 */

import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";

const RAFFLE_DIR = "/Users/mac/Documents/Pie/raffle";
const DB_PATH = join(RAFFLE_DIR, "raffle.db");
const COVERAGE_RUNNER = join(RAFFLE_DIR, "coverage_runner.py");
const WORKTREES_ROOT = "/Users/mac/.raffle/worktrees";
const JEV_PRIMARY = "/Users/mac/jev-stageA";
const AWI_PRIMARY = "/Users/mac/agentic-workflow-integrity";
const UV_BIN = existsSync("/Users/mac/.local/bin/uv") ? "/Users/mac/.local/bin/uv" : "uv";

const VALID_TRACKS = [
  "JEV_SOTA_AND_DATASETS",
  "JEV_SPEED_AND_EFFICACY",
  "AWI_DATA_AND_TECHNIQUES",
  "AWI_MIN_LOC_MAX_COVERAGE_TESTS",
];

function flag(args, name) {
  const idx = args.indexOf(name);
  if (idx === -1 || idx + 1 >= args.length) return undefined;
  return args[idx + 1];
}

function sanitizeAgentId(raw) {
  if (!raw || typeof raw !== "string") {
    throw new Error("Missing --agent <agent-id>");
  }
  const cleaned = raw.trim().replace(/[^a-zA-Z0-9._-]/g, "-");
  if (cleaned.length < 3 || cleaned.length > 64) {
    throw new Error(`Invalid agent ID "${raw}" (must be 3..64 alphanumeric/dash chars)`);
  }
  return cleaned;
}

function openDb() {
  mkdirSync(RAFFLE_DIR, { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(DB_PATH);
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA busy_timeout = 15000;
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS raffle_agents (
      agent_id TEXT PRIMARY KEY,
      model_hint TEXT NOT NULL DEFAULT 'unknown',
      jev_worktree TEXT NOT NULL,
      awi_worktree TEXT NOT NULL,
      registered_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS raffle_submissions (
      submission_id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent_id TEXT NOT NULL,
      track TEXT NOT NULL CHECK (track IN (
        'JEV_SOTA_AND_DATASETS',
        'JEV_SPEED_AND_EFFICACY',
        'AWI_DATA_AND_TECHNIQUES',
        'AWI_MIN_LOC_MAX_COVERAGE_TESTS'
      )),
      title TEXT NOT NULL,
      summary_markdown TEXT NOT NULL,
      citations_text TEXT NOT NULL DEFAULT '',
      jev_commit_sha TEXT NOT NULL DEFAULT '',
      awi_commit_sha TEXT NOT NULL DEFAULT '',
      jev_diff_stat TEXT NOT NULL DEFAULT '',
      awi_diff_stat TEXT NOT NULL DEFAULT '',
      jev_eval_json TEXT NOT NULL DEFAULT '{}',
      awi_eval_json TEXT NOT NULL DEFAULT '{}',
      submitted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(agent_id, track),
      FOREIGN KEY (agent_id) REFERENCES raffle_agents(agent_id)
    );
  `);
  return db;
}

function runGit(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function verifyPrimaryReposUntouched() {
  // Primary /Users/mac/agentic-workflow-integrity must have zero uncommitted tracked changes
  const awiDirty = runGit(AWI_PRIMARY, ["status", "--porcelain", "--untracked-files=no"]);
  if (awiDirty.length > 0) {
    throw new Error(
      `Primary repo ${AWI_PRIMARY} has uncommitted modifications! Work ONLY inside your isolated worktree under ${WORKTREES_ROOT}/<agent-id>/agentic-workflow-integrity.\nDirty:\n${awiDirty}`,
    );
  }
  const jevDirty = runGit(JEV_PRIMARY, ["status", "--porcelain", "--untracked-files=no"]);
  if (jevDirty.length > 0) {
    throw new Error(
      `Primary repo ${JEV_PRIMARY} has uncommitted modifications! Work ONLY inside your isolated worktree under ${WORKTREES_ROOT}/<agent-id>/jev-stageA.\nDirty:\n${jevDirty}`,
    );
  }
}

function provisionWorktree(primaryRepo, worktreePath, branchName) {
  mkdirSync(dirname(worktreePath), { recursive: true, mode: 0o700 });
  if (!existsSync(join(worktreePath, ".git"))) {
    try {
      runGit(primaryRepo, ["worktree", "prune"]);
    } catch {
      // ignore
    }
    const existingBranches = runGit(primaryRepo, ["branch", "--list", branchName]);
    if (existingBranches) {
      runGit(primaryRepo, ["worktree", "add", "--force", worktreePath, branchName]);
    } else {
      runGit(primaryRepo, ["worktree", "add", "--force", "-b", branchName, worktreePath, "HEAD"]);
    }
  }
  // Provision uv venv inside the worktree
  execFileSync(UV_BIN, ["venv", join(worktreePath, ".venv"), "--allow-existing"], {
    cwd: worktreePath,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function ensureSymlinkOrCopyJevExtras(jevWorktree) {
  const planFile = "Layered IPI Defense Agent Project Plan.md";
  const srcPlan = join(JEV_PRIMARY, planFile);
  const dstPlan = join(jevWorktree, planFile);
  if (existsSync(srcPlan) && !existsSync(dstPlan)) {
    copyFileSync(srcPlan, dstPlan);
  }
  for (const dirName of ["data", "data2", "run3"]) {
    const srcDir = join(JEV_PRIMARY, dirName);
    const dstDir = join(jevWorktree, dirName);
    if (existsSync(srcDir) && !existsSync(dstDir)) {
      try {
        symlinkSync(srcDir, dstDir, "dir");
      } catch {
        // ignore if already linked
      }
    }
  }
}

function evaluateWorktree(worktreePath, kind) {
  if (!existsSync(worktreePath)) {
    return { ok: false, error: `Worktree not found: ${worktreePath}` };
  }
  let covJson = {};
  try {
    const raw = execFileSync(
      UV_BIN,
      ["run", "--directory", worktreePath, "python", COVERAGE_RUNNER, worktreePath, kind],
      {
        cwd: worktreePath,
        encoding: "utf8",
        timeout: 60_000,
        stdio: ["ignore", "pipe", "pipe"],
      },
    ).trim();
    const lastLine = raw.split("\n").at(-1) ?? "{}";
    covJson = JSON.parse(lastLine);
  } catch (err) {
    const stdout = err.stdout ? String(err.stdout).trim() : "";
    const lastLine = stdout.split("\n").at(-1) ?? "";
    try {
      covJson = JSON.parse(lastLine);
    } catch {
      covJson = {
        ok: false,
        error: String(err.message ?? err).slice(0, 600),
      };
    }
  }

  if (kind === "awi") {
    const metricsSummary = {};
    try {
      execFileSync(
        UV_BIN,
        ["run", "--directory", worktreePath, "python", "experiments/run_dataset_eval.py"],
        { cwd: worktreePath, timeout: 30_000, stdio: ["ignore", "pipe", "pipe"] },
      );
      const v1Path = join(worktreePath, "results/dataset_v1_metrics.json");
      if (existsSync(v1Path)) {
        const v1 = JSON.parse(readFileSync(v1Path, "utf8"));
        metricsSummary.datasetV1 = v1.modes ?? v1;
      }
    } catch (err) {
      metricsSummary.datasetV1Error = String(err.message ?? err).slice(0, 300);
    }
    try {
      execFileSync(
        UV_BIN,
        ["run", "--directory", worktreePath, "python", "experiments/run_dataset_v2_eval.py"],
        { cwd: worktreePath, timeout: 30_000, stdio: ["ignore", "pipe", "pipe"] },
      );
      const v2Path = join(worktreePath, "results/dataset_v2_metrics.json");
      if (existsSync(v2Path)) {
        const v2 = JSON.parse(readFileSync(v2Path, "utf8"));
        metricsSummary.datasetV2 = {
          event_level_primary: v2.event_level_primary,
          trace_level: v2.trace_level,
        };
      }
    } catch (err) {
      metricsSummary.datasetV2Error = String(err.message ?? err).slice(0, 300);
    }
    covJson.awiBenchmarks = metricsSummary;
  }

  return covJson;
}

function autoCommitWorktree(worktreePath, agentId, track, title) {
  // Remove symlinked data/data2/run3 before git add in jev worktree so huge tarballs aren't staged, then re-link
  const unlinked = [];
  for (const d of ["data", "data2", "run3"]) {
    const p = join(worktreePath, d);
    try {
      if (lstatSync(p).isSymbolicLink()) {
        rmSync(p);
        unlinked.push(d);
      }
    } catch {
      // not a symlink
    }
  }
  try {
    const status = runGit(worktreePath, ["status", "--porcelain"]);
    if (status.length > 0) {
      runGit(worktreePath, ["add", "-A"]);
      runGit(worktreePath, [
        "-c",
        `user.name=${agentId}`,
        "-c",
        `user.email=${agentId}@raffle.local`,
        "commit",
        "-m",
        `raffle(${track}): ${title}`,
      ]);
    }
    const sha = runGit(worktreePath, ["rev-parse", "HEAD"]);
    const diffStat = runGit(worktreePath, ["diff", "--stat", "main..HEAD"]);
    return { sha, diffStat };
  } finally {
    for (const d of unlinked) {
      const srcDir = join(JEV_PRIMARY, d);
      const dstDir = join(worktreePath, d);
      if (existsSync(srcDir) && !existsSync(dstDir)) {
        try {
          symlinkSync(srcDir, dstDir, "dir");
        } catch {
          // ignore
        }
      }
    }
  }
}

function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const db = openDb();

  if (cmd === "register") {
    const agentId = sanitizeAgentId(flag(args, "--agent"));
    const modelHint = (flag(args, "--model") ?? "frontier-agent").trim();
    verifyPrimaryReposUntouched();

    const agentRoot = join(WORKTREES_ROOT, agentId);
    const jevWt = join(agentRoot, "jev-stageA");
    const awiWt = join(agentRoot, "agentic-workflow-integrity");
    const branchName = `raffle/${agentId}`;

    provisionWorktree(JEV_PRIMARY, jevWt, branchName);
    ensureSymlinkOrCopyJevExtras(jevWt);
    provisionWorktree(AWI_PRIMARY, awiWt, branchName);

    const now = new Date().toISOString();
    db.prepare(
      `INSERT INTO raffle_agents (agent_id, model_hint, jev_worktree, awi_worktree, registered_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(agent_id) DO UPDATE SET
         model_hint = excluded.model_hint,
         jev_worktree = excluded.jev_worktree,
         awi_worktree = excluded.awi_worktree`,
    ).run(agentId, modelHint, jevWt, awiWt, now);

    const jevBase = evaluateWorktree(jevWt, "jev");
    const awiBase = evaluateWorktree(awiWt, "awi");

    console.log(
      JSON.stringify(
        {
          ok: true,
          agentId,
          branch: branchName,
          pythonRunner: `${UV_BIN} run`,
          worktrees: {
            jevStageA: jevWt,
            agenticWorkflowIntegrity: awiWt,
          },
          baselineEval: {
            jevStageA: {
              testsRan: jevBase.testsRan,
              coveragePct: jevBase.coveragePct,
              testLoc: jevBase.testLoc,
              efficiencyScore: jevBase.efficiencyScore,
            },
            agenticWorkflowIntegrity: {
              testsRan: awiBase.testsRan,
              coveragePct: awiBase.coveragePct,
              testLoc: awiBase.testLoc,
              efficiencyScore: awiBase.efficiencyScore,
            },
          },
          mandatoryTracks: VALID_TRACKS,
        },
        null,
        2,
      ),
    );
    return;
  }

  if (cmd === "eval") {
    const agentId = sanitizeAgentId(flag(args, "--agent"));
    verifyPrimaryReposUntouched();
    const row = db
      .prepare("SELECT * FROM raffle_agents WHERE agent_id = ?")
      .get(agentId);
    if (!row) {
      throw new Error(`Agent "${agentId}" is not registered. Run register first.`);
    }
    const jevEval = evaluateWorktree(row.jev_worktree, "jev");
    const awiEval = evaluateWorktree(row.awi_worktree, "awi");
    console.log(
      JSON.stringify(
        {
          ok: Boolean(jevEval.ok && awiEval.ok),
          agentId,
          jevStageA: jevEval,
          agenticWorkflowIntegrity: awiEval,
        },
        null,
        2,
      ),
    );
    return;
  }

  if (cmd === "submit") {
    const agentId = sanitizeAgentId(flag(args, "--agent"));
    const track = (flag(args, "--track") ?? "").trim();
    const title = (flag(args, "--title") ?? "").trim();
    const summaryFile = flag(args, "--summary-file");
    const summaryInline = flag(args, "--summary");
    const citations = (flag(args, "--citations") ?? "").trim();

    if (!VALID_TRACKS.includes(track)) {
      throw new Error(
        `Invalid --track "${track}". Must be one of: ${VALID_TRACKS.join(", ")}`,
      );
    }
    if (title.length < 10) {
      throw new Error("--title must be at least 10 characters.");
    }
    let summaryMarkdown = "";
    if (summaryFile) {
      summaryMarkdown = readFileSync(resolve(summaryFile), "utf8").trim();
    } else if (summaryInline) {
      summaryMarkdown = summaryInline.trim();
    }
    if (summaryMarkdown.length < 250) {
      throw new Error(
        `Submission summary is too short (${summaryMarkdown.length} chars; minimum 250 chars). Provide a detailed synthesis via --summary-file <path.md>.`,
      );
    }

    verifyPrimaryReposUntouched();
    const agentRow = db
      .prepare("SELECT * FROM raffle_agents WHERE agent_id = ?")
      .get(agentId);
    if (!agentRow) {
      throw new Error(`Agent "${agentId}" is not registered. Run register first.`);
    }

    const jevGit = autoCommitWorktree(agentRow.jev_worktree, agentId, track, title);
    const awiGit = autoCommitWorktree(agentRow.awi_worktree, agentId, track, title);
    const jevEval = evaluateWorktree(agentRow.jev_worktree, "jev");
    const awiEval = evaluateWorktree(agentRow.awi_worktree, "awi");

    const now = new Date().toISOString();
    db.prepare(
      `INSERT INTO raffle_submissions (
         agent_id, track, title, summary_markdown, citations_text,
         jev_commit_sha, awi_commit_sha, jev_diff_stat, awi_diff_stat,
         jev_eval_json, awi_eval_json, submitted_at, updated_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(agent_id, track) DO UPDATE SET
         title = excluded.title,
         summary_markdown = excluded.summary_markdown,
         citations_text = excluded.citations_text,
         jev_commit_sha = excluded.jev_commit_sha,
         awi_commit_sha = excluded.awi_commit_sha,
         jev_diff_stat = excluded.jev_diff_stat,
         awi_diff_stat = excluded.awi_diff_stat,
         jev_eval_json = excluded.jev_eval_json,
         awi_eval_json = excluded.awi_eval_json,
         updated_at = excluded.updated_at`,
    ).run(
      agentId,
      track,
      title,
      summaryMarkdown,
      citations,
      jevGit.sha,
      awiGit.sha,
      jevGit.diffStat,
      awiGit.diffStat,
      JSON.stringify(jevEval),
      JSON.stringify(awiEval),
      now,
      now,
    );

    const submittedRows = db
      .prepare(
        "SELECT track, title, jev_commit_sha, awi_commit_sha, updated_at FROM raffle_submissions WHERE agent_id = ? ORDER BY track",
      )
      .all(agentId);
    const submittedTracks = new Set(submittedRows.map((r) => r.track));
    const missingTracks = VALID_TRACKS.filter((t) => !submittedTracks.has(t));

    console.log(
      JSON.stringify(
        {
          ok: true,
          agentId,
          upsertedTrack: track,
          jevCommit: jevGit.sha,
          awiCommit: awiGit.sha,
          jevCoverage: {
            testsRan: jevEval.testsRan,
            coveragePct: jevEval.coveragePct,
            testLoc: jevEval.testLoc,
            efficiencyScore: jevEval.efficiencyScore,
          },
          awiCoverage: {
            testsRan: awiEval.testsRan,
            coveragePct: awiEval.coveragePct,
            testLoc: awiEval.testLoc,
            efficiencyScore: awiEval.efficiencyScore,
          },
          completedTracksCount: submittedTracks.size,
          missingTracks,
          allTracksComplete: missingTracks.length === 0,
        },
        null,
        2,
      ),
    );
    return;
  }

  if (cmd === "status") {
    const agentId = sanitizeAgentId(flag(args, "--agent"));
    verifyPrimaryReposUntouched();
    const agentRow = db
      .prepare("SELECT * FROM raffle_agents WHERE agent_id = ?")
      .get(agentId);
    if (!agentRow) {
      throw new Error(`Agent "${agentId}" is not registered.`);
    }
    const rows = db
      .prepare(
        "SELECT track, title, length(summary_markdown) AS summary_chars, jev_commit_sha, awi_commit_sha, updated_at FROM raffle_submissions WHERE agent_id = ? ORDER BY track",
      )
      .all(agentId);
    const submittedTracks = new Set(rows.map((r) => r.track));
    const missingTracks = VALID_TRACKS.filter((t) => !submittedTracks.has(t));
    const jevEval = evaluateWorktree(agentRow.jev_worktree, "jev");
    const awiEval = evaluateWorktree(agentRow.awi_worktree, "awi");

    console.log(
      JSON.stringify(
        {
          ok: true,
          agentId,
          worktrees: {
            jevStageA: agentRow.jev_worktree,
            agenticWorkflowIntegrity: agentRow.awi_worktree,
          },
          submissions: rows,
          completedTracksCount: submittedTracks.size,
          missingTracks,
          allTracksComplete:
            missingTracks.length === 0 &&
            Boolean(jevEval.ok) &&
            Boolean(awiEval.ok) &&
            jevEval.testsRan > 0 &&
            awiEval.testsRan > 0,
          liveEval: {
            jevStageA: {
              ok: jevEval.ok,
              testsRan: jevEval.testsRan,
              coveragePct: jevEval.coveragePct,
              testLoc: jevEval.testLoc,
              efficiencyScore: jevEval.efficiencyScore,
            },
            agenticWorkflowIntegrity: {
              ok: awiEval.ok,
              testsRan: awiEval.testsRan,
              coveragePct: awiEval.coveragePct,
              testLoc: awiEval.testLoc,
              efficiencyScore: awiEval.efficiencyScore,
              awiBenchmarks: awiEval.awiBenchmarks,
            },
          },
        },
        null,
        2,
      ),
    );
    return;
  }

  console.error(
    `Usage:
  node ${ process.argv[1] } register --agent <agent-id> [--model <model-name>]
  node ${ process.argv[1] } eval     --agent <agent-id>
  node ${ process.argv[1] } submit   --agent <agent-id> --track <TRACK> --title "<title>" --summary-file <path.md> [--citations "<refs>"]
  node ${ process.argv[1] } status   --agent <agent-id>

Tracks (submit all 4; UPSERT supported):
  - JEV_SOTA_AND_DATASETS
  - JEV_SPEED_AND_EFFICACY
  - AWI_DATA_AND_TECHNIQUES
  - AWI_MIN_LOC_MAX_COVERAGE_TESTS`,
  );
  process.exitCode = 2;
}

main();
