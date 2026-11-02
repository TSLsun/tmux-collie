# Test scheduling measurements

`make test` retains the existing Bats default: eight workers when GNU parallel
is installed, otherwise one. `make test JOBS=4` overrides the count. No new
shared default is justified by these observations: suite and stress timings
favor different settings, and hosted runners vary substantially.

## Reproduce

The original `test benchmarks` Actions matrix measured JOBS=1,2,4,8 on
`ubuntu-latest` and `macos-latest`. `files` passes
`--no-parallelize-within-files`; `tests` uses Bats' default parallel scheduling.
At JOBS=1 both modes use the same serial command because Bats rejects parallel
scheduling switches in serial mode. Workflow dispatch is available after the
workflow exists on the repository's default branch; this testing-only PR uses
pull-request label runs instead, as described in the controlled follow-up below.

With Python 3, Bats, GNU parallel, tmux, Git, Bash, zsh and fzf installed:

```sh
python3 scripts/benchmark-tests.py --jobs 4 --mode files --output /tmp/collie-benchmark
```

Each original matrix cell ran 233 suite tests, then three 90-test repetitions of
`metadata.bats`, `agents.bats`, `run.bats`, `restore.bats`, `dash.bats` and
`runs.bats` together. These preserve metadata's 80 simultaneous contenders,
concurrent run-ID allocation, restore races and real-fzf interactions. Every
test retains its assertions, stress intensity and private tmux socket.
Parallel scheduling adds competition from other tests; serial runs still
exercise the tests' internal concurrency.

Artifacts retain runner images, resolved tool versions, the tested merge SHA,
commands and per-test TAP timings. The driver records monotonic wall time,
child user/system CPU time, test count, exit status, skips and failures for each
invocation. Failed invocations, empty TAP or any skip fail the cell; later
repetitions still run. CPU is cumulative across workers and waited descendants,
so it can exceed wall time. Dependency installation and version probes are
excluded. Each setting uses a separate hosted runner, with one full-suite
observation and three stress repetitions on that runner. There is no matched-host
crossover or randomized order. These measurements describe the listed images,
not confidence intervals or guarantees for another machine. Artifacts expire
after 14 days; retain downloads when investigating a result.

## Hosted observations

