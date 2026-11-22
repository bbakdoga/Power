# Training on the Pegasus cluster

Jobs are submitted **from Baris's Mac**, which has cluster access. Nothing in
this repository holds credentials.

## One-time setup

1. Put the cluster in `~/.ssh/config` with an SSH key (ask the cluster admins
   if keys are allowed; otherwise use their standard login, e.g. with Duo):
   ```
   Host pegasus
     HostName <login node from your config file>
     User <your cluster username>
     IdentityFile ~/.ssh/id_ed25519
   ```
2. `cp cluster/cluster.env.example cluster/cluster.env` and fill in the work
   directory, scheduler, account and partition. `cluster.env` is gitignored.
3. On the cluster, create the environment once:
   ```bash
   cd $CLUSTER_WORKDIR && python3 -m venv .venv && source .venv/bin/activate
   pip install -e ".[train,dev]"
   ```

## Running directly on Pegasus (what Baris does)

Work in the checkout on Pegasus; `cluster/pegasus.sh` submits jobs from the
login node and queues GPU jobs on every allowed partition at once (never B200
or RTXB6000). Logs go to `logs/`.

```bash
# once: training libraries, then check a GPU job can see the GPU
pip install -e ".[train]"
srun -p RTXA6000,L40S,A100-80GB --gres=gpu:1 -c 4 --mem 16G --time=00:15:00 --immediate=600 \
  .venv/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"

# 1. Open Images pretraining data. Downloads run on the login node; anything
#    that imports numpy (food-rec) must run on a compute node.
mkdir -p data/external/openimages && cd data/external/openimages
wget https://storage.googleapis.com/openimages/v7/oidv7-class-descriptions-boxable.csv
wget https://storage.googleapis.com/openimages/v6/oidv6-train-annotations-bbox.csv
wget https://storage.googleapis.com/openimages/2018_04/train/train-images-boxable-with-rotation.csv
cd -
sbatch -p batch -c 4 --mem 32G --time=02:00:00 -o logs/select_%j.log --wrap "source .venv/bin/activate && \
  food-rec select-openimages-pretrain --classes-csv data/external/openimages/oidv7-class-descriptions-boxable.csv \
  --boxes-csv data/external/openimages/oidv6-train-annotations-bbox.csv \
  --metadata-csv data/external/openimages/train-images-boxable-with-rotation.csv"
python3 scripts/download_openimages.py data/pretrain/openimages/ids.txt data/pretrain/openimages/images \
  --max-side 640 --workers 32      # several hours; safe to re-run, skips finished files

# 2. pretraining (both can run at the same time)
cluster/pegasus.sh pretrain_detector
cluster/pegasus.sh pretrain_classifier

# 3. food data: validate, split, freeze, then the 4-run comparison
cluster/pegasus.sh validate
cluster/pegasus.sh experiments v0.1.0
```

If `pretrain_detector` hits the 1-day limit, submit it again: it continues
from the last finished epoch.

## Running from the Mac

```bash
cluster/submit.sh validate                  # CPU: licence check + dataset validation
cluster/submit.sh train_detector v0.1.0     # GPU: needs a frozen dataset version
cluster/submit.sh train_classifier v0.1.0

# Pretrained vs from-scratch comparison (same dataset version and test split)
cluster/submit.sh train_detector   v0.1.0 configs/experiments/detection_openimages.yaml
cluster/submit.sh train_detector   v0.1.0 configs/experiments/detection_scratch.yaml
cluster/submit.sh train_classifier v0.1.0 configs/experiments/classification_openimages.yaml
cluster/submit.sh train_classifier v0.1.0 configs/experiments/classification_scratch.yaml
```

Every job runs `food-rec check-licenses` first and stops if a config uses an
asset that is not approved. Training also stops if the frozen dataset changed.

## Data transfer

`submit.sh` uses `rsync` over SSH, so photos go only to the cluster
filesystem. Keep them in your private project or scratch space, not a shared
or public directory.
