#!/usr/bin/env bash
#SBATCH --job-name=food-pretrain-classifier
#SBATCH --partition=__PARTITION__
#SBATCH --account=__ACCOUNT__
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=23:59:00
#SBATCH --output=logs/%x-%j.out
# Open Images pretraining of the MobileNetV3 classifier backbone.
source cluster/slurm/common.sh
food-rec check-licenses configs/pretrain/classification_openimages.yaml
food-rec pretrain-classifier