The [corrected matrix](https://github.com/TSLsun/tmux-collie/actions/runs/41336464151)
measures head `e4a7987` on the exact readiness dependency
`fe4fc6c58f6b857ce2471ed15ec4def3ba7760db`. Download each `benchmark-*` artifact
for `metadata.json`, `results.json`, four timed TAP files and any diagnostics.
All numbers below are measured seconds; stress median/range covers three runs.
Failures/skips sum all four invocations in each cell. Fifteen cells passed;
one failed. All 48 stress repetitions passed, with zero skips across 8,048
test executions (8,047 passed, one failed).

<!-- measured-table -->
| OS | Jobs | Mode | CPUs | Suite wall | Suite user CPU | Suite system CPU | Stress wall median (range) | Failures/skips |
|---|---:|---|---:|---:|---:|---:|---|---|
| macOS | 1 | files | 3 | 253.01 | 128.03 | 100.13 | 143.71 (140.34–159.76) | 0/0 |
| macOS | 1 | tests | 3 | 289.42 | 147.30 | 119.19 | 144.98 (144.31–164.64) | 0/0 |
| macOS | 2 | files | 3 | 124.04 | 115.92 | 77.63 | 78.81 (75.42–79.02) | 0/0 |
| macOS | 2 | tests | 3 | 249.04 | 177.06 | 146.95 | 118.69 (107.54–128.78) | 0/0 |
| macOS | 4 | files | 3 | 136.26 | 150.13 | 120.15 | 91.72 (84.69–110.82) | 0/0 |
| macOS | 4 | tests | 3 | 166.26 | 180.90 | 149.31 | 87.43 (79.07–96.44) | 0/0 |
| macOS | 8 | files | 3 | 144.47 | 173.45 | 142.77 | 97.67 (95.75–103.38) | 0/0 |
| macOS | 8 | tests | 3 | 144.59 | 171.86 | 145.47 | 82.75 (80.53–83.08) | 0/0 |
| Linux | 1 | files | 4 | 134.64 | 75.30 | 115.87 | 79.55 (78.76–81.02) | 0/0 |
| Linux | 1 | tests | 4 | 123.21 | 68.08 | 78.20 | 64.14 (63.28–64.38) | 1/0 |
| Linux | 2 | files | 4 | 92.46 | 83.27 | 130.08 | 65.00 (64.44–65.23) | 0/0 |
| Linux | 2 | tests | 4 | 117.30 | 52.42 | 95.56 | 64.39 (60.97–66.73) | 0/0 |
| Linux | 4 | files | 4 | 72.66 | 91.60 | 131.34 | 59.14 (58.89–59.35) | 0/0 |
| Linux | 4 | tests | 4 | 95.61 | 95.33 | 143.18 | 59.73 (56.76–60.18) | 0/0 |
| Linux | 8 | files | 4 | 78.20 | 100.73 | 145.46 | 59.92 (59.25–60.60) | 0/0 |
| Linux | 8 | tests | 4 | 78.58 | 103.99 | 148.93 | 53.44 (53.15–56.09) | 0/0 |
<!-- end-measured-table -->

The Linux serial `tests` suite failed its concurrent allocation assertion:
captured events contain two `run_started run=1` records for separate windows.
Its three stress repetitions passed. The failure remains part of the data;
the failed suite time is not a clean performance comparison. This benchmark
PR does not change the production allocator or weaken the assertion.

File-level JOBS=4 had the lowest observed Linux suite wall time, while
within-file JOBS=8 had the lowest Linux stress median. This tradeoff does not
establish a single best setting. On the corrected three-CPU macOS runners,
file-level JOBS=2 had the lowest suite wall time and stress median. Each setting
still ran on a different host. A controlled follow-up should run candidate
settings repeatedly on the same runner and investigate allocation correctness
before changing defaults.

The [preliminary matrix](https://github.com/TSLsun/tmux-collie/actions/runs/41334721039)
passed all 16 cells, but its stress set had 78 tests and omitted repeated
`agents.bats` allocation coverage; the full suite included it once. Do not pool
its stress timings with the corrected 90-test repetitions. Its macOS cells
reported three CPUs at JOBS=1/2/4 and five at JOBS=8. For example, within-file
JOBS=8 took 66.59s on five CPUs there and 144.59s on three CPUs in the corrected
run. Even identical serial commands varied: preliminary macOS suite times were
196.19s and 284.67s. Runner label and logical CPU count alone do not control
hardware performance or host contention.

Resolved versions in the retained artifacts:

| Tool / image | Linux | macOS |
|---|---|---|
| Runner image | ubuntu26 / 20261026.180.1 | macos26 / 20261026.0455.2 |
| Bash (`bash --version`) | 5.3.9 | 3.2.57 |
| Bats | 1.13.0 | 1.14.0 |
| GNU parallel | 20240222 | 20260922 |
| tmux | 3.6 | 3.8 |
| Git | 2.56.0 | 2.56.0 |
| fzf | 0.73.0 | 0.74.5 |
| Python | 3.14.4 | 3.15.1 |

OS comparisons therefore include different tool versions as well as hardware.
Linux fzf is pinned to the supported minimum; macOS uses the resolved Homebrew
version. The raw metadata is authoritative if future runs resolve differently.

## Controlled 12/16 follow-up

The current `controlled test benchmarks` workflow runs JOBS=4/8/12/16 in both
scheduling modes sequentially within one Actions job per OS. Four is the earlier
Linux candidate and eight is the existing default. Apply the
`run-controlled-benchmarks` PR label to start a run; remove and reapply it for an
explicit repeat. Documentation pushes do not start another experiment.

Allocation correctness is a prerequisite. The runner records 50 rounds of
32 native `mkdir -v` contenders and a kernel `os.mkdir` control, then verifies
that the held-lock regression fails on the stock allocator. It applies only
the exact candidate patch from draft [PR #81](https://github.com/TSLsun/tmux-collie/pull/81),
`baa40b1dd80918f571bd3e0cc9ef427ca0b03654`, in its disposable workspace. The fixed
regression and 20 repetitions of the unchanged real concurrent-ID test must pass
before timing begins. This does not apply the fix or readiness dependency to main.

Every setting gets two full-suite runs and three unchanged stress runs. A
recorded seed shuffles the first round; the second reverses both setting order
and suite/stress order. A third shuffled round provides another stress run.
The controller verifies test counts, records the exact patch/file hashes and
uses one host identity across all 40 timed blocks per OS. Runner image, CPU
model/count, memory where available, executable paths and tool versions are
retained with the measurements. Expected regression failures are separate from
measured suite/stress failures. Any measured failure, skip or missing test count
fails the experiment and remains in its artifacts.

This is a distinct allocation-fix variant, so its timings must not be pooled
with the original stock-allocation table above. Repeated measurements on a
single runner control hardware differences between settings, while host
contention, thermal effects and cache history can still vary. Completed results are reported below; shared defaults remain unchanged.

## Controlled 12/16 results

[Completed hosted experiment](https://github.com/TSLsun/tmux-collie/actions/runs/41376826676),
harness head `6a50a90`, readiness `fe4fc6c` plus pinned allocation candidate
`baa40b1`: 40 timed invocations per OS, 80 total; 11,808 test executions,
11,806 passes, two failures and zero skips. Each setting has two suites and
three stress repetitions. Linux passed all 40 invocations. macOS completed all
40 with the two failures described below; its measurement job correctly failed.

All Linux settings shared one four-logical-CPU AMD EPYC 7763 VM. All macOS
settings shared one three-logical-CPU Apple M1 (Virtual) / VirtualMac2,1 VM
with 7 GiB reported memory. Hardware and executable/version records are in
`experiment.json`; host identity, counts and patch hashes were checked across
all observations. Tool versions match the table above; the native Linux mkdir
probe additionally resolved uutils coreutils 0.10.0. macOS mkdir has no
`--version` interface, so its OS image and binary path are retained instead.

Times are seconds, in round order. Brackets show observed sample counts.
CPU columns are medians of recorded child user+system CPU; raw JSON retains
user/system separately. This is `RUSAGE_CHILDREN` accounting of waited
descendants, not whole-host accounting; detached tmux daemon CPU may escape it.
`*` marks a failed invocation or a stress group containing one. Its time remains
visible, but failed invocations are excluded from paired speed comparisons.

| OS | Jobs | Mode | Suite walls [observed n] | Stress median (range) [observed n] | Suite child CPU median | Stress child CPU median | Failures/skips |
|---|---:|---|---|---|---:|---:|---|
| Linux | 4 | files | 72.88, 72.63 [2] | 58.52 (57.67–58.62) [3] | 225.04 | 159.30 | 0/0 |
| Linux | 4 | tests | 94.91, 95.94 [2] | 57.51 (57.31–58.32) [3] | 241.20 | 167.09 | 0/0 |
| Linux | 8 | files | 74.12, 74.21 [2] | 57.84 (56.66–57.85) [3] | 233.95 | 163.86 | 0/0 |
| Linux | 8 | tests | 77.67, 77.64 [2] | 53.54 (53.44–54.02) [3] | 253.29 | 177.86 | 0/0 |
| Linux | 12 | files | 76.47, 77.54 [2] | 57.38 (56.32–57.62) [3] | 235.33 | 162.72 | 0/0 |
| Linux | 12 | tests | 77.15, 76.26 [2] | 52.15 (51.62–52.93) [3] | 260.51 | 176.17 | 0/0 |
| Linux | 16 | files | 76.38, 77.52 [2] | 56.85 (56.20–57.86) [3] | 233.86 | 162.74 | 0/0 |
| Linux | 16 | tests | 77.67, 78.88 [2] | 51.65 (51.21–51.88) [3] | 266.79 | 175.72 | 0/0 |
| macOS | 4 | files | 128.65, 114.95 [2] | 82.43 (78.59–87.72) [3] | 248.03 | 142.50 | 0/0 |
| macOS | 4 | tests | 142.72, 143.05 [2] | 84.61 (72.24–91.76) [3] | 284.95 | 166.08 | 0/0 |
| macOS | 8 | files | 87.73, 119.78 [2] | 86.40 (61.29–88.36) [3] | 221.63 | 160.74 | 0/0 |
| macOS | 8 | tests | 133.70*, 116.05 [2] | 75.84 (70.43–78.58) [3] | 276.02 | 164.25 | 1/0 |
| macOS | 12 | files | 115.02, 128.32 [2] | 72.33 (69.98–92.28) [3] | 248.41 | 129.07 | 0/0 |
| macOS | 12 | tests | 125.09, 117.76 [2] | 70.13 (60.42–79.15) [3] | 269.20 | 152.15 | 0/0 |
| macOS | 16 | files | 137.40, 147.04 [2] | 87.56 (75.70–92.14) [3] | 288.25 | 163.55 | 0/0 |
| macOS | 16 | tests | 150.83, 121.83 [2] | 75.23 (71.22–76.66) [3]* | 303.36 | 166.73 | 1/0 |

Retain the existing default of eight workers and existing scheduling mode.
On Linux, within-file JOBS=12 reduced suite wall time only 0.66%/1.77% while
increasing recorded child CPU 3.15%/2.56%. JOBS=16 was effectively equal/1.60%
slower, with 4.54%/6.12% more recorded child CPU. Stress medians improved from
53.54s at eight to 52.15s at twelve and 51.65s at sixteen, a modest workload-
specific gain rather than a full-suite improvement.

The only clean paired macOS within-file suite round was slower at twelve
(117.76s versus 116.05s, +1.48%) and sixteen (121.83s, +4.99%). File-only
JOBS=12/16 suites were slower than file-only eight in both rounds. Stress
results vary by setting and time; file-only stress has six schedulable files,
so worker counts above six do not add file concurrency there. One VM controls
hardware differences between settings, but host contention and runtime timing
still vary. Two suite samples and three stress samples do not establish a
universal optimum.

Both macOS failures remain part of the result: JOBS=8 within-file suite round
one failed the Codex session-identity readiness assertion; JOBS=16 within-file
stress round three failed Gemini's working-to-idle readiness assertion. Neither
is a duplicate run-ID failure. No assertion, deadline or stress intensity was
weakened to obtain passing data, and these measurements were not retried.

Allocation investigation observed 17 native status-0/no-receipt mkdir exits
in 50 rounds of 32 contenders on Linux, and zero on macOS; both kernel controls
had exactly one winner each round. Stock held-lock regressions failed as
expected; the pinned candidate passed them. All 120 real concurrent-ID checks
passed: 20 preflight repetitions plus 40 timed checks per OS. These are bounded
correctness observations, not a guarantee that all readiness races are fixed.
The independent production fix remains draft in PR #81; benchmark/readiness
PRs remain unmerged pending explicit human authorization.
