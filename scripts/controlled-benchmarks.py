#!/usr/bin/env python3
"""Gate allocator correctness, then compare settings sequentially on one runner."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import random
import resource
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

READINESS = 'fe4fc6c58f6b857ce2471ed15ec4def3ba7760db'
PATCH_PATHS = ['lib/cmd/agents.sh', 'test/run_lock.bats']


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def git(*args):
    return subprocess.check_output(['git', *args])


def schedule(seed, workers):
    order = list(itertools.product(workers, ('files', 'tests')))
    random.Random(seed).shuffle(order)
    plan = []
    # Reverse both settings and phase order in round two to counterbalance
    # early/late position. Round three supplies the third stress observation.
    for round_number, settings, phases in (
            (1, order, ('suite', 'stress')),
            (2, list(reversed(order)), ('stress', 'suite'))):
        for jobs, mode in settings:
            for phase in phases:
                plan.append(dict(round=round_number, jobs=jobs, mode=mode, phase=phase))
    extra = order[:]
    random.Random(seed + 1).shuffle(extra)
    for jobs, mode in extra:
        plan.append(dict(round=3, jobs=jobs, mode=mode, phase='stress'))
    return plan


def observe(command, output, env, timeout=None):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with output.open('w') as stream:
        try:
            status = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                    env=env, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            status = 124
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    text = output.read_text()
    tests = [line for line in text.splitlines() if line.startswith(('ok ', 'not ok '))]
    result = dict(command=command, exit_status=status,
                  wall_seconds=time.monotonic() - start,
                  user_cpu_seconds=after.ru_utime - before.ru_utime,
                  system_cpu_seconds=after.ru_stime - before.ru_stime,
                  tests=len(tests), failures=sum(line.startswith('not ok ') for line in tests),
                  skips=sum('# skip' in line.lower() for line in tests))
    write_json(output.with_suffix('.json'), result)
    return result


def native_mkdir_probe(output, rounds=50, contenders=32):
    """Compare native utility status/receipts with the kernel's exclusive create."""
    observations = []
    with tempfile.TemporaryDirectory(dir=output) as directory:
        root = Path(directory)
        with ThreadPoolExecutor(max_workers=contenders) as pool:
            for attempt in range(rounds):
                barrier = threading.Barrier(contenders)
                lock = root / f'native-{attempt}'

                def native(_):
                    barrier.wait()
                    result = subprocess.run(['mkdir', '-v', str(lock)],
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    return dict(status=result.returncode, receipt=bool(result.stdout))

                native_results = list(pool.map(native, range(contenders)))
                barrier = threading.Barrier(contenders)
                kernel_lock = root / f'kernel-{attempt}'

                def kernel(_):
                    barrier.wait()
                    try:
                        os.mkdir(kernel_lock)
                        return True
                    except FileExistsError:
                        return False

                kernel_winners = sum(pool.map(kernel, range(contenders)))
                assert kernel_winners == 1, 'kernel control did not have exactly one winner'
                observations.append(dict(round=attempt + 1, contenders=contenders,
                                         native=native_results, kernel_winners=kernel_winners))
                # Persist each round so a later infrastructure failure keeps evidence.
                write_json(output / 'native-mkdir.json', observations)
    return sum(sum(row['status'] == 0 and not row['receipt'] for row in item['native'])
               for item in observations)


def correctness_gate(output, fix, env):
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', 'merge-base', '--is-ancestor', READINESS, 'HEAD'], check=True)
    subprocess.run(['git', 'diff', '--exit-code', READINESS, 'HEAD', '--',
                    'lib', 'agents', 'bin', 'test', 'collie.tmux'], check=True)
    changed = git('diff', '--name-only', fix + '^', fix).decode().splitlines()
    if sorted(changed) != sorted(PATCH_PATHS):
        raise RuntimeError(f'unexpected candidate patch paths: {changed}')
    patch = git('diff', '--binary', fix + '^', fix, '--', *PATCH_PATHS)
    (output / 'allocation-candidate.patch').write_bytes(patch)
    proof = dict(readiness=READINESS, head=git('rev-parse', 'HEAD').decode().strip(),
                 allocation_fix=fix, patch_sha256=hashlib.sha256(patch).hexdigest(),
                 stock_code_matches_readiness=True)
    write_json(output / 'provenance.json', proof)
    proof['native_false_successes'] = native_mkdir_probe(output)
    regression = Path('test/run_lock.bats')
    if regression.exists():
        raise RuntimeError('stock checkout already has the candidate regression')
    regression.write_bytes(git('show', fix + ':test/run_lock.bats'))
    try:
        stock = observe(['bats', '--tap', '--timing', str(regression)],
                        output / 'regression-stock.tap', env, timeout=180)
        if not (stock['exit_status'] == 1 and stock['tests'] == 1
                and stock['failures'] == 1 and stock['skips'] == 0
                and 'timed out waiting for' in (output / 'regression-stock.tap').read_text()):
            raise RuntimeError('stock allocator did not fail the expected regression assertion')
    finally:
        regression.unlink()
    subprocess.run(['git', 'apply', '--check', '-'], input=patch, check=True)
    subprocess.run(['git', 'apply', '-'], input=patch, check=True)
    proof['patched_files'] = {}
    for name in PATCH_PATHS:
        actual = Path(name).read_bytes()
        if actual != git('show', fix + ':' + name):
            raise RuntimeError(f'patched file does not equal pinned candidate: {name}')
        proof['patched_files'][name] = hashlib.sha256(actual).hexdigest()
    write_json(output / 'provenance.json', proof)
    fixed = observe(['bats', '--tap', '--timing', str(regression)],
                    output / 'regression-fixed.tap', env, timeout=180)
    if fixed['exit_status'] or fixed['tests'] != 1 or fixed['skips'] or fixed['failures']:
        raise RuntimeError('fixed allocator failed isolated regression')
    for attempt in range(1, 21):
        result = observe(['bats', '--tap', '--timing', '--filter',
                          '^concurrent runs get distinct IDs', 'test/agents.bats'],
                         output / f'concurrent-{attempt:02}.tap', env, timeout=180)
        if result['exit_status'] or result['tests'] != 1 or result['skips'] or result['failures']:
            raise RuntimeError(f'fixed concurrent allocation failed preflight repetition {attempt}')
    proof['stock_regression_status'] = stock['exit_status']
    proof['fixed_regression_status'] = fixed['exit_status']
    proof['concurrent_preflight_passes'] = 20
    write_json(output / 'provenance.json', proof)
    print(json.dumps(dict(correctness='passed', native_false_successes=proof['native_false_successes'],
                          concurrent_preflight_passes=20)), flush=True)


def prepare(args):
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise RuntimeError('output directory must be empty to preserve earlier evidence')
    metadata = dict(host_id=str(uuid.uuid4()), seed=args.seed, cpu_count=os.cpu_count(),
                    platform=platform.platform(), runner_name=os.environ.get('RUNNER_NAME'),
                    run_id=os.environ.get('GITHUB_RUN_ID'), workers=args.jobs,
                    head=git('rev-parse', 'HEAD').decode().strip(), readiness=READINESS,
                    allocation_fix=args.allocation_fix, schedule=schedule(args.seed, args.jobs),
                    runner_image={key: os.environ.get(key) for key in
                                  ('ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH',
                                   'GITHUB_RUN_ATTEMPT')})
    commands = [['bash', '--version'], ['bats', '--version'], ['parallel', '--version'],
                ['tmux', '-V'], ['git', '--version'], ['fzf', '--version'],
                ['python3', '--version'], ['mkdir', '--version']]
    commands += ([['sysctl', '-n', 'machdep.cpu.brand_string'],
                  ['sysctl', '-n', 'hw.model', 'hw.memsize']]
                 if platform.system() == 'Darwin' else [['lscpu']])
    metadata['resolved_tools_and_hardware'] = []
    for command in commands:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        binary = shutil.which(command[0])
        metadata['resolved_tools_and_hardware'].append(dict(
            command=command, path=binary, realpath=os.path.realpath(binary) if binary else None,
            status=result.returncode, output=result.stdout.strip()))
    write_json(args.output / 'experiment.json', metadata)
    env = runner_env(metadata)
    correctness_gate(args.output / 'correctness', args.allocation_fix, env)
    stress_files = ['test/metadata.bats', 'test/agents.bats', 'test/run.bats',
                    'test/restore.bats', 'test/dash.bats', 'test/runs.bats']
    metadata['expected_tests'] = {
        'suite': int(subprocess.check_output(['bats', '--count', 'test/'], env=env)),
        'stress': int(subprocess.check_output(['bats', '--count', *stress_files], env=env)),
    }
    write_json(args.output / 'experiment.json', metadata)
    return metadata


def runner_env(metadata):
    return dict(os.environ, BATS_TEST_TIMEOUT='120',
                COLLIE_BENCHMARK_HOST_ID=metadata['host_id'],
                COLLIE_BENCHMARK_VARIANT='allocation-receipt-candidate',
                COLLIE_ALLOCATION_FIX_SHA=metadata['allocation_fix'],
                COLLIE_READINESS_SHA=metadata['readiness'])


def valid_observation(item):
    rows = item['observations']
    return (item['driver_status'] == 0 and len(rows) == 1
            and all(row['exit_status'] == 0 and row['failures'] == 0 and row['skips'] == 0
                    and row['tests'] == item['expected_tests'] for row in rows))


def check_experiment(metadata, observations):
    expected = {f"{i:02}-r{x['round']}-j{x['jobs']}-{x['mode']}-{x['phase']}"
                for i, x in enumerate(metadata['schedule'], 1)}
    actual = [item['block'] for item in observations]
    complete = len(actual) == len(set(actual)) and set(actual) == expected
    failed = sum(not valid_observation(item) for item in observations)
    summary = dict(expected_blocks=len(expected), observed_blocks=len(actual),
                   complete=complete, failed_blocks=failed)
    print(json.dumps(summary), flush=True)
    return complete and failed == 0, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allocation-fix', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=20261102)
    parser.add_argument('--jobs', type=int, nargs='+', choices=(1, 2, 4, 8, 12, 16),
                        default=[4, 8, 12, 16])
    parser.add_argument('--stage', choices=('all', 'prepare', '1', '2', '3', 'check'), default='all')
    args = parser.parse_args()
    if len(set(args.jobs)) != len(args.jobs):
        parser.error('worker counts must be unique')
    if len(args.allocation_fix) != 40 or any(c not in '0123456789abcdef' for c in args.allocation_fix):
        parser.error('allocation fix must be an exact lowercase commit SHA')
    if args.stage in ('all', 'prepare'):
        metadata = prepare(args)
        if args.stage == 'prepare':
            return
    else:
        metadata = json.loads((args.output / 'experiment.json').read_text())
        if (metadata['allocation_fix'] != args.allocation_fix or metadata['workers'] != args.jobs
                or metadata['seed'] != args.seed or metadata['run_id'] != os.environ.get('GITHUB_RUN_ID')
                or metadata['head'] != git('rev-parse', 'HEAD').decode().strip()
                or metadata['runner_name'] != os.environ.get('RUNNER_NAME')):
            raise RuntimeError('experiment arguments, checkout or runner changed between stages')
        proof = json.loads((args.output / 'correctness/provenance.json').read_text())
        if proof.get('concurrent_preflight_passes') != 20:
            raise RuntimeError('correctness preflight is incomplete')
        for name, digest in proof['patched_files'].items():
            if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
                raise RuntimeError(f'candidate file changed between stages: {name}')
    records_path = args.output / 'observations.json'
    observations = json.loads(records_path.read_text()) if records_path.exists() else []
    if args.stage == 'check':
        passed, summary = check_experiment(metadata, observations)
        write_json(args.output / 'summary.json', summary)
        raise SystemExit(0 if passed else 1)
    env = runner_env(metadata)
    failed = False
    for index, item in enumerate(metadata['schedule'], 1):
        if args.stage != 'all' and item['round'] != int(args.stage):
            continue
        block = f"{index:02}-r{item['round']}-j{item['jobs']}-{item['mode']}-{item['phase']}"
        destination = args.output / block
        if destination.exists() or any(row['block'] == block for row in observations):
            raise RuntimeError(f'refusing to overwrite prior observation: {block}')
        block_env = dict(env, COLLIE_BENCHMARK_BLOCK=block)
        command = ['python3', 'scripts/benchmark-tests.py', '--jobs', str(item['jobs']),
                   '--mode', item['mode'], '--phase', item['phase'],
                   '--stress-repetitions', '1', '--output', str(destination)]
        result = subprocess.run(command, env=block_env)
        block_records_path = destination / 'results.json'
        records = json.loads(block_records_path.read_text()) if block_records_path.exists() else []
        observation = dict(block=block, **item, driver_status=result.returncode,
                           expected_tests=metadata['expected_tests'][item['phase']], observations=records)
        observations.append(observation)
        write_json(records_path, observations)
        print(json.dumps(observation), flush=True)
        failed |= not valid_observation(observation)
        block_metadata = json.loads((destination / 'metadata.json').read_text())
        if block_metadata['runner']['COLLIE_BENCHMARK_HOST_ID'] != metadata['host_id']:
            raise RuntimeError('measurement host identity changed')
    if args.stage == 'all':
        passed, summary = check_experiment(metadata, observations)
        write_json(args.output / 'summary.json', summary)
        failed |= not passed
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()
