#!/usr/bin/env bash
# Shared job setup. Sourced by the sbatch scripts; reads cluster/cluster.env on the cluster.
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-$PWD}"
if [[ -f cluster/cluster.env ]]; then
  # shellcheck disable=SC1091
  source cluster/cluster.env
fi
eval "${CLUSTER_ENV_SETUP:-true}"
export PYTHONHASHSEED=1337
export CUBLAS_WORKSPACE_CONFIG=:4096:8   # deterministic cuBLAS
mkdir -p logs
echo "job ${SLURM_JOB_ID:-local} on $(hostname) at $(date -u +%FT%TZ)"
nvidia-smi || true
python -c "import food_recognition, sys; print('food_recognition', food_recognition.__version__, sys.version)"
