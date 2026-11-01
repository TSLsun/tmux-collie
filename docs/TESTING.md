# Test scheduling measurements

`make test` retains the existing Bats default: eight workers when GNU parallel
is installed, otherwise one. `make test JOBS=4` overrides the count. No new
shared default is justified by these observations: suite and stress timings
favor different settings, and hosted runners vary substantially.

## Reproduce

The `test benchmarks` Actions workflow measures JOBS=1,2,4,8 on
`ubuntu-latest` and `macos-latest`. `files` passes
`--no-parallelize-within-files`; `tests` uses Bats' default parallel scheduling.
At JOBS=1 both modes use the same serial command because Bats rejects parallel
scheduling switches in serial mode. Workflow dispatch is available after the
workflow exists on the repository's default branch; this testing-only PR uses
pull-request runs instead.

With Python 3, Bats, GNU parallel, tmux, Git, Bash, zsh and fzf installed:

```sh
python3 scripts/benchmark-tests.py --jobs 4 --mode files --output /tmp/collie-benchmark
```

Each cell runs 233 suite tests, then three 90-test repetitions of
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
