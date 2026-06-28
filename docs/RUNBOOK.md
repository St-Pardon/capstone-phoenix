# Runbook — Phoenix TaskApp on OCI k3s

A teammate should be able to rebuild the live, HTTPS, multi-node, GitOps-managed cluster from
this file alone. Cloud: **Oracle Cloud (OCI)**, region **eu-paris-1**.

## 0. Prerequisites (once)
```bash
brew install terraform ansible kubectl oci-cli helm jq
ssh-keygen -t ed25519 -f ~/.ssh/oci_phoenix -C phoenix     # node SSH key
# OCI: sign up, UPGRADE to Pay As You Go (dodges A1 capacity), create an API key in
# ~/.oci/config (see notes/oracle-cloud-setup.md §3). Have a domain you control.
```
Fill the gitignored real values before applying:
- `infra/terraform/root/terraform.tfvars` — `compartment_ocid`, `allowed_ssh_cidr` (your IP /32), `region = "eu-paris-1"`
- `gitops/*` and `manifests/overlays/prod/kustomization.yaml` — replace every `CHANGEME` / `REPLACE_*` (fork URL, domain, email, image tags)

## 1. Remote-state backend (run once)
```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars     # set compartment_ocid + region=eu-paris-1
terraform init && terraform apply
terraform output                                 # note bucket name, namespace, s3 endpoint
# OCI console -> profile -> Customer secret keys -> Generate (the S3 creds for the backend)
export AWS_ACCESS_KEY_ID=<access key>
export AWS_SECRET_ACCESS_KEY=<secret key>
```
Edit `infra/terraform/root/backend.tf`: set `bucket`, the `endpoints.s3` (your namespace), and
`region` — all to **eu-paris-1**.

## 2. Infrastructure — 3 nodes, VCN, firewall
```bash
cd ../root
cp terraform.tfvars.example terraform.tfvars     # compartment_ocid, allowed_ssh_cidr, region
terraform init                                   # migrates state to Object Storage
terraform apply                                  # 1 server + 2 workers, NSG, public subnet
terraform output                                 # server/worker public + private IPs
```

## 3. Cluster bring-up — k3s via Ansible
```bash
cd ../../ansible
./inventory/generate-inventory.sh                # builds inventory/hosts.yml from TF outputs
ansible-playbook site.yml                         # hardening -> k3s server -> agents -> kubeconfig
ansible-playbook site.yml                         # RUN AGAIN: must report changed=0 (idempotent)
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide                         # server + 2 workers = Ready
```

## 4. Provide the Secret
**This deployment uses Sealed Secrets (Option A) — the encrypted Secret lives in git
(`manifests/base/taskapp-sealedsecret.yaml`), no plaintext anywhere.** Fill real values first:
`cp manifests/base/secret.example.yaml /tmp/secret.yaml` (set all six keys: `POSTGRES_USER/PASSWORD`,
`DATABASE_USER/PASSWORD`, `SECRET_KEY`, `DATABASE_URL`).

**Option A — Sealed Secrets (git-native, what this repo ships).** Do this *after* step 5 brings up
the sealed-secrets controller, then git holds the encrypted Secret:
```bash
manifests/seal-secret.sh /tmp/secret.yaml      # -> manifests/base/taskapp-sealedsecret.yaml
# (it is already in manifests/base/kustomization.yaml resources). Commit + push.
# Argo syncs it; the controller decrypts it in-cluster into the taskapp-secret Secret.
```
> Re-sealing / first cutover: if a plaintext `taskapp-secret` already exists (e.g. an earlier
> out-of-band apply), the controller refuses to adopt it — delete that Secret once and
> `kubectl -n kube-system rollout restart deploy/sealed-secrets-controller`; it recreates the
> Secret from the SealedSecret and owns it (ownerReference kind=SealedSecret).

**Option B — out-of-band (bootstrap-only fallback).** A plain Secret applied by hand; Argo ignores
it. Only used to bring the app up *before* the controller exists; superseded by Option A:
```bash
kubectl create namespace taskapp
kubectl apply -n taskapp -f /tmp/secret.yaml
```

## 5. GitOps takes over — install Argo CD, hand it the cluster
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl apply -f ../../gitops/appproject.yaml    # scoped project (must exist first)
kubectl apply -f ../../gitops/root-app.yaml       # app-of-apps
```
Argo now syncs by sync-wave: **ingress-nginx (-2) → cert-manager (-1) → taskapp (0)**, with
**kube-prometheus-stack (0)** alongside (independent — see §7). From here,
**no manual `kubectl apply`** — git is the source of truth.

## 6. DNS + TLS
This deploy serves **two hosts** (see `manifests/overlays/prod/kustomization.yaml`):
`onyedikachi-capston.st-pardon.com` (frontend + same-origin `/api`) and `api.st-pardon.com`
(backend, direct). Each gets its own Let's Encrypt cert.
```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # note EXTERNAL-IP (node IP via klipper)
# At your registrar, point BOTH hosts at that IP:
#   A  onyedikachi-capston.st-pardon.com  ->  <node IP>
#   A  api.st-pardon.com                  ->  <node IP>
kubectl -n taskapp get certificate          # taskapp-tls AND taskapp-api-tls -> READY=True
curl -vI https://onyedikachi-capston.st-pardon.com          # frontend: valid LE cert, HTTP 200
curl -vI https://api.st-pardon.com                          # backend:  valid LE cert, HTTP 200
```
> **Gotcha (already fixed in the manifests):** under the namespace's default-deny NetworkPolicy,
> the ACME HTTP-01 solver pod must carry `app.kubernetes.io/part-of=taskapp` or ingress-nginx
> can't reach it and the challenge fails with `wrong status code '502'`. The Issuer's
> `solvers.http01.ingress.podTemplate` stamps that label — keep it. If certs ever stick at
> `pending`, `kubectl -n taskapp delete challenge --all` forces a fresh solver pod.

## 7. Observability — access Grafana & check Prometheus targets
The `kube-prometheus-stack` Argo app brings up Prometheus + Grafana + Alertmanager + node-exporter +
kube-state-metrics in the `monitoring` namespace (tuned down for ARM — see
`docs/ARCHITECTURE.md §6`). It's not exposed via Ingress; reach it with a port-forward.
```bash
# Wait for the stack to be healthy
kubectl -n monitoring get pods                         # all Running/Completed; operator + grafana up
kubectl -n argocd get app kube-prometheus-stack        # Synced + Healthy

