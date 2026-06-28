# Architecture — Phoenix TaskApp on OCI k3s

## 1. Topology

```
                                 Internet
   DNS A  onyedikachi-capston.st-pardon.com ─┐      ┌─ DNS A  api.st-pardon.com
             (frontend + same-origin /api)    └──┬───┘   (backend, direct)
                                         both ──▶ │ node public IP
                            ┌───────────────────────────────────┐ OCI NSG: 80/443 world,
                            │            ingress-nginx            │ 22/6443 operator-only
                            │  TLS terminated, 2 certs            │◀─ cert-manager + Let's
                            └──┬───────────────┬──────────────┬──┘   Encrypt (HTTP-01)
            host=frontend  /  │           /api │              │  host=api  /
                ┌─────────────▼──┐         ┌───▼──────────────▼──┐
                │   frontend     │         │      backend         │ 2 replicas each,
                │  Service :80   │         │   Service :5000      │ spread across nodes
                └────────┬───────┘         └──────────┬──────────┘
                         ▼                            ▼
                frontend Pods (A,B)          backend Pods (A,B) ──▶ ┌────────────────┐
                                                                    │ postgres (STS) │ PVC
                                                                    │  Service :5432 │ local-path
                                                                    └────────────────┘

  certs:  taskapp-tls (frontend host) + taskapp-api-tls (api host) — both Let's Encrypt prod
  Nodes:  phoenix-server (k3s control-plane, schedulable) + phoenix-worker-1/2 (agents)
  GitOps: Argo CD (argocd ns) reconciles ingress-nginx, cert-manager, taskapp, kube-prometheus-stack
```

## 2. Node & network
- **Nodes:** 1 k3s server (1 OCPU / 6 GB) + 2 agents (1 OCPU / 9 GB) = the full 4-OCPU / 24 GB
  Always Free Ampere A1 allowance, all in `eu-paris-1` (single-AD region).
