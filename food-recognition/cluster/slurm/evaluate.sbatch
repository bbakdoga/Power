#!/usr/bin/env bash
#SBATCH --job-name=food-evaluate
#SBATCH --partition=__PARTITION__
#SBATCH --account=__ACCOUNT__
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=logs/%x-%j.out
# Usage: sbatch cluster/slurm/evaluate.sbatch models/runs/<experiment>/<run> [more runs...]
# Scores each finished run on the test split and prints one comparison line per run.
source cluster/slurm/common.sh
food-rec evaluate "$@"
