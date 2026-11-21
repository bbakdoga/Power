#!/usr/bin/env bash
#SBATCH --job-name=food-detector
#SBATCH --partition=__PARTITION__
#SBATCH --account=__ACCOUNT__
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=24:00:00
#SBATCH --output=logs/%x-%j.out
# Usage: sbatch cluster/slurm/train_detector.sbatch v0.1.0 [configs/experiments/<name>.yaml]
# Placeholders (__PARTITION__, __ACCOUNT__) are filled by cluster/submit.sh from cluster.env.
source cluster/slurm/common.sh
DATASET_VERSION="${1:?usage: train_detector.sbatch <dataset-version>}"
CONFIG="${2:-}"
food-rec check-licenses ${CONFIG:+"$CONFIG"}
food-rec train-detector --dataset-version "$DATASET_VERSION" ${CONFIG:+--config "$CONFIG"}
