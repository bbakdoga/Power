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

## Running

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
