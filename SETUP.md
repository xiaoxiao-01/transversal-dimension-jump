# Environment setup (macOS)

`notebooks/0_code_generation.ipynb` needs **SageMath + GAP + the QDistRnd GAP
package** (plus Guava, which QDistRnd depends on). The other notebooks only need
the PyPI packages.

> **Note on `requirements_py312.txt`:** that file is a `pip freeze` taken from
> inside a SageMath install — roughly half its lines point to local
> `file:///.../sage-10.5-current/...` wheels that don't exist on your machine.
> **Do not** `pip install -r requirements_py312.txt`. Use the script below, which
> gets Sage from conda and installs only the extra packages on top.

## One-command setup

On a fresh Mac (with [Homebrew](https://brew.sh) installed), from the repo root:

```bash
bash setup_macos_env.sh
```

This is idempotent — safe to re-run; it skips anything already done. It will:

1. Install **Miniforge** (conda/mamba) via Homebrew.
2. Create the **`tdj`** conda env: SageMath 10.5 + GAP + Python 3.12.
3. Install the QEC PyPI packages (`bposd`, `ldpc`, `stim`, `PyMatching`,
   `beliefmatching`, `sinter`, `numba`, `joblib`) into the env — via `uv` if
   present, else `pip`.
4. Clone **QDistRnd**, **AutoDoc**, and **Guava** into `~/.gap/pkg/` and compile
   Guava from source.
5. Write `~/.gap/gaprc` with a small fix (see below).
6. Register a Jupyter kernel **"Python (tdj / Sage 10.5)"**.
7. Verify the whole stack by building a code and running a QDistRnd distance
   estimate.

## Running the notebook in VSCode

1. Open `notebooks/0_code_generation.ipynb`.
2. Kernel picker (top-right) → **Select Another Kernel** → **Jupyter Kernel** →
   **Python (tdj / Sage 10.5)**.
3. Run all cells.

## What lives where

- **In the repo (travels via git):** `setup_macos_env.sh`, this file, `.gitattributes`,
  and the notebook edit that comments out the broken `SetPackagePath(...)` placeholder
  in cell 1 (QDistRnd is auto-discovered from `~/.gap/pkg`, so the line isn't needed).
- **Machine-local (the script recreates these):** the `tdj` conda env, the GAP
  packages under `~/.gap/pkg/`, `~/.gap/gaprc`, the Jupyter kernelspec, and the
  per-clone `filter.nbstripout.*` git config.

## Clean notebook diffs (nbstripout)

The setup configures [`nbstripout`](https://github.com/kynan/nbstripout) as a git
clean filter so that merely **running cells doesn't dirty the notebook in git** —
the volatile `execution_count` is stripped from what git sees. Cell **outputs are
kept** (`--keep-output`), since this repo ships the printed code parameters as
results. Your on-disk notebook is untouched; only git's view is normalized.

`.gitattributes` is committed, but the filter config in `.git/config` is per-clone.
The setup script sets it; if you ever set it up by hand, the key is:

```bash
git config filter.nbstripout.clean '"<env>/bin/python" -m nbstripout --keep-output'
```

(Note: `nbstripout --install --keep-output` does *not* persist `--keep-output` into
the clean command — it must be set explicitly, as the script does.)

## Why the `~/.gap/gaprc` fix is needed

Guava references three functions from GAP's optional `design` package
(`FpfAutomorphismGroupsCyclic`, `DesignFromFerreroPair`, `IncidenceMat`). With
`design` not installed, GAP prints "Unbound global variable" *syntax warnings*
when it parses Guava. Those warnings are harmless in plain GAP, but Sage's `gap`
pexpect interface treats **any** stderr output as a fatal error — so
`LoadPackage("QDistRnd")` fails *through Sage* even though it works in raw GAP.
The `gaprc` pre-binds those three names so the parser sees them as defined and
stays silent. (Installing the `design` package would also fix it, but it pulls in
`grape` → `nauty`, a much larger compile.)

## Why the kernel launches through `sage`

The registered kernel's `kernel.json` runs `sage --python -m ipykernel_launcher`, not
the bare env `python`. `from sage.all import *` shells out to helper binaries
(`Singular`, `gap`, …) that live in the env's `bin/`, and only the `sage` wrapper
puts that directory plus Sage's environment variables on `PATH`. Launching the bare
python fails on the first cell with `Singular not found on PATH`. It uses plain
`ipykernel_launcher` (not `sage.repl.ipython_kernel`) so cells run as ordinary
Python — the Sage preparser, which rewrites `^`, integer literals, etc., is *not*
applied. (There is also a separate conda-provided **"SageMath 10.5"** kernel that
*does* preparse; don't use it for these notebooks.)

## Manual fallback

If you prefer to run the steps by hand, they're each a labelled section in
`setup_macos_env.sh`.