# --- Grafana ---
# The chart generates a random admin password into a Secret (no credential is committed to git).
GRAFANA_PW=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d); echo "grafana admin password: $GRAFANA_PW"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000  ->  login admin / <the password printed above>
# Dashboards -> e.g. "Kubernetes / Compute Resources / Cluster" or "Node Exporter / Nodes"

# --- Prometheus (verify scrape targets are UP) ---
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/targets  ->  kubelet, node-exporter, kube-state-metrics = UP
# (the taskapp app pods are intentionally NOT scraped — default-deny NetworkPolicy; see §6)
```
> **Healthy looks like:** every pod in `monitoring` Running (node-exporter is a DaemonSet — one per
> node, so 3), the `prometheus-kube-prometheus-stack-prometheus-0` and Grafana pods Ready, and the
> Prometheus `/targets` page showing the cluster/node/kube-state jobs all green. The Grafana admin
> password is **chart-generated** (random) and read from the `kube-prometheus-stack-grafana` Secret
> at login — no credential is committed to git (consistent with the Sealed Secrets posture).

---

## 8. Postgres backups — OCI Object Storage
A `CronJob` (`taskapp-pg-backup`, daily 02:00 UTC) runs `pg_dump | gzip` and uploads to an OCI
bucket via `mc`. Backups survive node/cluster loss (the `local-path` PV does not).

```bash
# one-time: create the bucket (OCI CLI or console)
oci os bucket create --name phoenix-pg-backups --compartment-id <compartment_ocid>

# one-time: seal the S3 creds (OCI Customer Secret Keys) so they live encrypted in git
cp manifests/base/pg-backup-s3.example.yaml /tmp/pg-backup-s3.yaml    # fill S3_ACCESS_KEY/S3_SECRET_KEY
manifests/seal-secret.sh /tmp/pg-backup-s3.yaml manifests/base/pg-backup-s3-sealedsecret.yaml
# uncomment the pg-backup-s3-sealedsecret.yaml line in manifests/base/kustomization.yaml, commit, push

# run a backup on demand (don't wait for 02:00) and watch it
kubectl -n taskapp create job --from=cronjob/taskapp-pg-backup pg-backup-manual
kubectl -n taskapp logs job/pg-backup-manual -f       # "uploaded taskapp-<ts>.sql.gz -> phoenix-pg-backups"
```

**Restore test (proves the backup is usable — non-destructive, uses a throwaway DB):**
```bash
export S3_ENDPOINT=https://<ns>.compat.objectstorage.eu-paris-1.oraclecloud.com \
       S3_BUCKET=phoenix-pg-backups S3_ACCESS_KEY=... S3_SECRET_KEY=...
manifests/restore-postgres.sh            # pulls the newest object, restores into restore_verify, \dt, drops it
```

---

## Day-2 operations
> Argo has `selfHeal: true` — make changes **in git**, not with `kubectl`, or they get reverted.

- **Scale a tier:** edit `replicas` (frontend) in `manifests/overlays/prod`, commit, push → Argo syncs.
  (Backend replicas are owned by the HPA; Argo ignores `/spec/replicas` for it.)
- **Deploy a new build:** bump the image `newTag` in `overlays/prod/kustomization.yaml`, commit, push.
  The migration Job (PreSync hook) runs `alembic upgrade head` before the new pods roll.
- **Roll back a bad deploy:** `git revert` the tag bump and push (or `argocd app rollback taskapp`).
- **Rotate a secret:** update `/tmp/secret.yaml`, `kubectl apply -n taskapp -f`, then
  `kubectl -n taskapp rollout restart deploy/taskapp-backend`.

## Failure recovery (one is demoed live)
- **Worker node dies / is drained** — the live demo:
  ```bash
  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
  ```
  topologySpread keeps a replica on another node; the PDB (`minAvailable: 1`) blocks full
  eviction; displaced pods reschedule in ~30–60s. App stays up. `kubectl uncordon <node>` after.
- **Backend Pod crashloops:**
  ```bash
  kubectl -n taskapp logs deploy/taskapp-backend --previous
  kubectl -n taskapp describe pod <pod>      # check probe failures / env / image
  kubectl -n taskapp get events --sort-by=.lastTimestamp
  ```
- **A bad migration:** the PreSync hook fails → Argo halts the sync, so the *old* version keeps
  serving (no half-broken deploy). Fix the migration or `alembic downgrade`, then re-sync.
- **Postgres Pod rescheduled:** `kubectl -n taskapp delete pod taskapp-postgres-0` → it reschedules
  **on the same node** (the `local-path` PV is node-pinned), the PVC re-attaches, data intact.
  ⚠ Caveat: `local-path` does NOT survive node *loss* — for the failover demo, drain a worker that
  is **not** running postgres. (HA Postgres is a brief stretch goal.)
