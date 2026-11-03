#!/usr/bin/env python3
"""Time PTY producer writes, not final on-screen presentation or typing latency.

Run this same command in each terminal. Use an isolated fixture and matched
scrollback settings. Reports are local; this script performs no network calls.
"""
import argparse
import hashlib
import json
import os
import resource
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lines', type=int, default=200_000)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.lines <= 1_000_000:
        parser.error('--lines must be between 1 and 1000000')
    if not os.isatty(1):
        parser.error('stdout must be the terminal being measured')
    size = os.get_terminal_size(1)
    data = ''.join(f'{i:06d} ' + 'abcdefghijklmnopqrstuvwxyz 0123456789'.ljust(73) + '\n'
                   for i in range(args.lines)).encode('ascii')
    digest = hashlib.sha256(data).hexdigest()
    before = resource.getrusage(resource.RUSAGE_SELF)
    start = time.perf_counter()
    remaining = memoryview(data)
    while remaining:
        written = os.write(1, remaining[:65536])
        remaining = remaining[written:]
    elapsed = time.perf_counter() - start
    after = resource.getrusage(resource.RUSAGE_SELF)
    report = {'scope': 'producer PTY write/flush throughput; excludes final presentation',
              'lines': args.lines, 'bytes': len(data), 'sha256': digest,
              'columns': size.columns, 'rows': size.lines, 'seconds': elapsed,
              'producerCPUSeconds': after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
              'MiBPerSecond': len(data) / 1048576 / elapsed}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('\r\nBENCHMARK OUTPUT COMPLETE', flush=True)


if __name__ == '__main__':
    main()
