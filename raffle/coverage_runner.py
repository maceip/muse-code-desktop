#!/usr/bin/env python3
"""
Zero-dependency deterministic Python test + line/branch coverage + test-LOC evaluator.
Uses Python's built-in `trace` / AST inspection to measure exact executable statements
and covered statements across target source files while running `unittest` discovery.
"""
import ast
import io
import json
import os
import sys
import threading
import time
import trace
import unittest


def count_non_trivial_loc(file_path: str) -> int:
    """Count physical lines excluding blank lines, comment-only lines, and docstring-only lines."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            source = f.read()
    except OSError:
        return 0

    docstring_lines = set()
    try:
        tree = ast.parse(source, filename=file_path)
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                if (
                    node.body
                    and isinstance(node.body[0], ast.Expr)
                    and isinstance(node.body[0].value, ast.Constant)
                    and isinstance(node.body[0].value.value, str)
                ):
                    expr = node.body[0]
                    for ln in range(expr.lineno, (expr.end_lineno or expr.lineno) + 1):
                        docstring_lines.add(ln)
    except SyntaxError:
        pass

    loc = 0
    for idx, raw in enumerate(source.splitlines(), start=1):
        if idx in docstring_lines:
            continue
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        loc += 1
    return loc


def executable_lines_for_file(file_path: str) -> set[int]:
    """Return executable statement line numbers in a Python file using AST + trace.find_executable_linenos."""
    try:
        linenos = {
            ln
            for ln in trace._find_executable_linenos(file_path).keys()
            if isinstance(ln, int) and ln > 0
        }
    except Exception:
        linenos = set()

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            source = f.read()
        tree = ast.parse(source, filename=file_path)
        doc_lines = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                if (
                    node.body
                    and isinstance(node.body[0], ast.Expr)
                    and isinstance(node.body[0].value, ast.Constant)
                    and isinstance(node.body[0].value.value, str)
                ):
                    expr = node.body[0]
                    for ln in range(expr.lineno, (expr.end_lineno or expr.lineno) + 1):
                        doc_lines.add(ln)
        linenos -= doc_lines
    except Exception:
        pass
    return linenos


def main() -> int:
    if len(sys.argv) < 3:
        print(json.dumps({"error": "usage: coverage_runner.py <repo_root> <project_kind: awi|jev>"}))
        return 2

    repo_root = os.path.abspath(sys.argv[1])
    project_kind = sys.argv[2]
    sys.path.insert(0, repo_root)
    os.chdir(repo_root)

    if project_kind == "awi":
        target_dirs = [os.path.join(repo_root, "awi")]
        target_files = []
        for d in target_dirs:
            if os.path.isdir(d):
                for root, _, files in os.walk(d):
                    for fn in sorted(files):
                        if fn.endswith(".py") and fn != "__init__.py":
                            target_files.append(os.path.abspath(os.path.join(root, fn)))
    else:
        # jev-stageA core offline modules
        candidates = [
            "score.py",
            "replay.py",
            "analyze.py",
            "defenses.py",
            "attacks_ood.py",
            "adaptive.py",
            "report.py",
            "make_paraphrases.py",
            "verify_corpus.py",
        ]
        target_files = [
            os.path.abspath(os.path.join(repo_root, c))
            for c in candidates
            if os.path.isfile(os.path.join(repo_root, c))
        ]

    test_dir = os.path.join(repo_root, "tests")
    test_files = []
    if os.path.isdir(test_dir):
        for root, _, files in os.walk(test_dir):
            for fn in sorted(files):
                if fn.endswith(".py") and fn != "__init__.py":
                    test_files.append(os.path.abspath(os.path.join(root, fn)))

    total_test_loc = sum(count_non_trivial_loc(tf) for tf in test_files)

    if not test_files:
        total_exec = sum(len(executable_lines_for_file(f)) for f in target_files)
        print(
            json.dumps(
                {
                    "ok": True,
                    "testsRan": 0,
                    "testsFailed": 0,
                    "testsErrors": 0,
                    "testFiles": 0,
                    "testLoc": 0,
                    "executableLines": total_exec,
                    "coveredLines": 0,
                    "coveragePct": 0.0,
                    "efficiencyScore": 0.0,
                    "perFile": {},
                }
            )
        )
        return 0

    tracer = trace.Trace(count=1, trace=0, ignoredirs=[sys.prefix, sys.exec_prefix])
    threading.settrace(tracer.globaltrace)
    stream = io.StringIO()
    start_t = time.time()

    def run_suite():
        loader = unittest.TestLoader()
        suite = loader.discover(start_dir="tests", pattern="test*.py")
        runner = unittest.TextTestRunner(stream=stream, verbosity=2)
        return runner.run(suite)

    try:
        result = tracer.runfunc(run_suite)
    finally:
        threading.settrace(None)
    elapsed_ms = round((time.time() - start_t) * 1000, 2)
    results_counts = tracer.results().counts

    per_file = {}
    total_exec = 0
    total_cov = 0

    for tf in target_files:
        exec_lines = executable_lines_for_file(tf)
        covered = {ln for ln in exec_lines if results_counts.get((tf, ln), 0) > 0}
        missed = sorted(exec_lines - covered)
        n_exec = len(exec_lines)
        n_cov = len(covered)
        total_exec += n_exec
        total_cov += n_cov
        rel = os.path.relpath(tf, repo_root)
        per_file[rel] = {
            "executable": n_exec,
            "covered": n_cov,
            "pct": round((n_cov / n_exec * 100.0) if n_exec else 100.0, 2),
            "missedSample": missed[:15],
        }

    coverage_pct = round((total_cov / total_exec * 100.0) if total_exec else 0.0, 2)
    failures = len(result.failures)
    errors = len(result.errors)
    skipped = len(result.skipped)
    ok = failures == 0 and errors == 0 and result.testsRun > 0

    # Efficiency metric: rewards high coverage AND compact test LOC.
    # (coverage_pct^2) / max(40, test_loc) so e.g. 90% coverage in 120 LOC = 67.5,
    # whereas 90% coverage in 600 LOC = 13.5, and 30% coverage in 40 LOC = 22.5.
    efficiency_score = (
        round(((coverage_pct ** 2) / max(40, total_test_loc)), 2) if ok else 0.0
    )

    print(
        json.dumps(
            {
                "ok": ok,
                "elapsedMs": elapsed_ms,
                "testsRan": result.testsRun,
                "testsFailed": failures,
                "testsErrors": errors,
                "testsSkipped": skipped,
                "testFiles": len(test_files),
                "testLoc": total_test_loc,
                "executableLines": total_exec,
                "coveredLines": total_cov,
                "coveragePct": coverage_pct,
                "efficiencyScore": efficiency_score,
                "perFile": per_file,
                "runnerOutputTail": stream.getvalue()[-1200:] if not ok else "",
            }
        )
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
