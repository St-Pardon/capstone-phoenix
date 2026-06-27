#!/usr/bin/env bash
#
# Encrypt the real (gitignored) Secret into a committable SealedSecret using the in-cluster
# controller's public key. The output is safe to commit — only the cluster can decrypt it.
#
# Prereqs: kubeseal installed, KUBECONFIG set, sealed-secrets controller running (gitops app).
# Usage (from repo root):
#   cp manifests/base/secret.example.yaml /tmp/secret.yaml   # fill REAL values
#   manifests/seal-secret.sh /tmp/secret.yaml
# Then add manifests/base/taskapp-sealedsecret.yaml to base/kustomization.yaml `resources:`.
set -euo pipefail

SRC="${1:-/tmp/secret.yaml}"
OUT="${2:-manifests/base/taskapp-sealedsecret.yaml}"

kubeseal \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  --format yaml \
  < "$SRC" > "$OUT"

echo "Wrote $OUT — safe to commit. Add it to manifests/base/kustomization.yaml resources,"
echo "then you no longer need the out-of-band 'kubectl apply secret.yaml' step."
