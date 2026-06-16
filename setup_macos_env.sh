#!/usr/bin/env bash
#
# setup_macos_env.sh — reproduce the SageMath/GAP/QDistRnd environment needed by
# notebooks/0_code_generation.ipynb on a fresh macOS machine.
#
# What it does:
#   1. Installs Miniforge (conda/mamba) via Homebrew if missing.
#   2. Creates the `tdj` conda env: SageMath 10.5 + GAP + Python 3.12.
#   3. Installs the QEC PyPI packages into that env (uv if available, else pip).
#   4. Installs the GAP packages QDistRnd + AutoDoc + Guava into ~/.gap/pkg
#      (Guava is compiled from source).
#   5. Writes ~/.gap/gaprc so QDistRnd loads cleanly through Sage's gap interface.
#   6. Registers a Jupyter kernel "Python (tdj / Sage 10.5)" for VSCode.
#   7. Verifies the full stack end-to-end.
#
# Safe to re-run: each step is idempotent (skips work already done).
#
# Prerequisites: Homebrew (https://brew.sh) and git. Run from the repo root:
#   bash setup_macos_env.sh
#
# Note: deliberately NOT using `set -u` — conda's activation scripts reference
# unbound shell variables and would abort under it.
set -eo pipefail

ENV_NAME="tdj"
SAGE_VERSION="10.5"
PY_VERSION="3.12"
GUAVA_TAG="v3.20"               # Guava release known to build against GAP 4.13.x
GAP_PKG_DIR="${HOME}/.gap/pkg"
GAPRC="${HOME}/.gap/gaprc"

# QEC packages installed on top of Sage (pinned to the versions this repo was run with)
QEC_PKGS=(
  "bposd==2.1" "ldpc==2.3.8" "stim==1.15.0" "PyMatching==2.2.2"
  "beliefmatching==0.2.0" "sinter==1.15.0" "numba==0.62.1" "joblib==1.5.1"
)

