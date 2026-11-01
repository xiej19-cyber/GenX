#!/usr/bin/env python3
"""Run every unfinished GenX case in a folder, sequentially with Gurobi."""

import argparse
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue", type=Path, default=HERE)
    parser.add_argument("--genx", type=Path, default=HERE.parent)
    parser.add_argument("--julia", default=os.environ.get("JULIA", "julia"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    queue = args.queue.resolve()
    genx = args.genx.resolve()
    cases = sorted(
        (p for p in queue.iterdir()
         if p.is_dir() and (p / "settings" / "genx_settings.yml").is_file()),
        key=lambda p: p.name.casefold(),
    )
    print(f"Found {len(cases)} cases in {queue}", flush=True)

    for case in cases:
        done = case / ".batch_done"
        if done.exists():
            print(f"SKIP {case.name}", flush=True)
            continue
        if args.dry_run:
            print(f"WOULD RUN {case.name}", flush=True)
            continue

        logs = queue / "_logs"
        logs.mkdir(exist_ok=True)
        log = logs / f"{case.name}.{datetime.now():%Y%m%d_%H%M%S}.log"
        command = [args.julia, f"--project={genx}", str(HERE / "run_one.jl"), str(case)]
        print(f"RUN {case.name} (log: {log})", flush=True)
        try:
            with log.open("w", encoding="utf-8") as output:
                process = subprocess.Popen(command, cwd=genx, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True,
                                           errors="replace", bufsize=1)
                for line in process.stdout:
                    print(line, end="", flush=True)
                    output.write(line)
                code = process.wait()
        except OSError as exc:
            print(f"Cannot start Julia: {exc}", flush=True)
            return 1

        if code != 0:
            print(f"STOP: {case.name} failed (exit {code}); see {log}", flush=True)
            return code
        done.write_text(datetime.now().isoformat(timespec="seconds") + "\n")
        print(f"DONE {case.name}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped; run again to resume.")
        sys.exit(130)
