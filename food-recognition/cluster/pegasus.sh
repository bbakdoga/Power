#!/usr/bin/env bash
# Submit a job directly on the Pegasus login node (no Mac, no rsync):
#   cluster/pegasus.sh validate
#   cluster/pegasus.sh pretrain_detector
#   cluster/pegasus.sh pretrain_classifier
#   cluster/pegasus.sh train_detector   v0.1.0 configs/experiments/detection_openimages.yaml
#   cluster/pegasus.sh experiments      v0.1.0     # all 4 runs of the pretrained vs scratch comparison
#
# GPU jobs are queued on every allowed GPU partition at once and start on
# whichever frees up first. B200 and RTXB6000 are never used (project rule).
# V100-32GB is left out: current PyTorch wheels no longer support Volta GPUs.
set -euo pipefail
cd "$(dirname "$0")/.."

GPU_PARTITIONS="RTXA6000,RTXA6000-AV,L40S,L40S-AV,A100-80GB,A100-40GB,A100-PCI,A100-RP,RTX3090,H100,H100-RP,H100-PCI,H200,H200-PCI,H200-AV"
CPU_PARTITIONS="batch"
mkdir -p logs

submit() {
  local job="$1"; shift
  local partitions="$GPU_PARTITIONS"
  [[ "$job" == "validate" ]] && partitions="$CPU_PARTITIONS"
  sed -e "s/__PARTITION__/$partitions/" -e '/--account=__ACCOUNT__/d' "cluster/slurm/$job.sbatch" > "logs/.$job.sbatch"
  sbatch "logs/.$job.sbatch" "$@"
}

job="${1:?job: validate | pretrain_detector | pretrain_classifier | train_detector | train_classifier | experiments}"
shift
if [[ "$job" == "experiments" ]]; then
  version="${1:?usage: cluster/pegasus.sh experiments <dataset-version>}"
  for model in detection classification; do
    script=$([[ $model == detection ]] && echo train_detector || echo train_classifier)
    for init in openimages scratch; do
      submit "$script" "$version" "configs/experiments/${model}_${init}.yaml"
    done
  done
else
  submit "$job" "$@"
fi
echo "check with: squeue -u \$USER"
