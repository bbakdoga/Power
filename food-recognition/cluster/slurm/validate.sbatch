#!/usr/bin/env bash
#SBATCH --job-name=food-validate
#SBATCH --partition=__PARTITION__
#SBATCH --account=__ACCOUNT__
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --output=logs/%x-%j.out
# CPU only: run before any GPU job. Training refuses to start without a frozen, valid dataset.
source cluster/slurm/common.sh
food-rec check-licenses
food-rec validate