say()  { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31mxx %s\033[0m\n" "$*" >&2; exit 1; }

# --- 0. prerequisites -------------------------------------------------------
command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh first."
command -v git  >/dev/null 2>&1 || die "git not found."

BREW_PREFIX="$(brew --prefix)"

# --- 1. Miniforge -----------------------------------------------------------
CONDA_SH="${BREW_PREFIX}/Caskroom/miniforge/base/etc/profile.d/conda.sh"
if [ ! -f "${CONDA_SH}" ]; then
  say "Installing Miniforge via Homebrew"
  brew install miniforge
else
  say "Miniforge already installed"
fi
[ -f "${CONDA_SH}" ] || die "conda.sh not found at ${CONDA_SH} after install."
# shellcheck disable=SC1090
source "${CONDA_SH}"

# --- 2. conda env: Sage + GAP ----------------------------------------------
if conda env list | grep -qE "^\s*${ENV_NAME}\s"; then
  say "conda env '${ENV_NAME}' already exists"
else
  say "Creating conda env '${ENV_NAME}' (Sage ${SAGE_VERSION} + GAP + Python ${PY_VERSION}) — large download, be patient"
  mamba create -n "${ENV_NAME}" -c conda-forge -y \
    "sage=${SAGE_VERSION}" gap-core gap-defaults "python=${PY_VERSION}"
fi
conda activate "${ENV_NAME}"

# autotools are needed to compile Guava's Leon component
say "Ensuring build tools (autoconf/automake/libtool) are in the env"
mamba install -n "${ENV_NAME}" -c conda-forge -y autoconf automake libtool >/dev/null

# --- 3. QEC PyPI packages ---------------------------------------------------
say "Installing QEC PyPI packages into '${ENV_NAME}'"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "${CONDA_PREFIX}/bin/python" "${QEC_PKGS[@]}"
else
  warn "uv not found; falling back to pip"
  python -m pip install "${QEC_PKGS[@]}"
fi

# --- 4. GAP packages: QDistRnd + AutoDoc + Guava ----------------------------
mkdir -p "${GAP_PKG_DIR}"
clone_pkg() {  # name url [tag]
  local name="$1" url="$2" tag="${3:-}"
  if [ -d "${GAP_PKG_DIR}/${name}" ]; then
    say "GAP package ${name} already cloned"
  else
    say "Cloning GAP package ${name}"
    if [ -n "${tag}" ]; then
      git clone --depth 1 --branch "${tag}" "${url}" "${GAP_PKG_DIR}/${name}"
    else
      git clone --depth 1 "${url}" "${GAP_PKG_DIR}/${name}"
    fi
  fi
}
clone_pkg QDistRnd https://github.com/QEC-pages/QDistRnd.git
clone_pkg AutoDoc  https://github.com/gap-packages/AutoDoc.git
clone_pkg guava    https://github.com/gap-packages/guava.git "${GUAVA_TAG}"

# build Guava (compiles minimum-weight + Leon binaries) if not already built
if ls "${GAP_PKG_DIR}/guava/bin/"*/minimum-weight >/dev/null 2>&1; then
  say "Guava already built"
else
  say "Building Guava against GAP root ${CONDA_PREFIX}/lib/gap"
  pushd "${GAP_PKG_DIR}/guava" >/dev/null
  ./configure --with-gaproot="${CONDA_PREFIX}/lib/gap"
  make
  popd >/dev/null
fi

# --- 5. ~/.gap/gaprc fix ----------------------------------------------------
# Guava references three symbols from the (uninstalled) `design` package; GAP
# emits "Unbound global variable" syntax warnings when parsing Guava, and Sage's
# `gap` pexpect interface treats that stderr as fatal. Pre-bind them to silence it.
say "Writing ${GAPRC} (silences Guava syntax warnings for Sage's gap interface)"
mkdir -p "$(dirname "${GAPRC}")"
GAPRC_MARK="# --- transversal-dimension-jump: guava/QDistRnd fix ---"
if [ -f "${GAPRC}" ] && grep -qF "${GAPRC_MARK}" "${GAPRC}"; then
  say "gaprc fix already present"
else
  cat >> "${GAPRC}" <<EOF
${GAPRC_MARK}
if not IsBoundGlobal("FpfAutomorphismGroupsCyclic") then
  BindGlobal("FpfAutomorphismGroupsCyclic", fail);
fi;
if not IsBoundGlobal("DesignFromFerreroPair") then
  BindGlobal("DesignFromFerreroPair", fail);
fi;
if not IsBoundGlobal("IncidenceMat") then
  BindGlobal("IncidenceMat", fail);
fi;
EOF
fi

# --- 6. Jupyter kernel for VSCode ------------------------------------------
# The kernel must launch through the `sage` wrapper, not the bare env python:
# `from sage.all import *` shells out to helper binaries (Singular, gap, ...) that
# live in ${CONDA_PREFIX}/bin, and only `sage --python` puts that dir + Sage's env
# vars on PATH. Launching the bare python fails with "Singular not found on PATH".
# We use plain `ipykernel_launcher` (NOT sage.repl.ipython_kernel) so the notebook
# runs as ordinary Python — no Sage preparser rewriting `^`, integer literals, etc.
say "Registering Jupyter kernel 'Python (${ENV_NAME} / Sage ${SAGE_VERSION})'"
python -m ipykernel install --user --name "${ENV_NAME}" \
  --display-name "Python (${ENV_NAME} / Sage ${SAGE_VERSION})"
KERNEL_JSON="${HOME}/Library/Jupyter/kernels/${ENV_NAME}/kernel.json"
cat > "${KERNEL_JSON}" <<EOF
{
 "argv": [
  "${CONDA_PREFIX}/bin/sage",
  "--python",
  "-m",
  "ipykernel_launcher",
  "-f",
  "{connection_file}"
 ],
 "display_name": "Python (${ENV_NAME} / Sage ${SAGE_VERSION})",
 "language": "python",
 "metadata": {
  "debugger": true
 }
}
EOF

# --- 7. verify end-to-end ---------------------------------------------------
say "Verifying full stack (sage + bposd + QDistRnd distance estimate)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sage -python - "${REPO_ROOT}" <<'PY'
import sys
repo = sys.argv[1]
sys.path.insert(0, repo + "/src")
from sage.all import *
import numpy as np
from bposd.css import css_code
from CodeGeneration import create_2D_HGP_code
from BP_codes_sage import DistanceEst_Gap
assert str(gap('LoadPackage("QDistRnd");')) == "true", "QDistRnd failed to load"
H = np.array([[1,1,0],[0,1,1],[1,0,1]])
code = create_2D_HGP_code(H, H.T, compute_distance=False)
d = DistanceEst_Gap(code)
print("OK: built [[%d,..]] code, QDistRnd distance estimate = %s" % (code.N, d))
PY

say "Done. In VSCode, open notebooks/0_code_generation.ipynb and select the"
say "kernel 'Python (${ENV_NAME} / Sage ${SAGE_VERSION})'."
