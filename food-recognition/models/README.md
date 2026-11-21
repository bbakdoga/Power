# models/

Trained checkpoints and exported `.mlpackage` files live here and are never
committed. Each released model gets a record in `models/registry.yaml`
(committed) with its version, the frozen dataset version it was trained on,
the licence check result, sha256 of the files and the evaluation record path.
