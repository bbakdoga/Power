#!/usr/bin/env bash
#SBATCH --job-name=food-pretrain-detector
#SBATCH --partition=__PARTITION__
#SBATCH --account=__ACCOUNT__
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=23:59:00
#SBATCH --output=logs/%x-%j.out
# Open Images pretraining of YOLOX-Tiny. Fits the 1-day limit of every allowed
# partition; if it runs out of time, submit it again and it continues from the
# last finished epoch of the newest unfinished run.
source cluster/slurm/common.sh
food-rec check-licenses configs/pretrain/detection_openimages.yaml
RESUME=""
for run in $(ls -1dt models/runs/detection-pretrain/openimages-* 2>/dev/null); do
  if [[ -f "$run/resume.pt" && ! -f "$run/summary.json" ]]; then RESUME="$run"; break; fi
done
food-rec pretrain-detector ${RESUME:+--resume "$RESUME"}
