#!/usr/bin/env bash
# Run on your Mac: sync code (and data) to the cluster, then submit a job.
#   cluster/submit.sh validate
#   cluster/submit.sh train_detector v0.1.0
# Uses your SSH config and key; never put a password in a file or command line.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
# shellcheck disable=SC1091
source "$here/cluster.env"
job="${1:?job name: validate | train_detector | train_classifier}"; shift || true

rsync -az --delete \
  --exclude '.venv' --exclude '__pycache__' --exclude 'models/' --exclude 'reports/' \
  --exclude 'label-studio-data/' \
  "$root/" "$CLUSTER_HOST:$CLUSTER_WORKDIR/"

if [[ "$CLUSTER_SCHEDULER" == "slurm" ]]; then
  ssh "$CLUSTER_HOST" "cd '$CLUSTER_WORKDIR' && \
    sed -e 's/__PARTITION__/$CLUSTER_PARTITION/' -e 's/__ACCOUNT__/$CLUSTER_ACCOUNT/' \
      cluster/slurm/$job.sbatch > /tmp/\$USER-$job.sbatch && sbatch /tmp/\$USER-$job.sbatch $*"
else
  model="${job#train_}"
  ssh "$CLUSTER_HOST" "cd '$CLUSTER_WORKDIR' && \
    sed -e 's/__PARTITION__/$CLUSTER_PARTITION/' -e 's/__ACCOUNT__/$CLUSTER_ACCOUNT/' cluster/lsf/train.lsf | \
    MODEL=$model DATASET_VERSION=${1:-} bsub"
fi