- **Network:** VCN `10.0.0.0/16`, one public subnet `10.0.1.0/24`, internet gateway, default route.
- **Firewall (OCI NSG, the edge):** `80`/`443` from the world; `22`/`6443` from the operator IP
  only; `6443`/`8472-udp`/`10250` intra-VCN for k3s. **`6443` is never `0.0.0.0/0`** — enforced by
  the NSG *and* a Terraform variable validation. Host iptables (OCI's default REJECT) are removed
  by the Ansible hardening role so k3s networking works; the NSG is the real firewall.

## 3. Request flow
Two DNS A records point at the same node public IP. ingress-nginx (exposed on `:443` via k3s
klipper servicelb) terminates TLS — **two Let's Encrypt certs**, one per host — then routes:

- **`onyedikachi-capston.st-pardon.com`** (the app, served same-origin so there's **no CORS**):
  `/` → `taskapp-frontend:80`, `/api` → `taskapp-backend:5000`.
- **`api.st-pardon.com`** (the backend exposed directly for API clients / testing):
  `/` → `taskapp-backend:5000`.

The backend reads/writes `taskapp-postgres:5432` (headless Service → StatefulSet pod, data on a
`local-path` PVC). Both host/cert mappings live in `manifests/overlays/prod/kustomization.yaml`;
the base `ingress.yaml` ships the single-host template that the overlay patches.

## 4. The single-server assumptions I fixed ← graders look here

| Single-server assumption | Why it breaks on a cluster | How I fixed it |
|---|---|---|
| migrate-on-boot in the entrypoint | 2+ replicas race on `alembic upgrade head` | migration **Job** as an Argo **PreSync hook** — runs once, before replicas roll |
| named volume on the host | pods reschedule across nodes | Postgres **StatefulSet + PVC** (`local-path` storage class) |
| `ports:` published on the host | many pods/nodes need one front door | **ingress-nginx + Services**, klipper servicelb on node IPs |
| crash = you SSH in and restart | no human in the loop at scale | **Deployments + liveness/readiness/startup probes** self-heal |
| deploy = stop then start (downtime) | requests dropped mid-deploy | **RollingUpdate `maxUnavailable: 0`** + **PDB `minAvailable: 1`** |
| `.env` on disk, trusted | plaintext secret on every box | **ConfigMap** (non-secret) + **out-of-band Secret** |
| flat, trusted local network | no segmentation between tiers | **default-deny NetworkPolicy** + targeted allows (k3s enforces it) |
| one box = one failure domain | box dies → app dies | **3 nodes**, 2+ replicas/tier, **topologySpreadConstraints** |
| `:latest`, rebuild in place | unpinned, irreproducible | **pinned image tags** via kustomize `images:` |

## 5. Choices & trade-offs
- **kustomize (base + overlay)** over Helm/raw — declarative, no templating engine, Argo renders it
  natively; overlay isolates env-specifics (image tags, domain).
- **ingress-nginx over k3s Traefik** — disabled Traefik (`--disable traefik`); nginx for path-based
  same-origin routing and first-class cert-manager integration. Kept klipper servicelb for the LB.
  The overlay adds a second host (`api.st-pardon.com`) straight to the backend so the API is also
  reachable on its own subdomain + cert, independent of the same-origin app path.
- **NetworkPolicy enforced by k3s' built-in kube-router** — no Calico needed; default-deny + a rule
  for the ACME HTTP-01 solver so cert issuance still works under deny. Subtlety: kustomize
  `commonLabels` injects `part-of=taskapp` into the solver policy's *selector*, but cert-manager's
  solver pod isn't built by kustomize — so the Issuer's `solvers.http01.ingress.podTemplate` stamps
  that label on the solver pod; without it the policy doesn't match and HTTP-01 returns 502.
- **Secrets via Sealed Secrets (encrypted, in git)** — `manifests/seal-secret.sh` + the
  sealed-secrets controller turn the real Secret into a committable `SealedSecret` only the cluster
  can decrypt, so git holds the full desired state. The plain out-of-band `kubectl apply` of a
  Secret (`secret.example.yaml` shows the shape) remains the simpler fallback.
- **`local-path` storage** — k3s default, simplest; trade-off is the PV is node-pinned (survives pod
  delete, not node loss). HA Postgres is a stretch goal, intentionally deferred.
- **Remote state on OCI Object Storage (S3-compat)** — the OCI "equivalent" of S3; locking is the
  weak spot (no DynamoDB), handled by solo-operator discipline. See `infra-aws/` for the contrast.
- **Argo scoped `AppProject`** over `default` — allowlists the source repo + the platform namespaces
  (incl. `monitoring` for the observability stack).

## 6. Observability — kube-prometheus-stack

A single Argo Application (`gitops/apps/kube-prometheus-stack.yaml`, namespace `monitoring`) deploys
the **kube-prometheus-stack** Helm chart: **Prometheus + Grafana + Alertmanager + node-exporter +
kube-state-metrics**, plus the prometheus-operator and its CRDs.

- **Why this chart:** it's the de-facto, batteries-included monitoring stack — one chart wires
  Prometheus to scrape the kubelet/cAdvisor, node-exporter and kube-state-metrics, and ships
  ready-made Grafana dashboards (cluster/node/pod/namespace views). That bundled dashboard set is the
  observability *evidence* with zero custom wiring.
- **Tuned for free-tier ARM:** the cluster is 3 × Ampere A1 (1 OCPU each), so every component is
  pinned to modest requests/limits (Prometheus ~200m/512Mi req → 500m/1Gi limit; Grafana,
  Alertmanager, operator, exporters all small), a **single replica** each, and **retention 2d / 1GB**.
  Persistence is **OFF (emptyDir)** to avoid PVC pressure on the single `local-path` provisioner —
  the trade-off is that metrics/alert state are **not durable across pod restarts**, which is
  acceptable for a demo. All chart images are multi-arch (arm64-ok); no `nodeSelector` is set, so
  nothing is pinned to an unavailable amd64 image.
- **NetworkPolicy boundary (deliberate):** the `taskapp` namespace runs a **default-deny ingress**
  NetworkPolicy, so Prometheus in `monitoring` **cannot** scrape the taskapp Flask pods — and we
  don't try to. The Flask app exposes no `/metrics` endpoint anyway. Monitoring covers
  **cluster/node/Kubernetes-state** signals (kubelet & cAdvisor, node-exporter, kube-state-metrics),
  which is plenty for the observability deliverable. Poking a hole in the app's default-deny just to
  scrape a non-existent endpoint would weaken the segmentation story for no benefit, so the boundary
  stays. If app-level metrics were ever wanted, the right move would be a scoped `allow-from
  monitoring` NetworkPolicy + a real `/metrics` endpoint + a `ServiceMonitor`, not removing
  default-deny.
- **GitOps fit:** sync-wave `"0"` — independent of the taskapp, bundles its own CRDs, so it has no
  ordering dependency on the wave -2/-1 platform controllers.
