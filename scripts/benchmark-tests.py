#!/usr/bin/env python3
"""Measure Bats on a hosted runner; retain TAP and machine-readable observations."""
import argparse
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--jobs', type=int, choices=(1, 2, 4, 8), required=True)
parser.add_argument('--mode', choices=('files', 'tests'), required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)


def resolved(command):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return {'command': command, 'status': result.returncode, 'output': result.stdout.strip()}


metadata = {
    'sha': resolved(['git', 'rev-parse', 'HEAD']),
    'platform': platform.platform(), 'cpu_count': os.cpu_count(),
    'runner': {key: os.environ.get(key) for key in
               ('RUNNER_OS', 'RUNNER_ARCH', 'ImageOS', 'ImageVersion',
                'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')},
    'jobs': args.jobs, 'mode': args.mode,
    'versions': [resolved(command) for command in
                 (['bash', '--version'], ['bats', '--version'], ['parallel', '--version'],
                  ['tmux', '-V'], ['git', '--version'], ['fzf', '--version'],
                  ['python3', '--version'])],
}
(args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
base = ['bats', '--tap', '--timing', '--print-output-on-failure', '--jobs', str(args.jobs)]
# Bats rejects parallel scheduling flags for a serial run. Both serial
# cells intentionally execute the same baseline command.
if args.mode == 'files' and args.jobs > 1:
    base.append('--no-parallelize-within-files')
env = dict(os.environ, BATS_TEST_TIMEOUT='120')
results = []
failed = False
# Whole files keep concurrent allocation, metadata's 80 contenders, restore
# races and both real-fzf dashboard tests intact and in competition.
stress = ['test/metadata.bats', 'test/run.bats', 'test/restore.bats',
          'test/dash.bats', 'test/runs.bats']
for label, files in [('suite', ['test/'])] + [
        (f'stress-{attempt}', stress) for attempt in range(1, 4)]:
    command = base + files
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with (args.output / f'{label}.tap').open('w') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=env)
    wall = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    lines = (args.output / f'{label}.tap').read_text().splitlines()
    tests = [line for line in lines if line.startswith(('ok ', 'not ok '))]
    observation = {
        'label': label, 'command': command, 'exit_status': result.returncode,
        'wall_seconds': wall, 'user_cpu_seconds': after.ru_utime - before.ru_utime,
        'system_cpu_seconds': after.ru_stime - before.ru_stime,
        'tests': len(tests), 'failures': sum(line.startswith('not ok ') for line in tests),
        'skips': sum('# skip' in line.lower() for line in tests),
    }
    results.append(observation)
    print(json.dumps(observation), flush=True)
    (args.output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    failed |= result.returncode != 0 or observation['skips'] != 0 or not tests
raise SystemExit(1 if failed else 0)
