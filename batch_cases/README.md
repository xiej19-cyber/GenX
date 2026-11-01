# Sequential GenX case runner

Place any number of complete case folders inside this directory. The script runs them in alphabetical order with Gurobi. It does not use each case's `Run.jl`.

On the Linux workstation:

```bash
python3 /path/to/batchcases/run_batch.py --genx /path/to/GenX --dry-run
python3 /path/to/batchcases/run_batch.py --genx /path/to/GenX
```

If the cases are in another folder, add `--queue /path/to/cases`. Julia must be on `PATH`, or pass `--julia /path/to/julia`.

Successful cases get a `.batch_done` file and are skipped on subsequent runs. To rerun one, delete its `.batch_done` file. Solver output appears in the terminal and is also saved under `_logs/`. The script stops on the first error, so the error is visible immediately; run it again after fixing the problem to continue.
