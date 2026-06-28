#!/usr/bin/env bash
# Phoenix capstone — evidence capture.
# Run on the control box with KUBECONFIG pointed at the OCI k3s cluster.
# Produces the artifacts docs/EVIDENCE/README.md lists. Each subcommand writes one file
# next to this script. Screenshots (Argo UI, an HPA graph) still need a manual grab — the
# CLI equivalents here are the text proof; the .png is the pretty version.
#
#   ./capture.sh nodes        # nodes-ready.txt
#   ./capture.sh spread       # pods-spread.txt
#   ./capture.sh tls          # tls-valid.txt
#   ./capture.sh persist      # pvc-persist.log     (deletes the postgres pod)
#   ./capture.sh zerodowntime # zero-downtime.log   (rolls backend + frontend)
#   ./capture.sh hpa          # hpa-scale.txt       (generates load; Ctrl-C when scaled)
#   ./capture.sh argocd       # argocd-synced.txt   (also screenshot the UI)
#   ./capture.sh failover     # failover.txt        (drains a worker; uncordons after)
#   ./capture.sh safe         # everything non-disruptive (nodes, spread, tls, argocd)
#
set -uo pipefail

NS="${NS:-taskapp}"
FRONTEND_HOST="${FRONTEND_HOST:-onyedikachi-capston.st-pardon.com}"
API_HOST="${API_HOST:-api.st-pardon.com}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hdr() { echo; echo "===== $* ====="; }
run() { echo "\$ $*"; "$@"; echo; }

nodes() {
  { hdr "kubectl get nodes -o wide  ($(date -u))"
    run kubectl get nodes -o wide
  } | tee "$DIR/nodes-ready.txt"
}

spread() {
  { hdr "taskapp pods with NODE column — replicas must be on different nodes  ($(date -u))"
    run kubectl -n "$NS" get pods -o wide --sort-by=.spec.nodeName
    hdr "replica-per-node tally (backend/frontend should each span 2 nodes)"
    kubectl -n "$NS" get pods -L app.kubernetes.io/name -o \
      'custom-columns=POD:.metadata.name,NODE:.spec.nodeName,TIER:.metadata.labels.app\.kubernetes\.io/name' \
      --no-headers | awk '{print $3, $2}' | sort | uniq -c
  } | tee "$DIR/pods-spread.txt"
}

tls() {
  { for H in "$FRONTEND_HOST" "$API_HOST"; do
      hdr "https://$H  ($(date -u))"
      run bash -c "curl -sSI https://$H | head -12"
      echo "--- certificate issuer / validity ---"
      echo | openssl s_client -connect "$H:443" -servername "$H" 2>/dev/null \
        | openssl x509 -noout -issuer -subject -dates
    done
    hdr "cert-manager Certificate objects"
    run kubectl -n "$NS" get certificate
  } | tee "$DIR/tls-valid.txt"
}

persist() {
  { hdr "PROVE data survives a Postgres pod delete  ($(date -u))"
    local PSQL='psql -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c'
    echo "--- seed a marker row ---"
    kubectl -n "$NS" exec sts/taskapp-postgres -- bash -c "$PSQL \
      \"CREATE TABLE IF NOT EXISTS evidence_persist(note text, t timestamptz default now()); \
        INSERT INTO evidence_persist(note) VALUES('survives-pod-delete'); \
        SELECT count(*) FROM evidence_persist;\""
    echo "--- delete the pod, wait for it to come back ---"
    run kubectl -n "$NS" delete pod taskapp-postgres-0
    run kubectl -n "$NS" rollout status sts/taskapp-postgres --timeout=180s
    echo "--- read the marker back (data intact == PVC persisted) ---"
    kubectl -n "$NS" exec sts/taskapp-postgres -- bash -c "$PSQL \
      \"SELECT note, t FROM evidence_persist ORDER BY t DESC LIMIT 3;\""
    echo "--- cleanup marker table ---"
    kubectl -n "$NS" exec sts/taskapp-postgres -- bash -c "$PSQL \"DROP TABLE evidence_persist;\""
  } | tee "$DIR/pvc-persist.log"
}

zerodowntime() {
  { hdr "ZERO-DOWNTIME rollout — unbroken 200s while backend+frontend redeploy  ($(date -u))"
    local CODES; CODES="$(mktemp)"
    echo "hammering https://$FRONTEND_HOST/ every 0.2s during the rollout..."
    ( for _ in $(seq 1 900); do
        curl -s -o /dev/null -w '%{http_code}\n' "https://$FRONTEND_HOST/"; sleep 0.2
      done ) > "$CODES" &
    local LOOP=$!
    sleep 2
    run kubectl -n "$NS" rollout restart deploy/taskapp-backend deploy/taskapp-frontend
    kubectl -n "$NS" rollout status deploy/taskapp-backend  --timeout=180s
    kubectl -n "$NS" rollout status deploy/taskapp-frontend --timeout=180s
    kill "$LOOP" 2>/dev/null; wait "$LOOP" 2>/dev/null
    hdr "HTTP status code tally during the deploy (want: all 200)"
    sort "$CODES" | uniq -c
    rm -f "$CODES"
  } | tee "$DIR/zero-downtime.log"
}

hpa() {
  { hdr "HPA scale-up under load — Ctrl-C once replicas have climbed  ($(date -u))"
    echo "starting 4 load-gen pods hitting taskapp-backend:5000 ..."
    for i in 1 2 3 4; do
      kubectl -n "$NS" run "loadgen-$i" --image=busybox:1.36 --restart=Never -- \
        /bin/sh -c 'while true; do wget -q -O- http://taskapp-backend:5000/ >/dev/null 2>&1; done' \
        >/dev/null 2>&1 || true
    done
    echo "watch the HPA climb (target 70% CPU, 2 -> 5). Ctrl-C when satisfied, then it cleans up."
    trap 'echo; echo "--- tearing down load-gen ---"; \
          kubectl -n "$NS" delete pod loadgen-1 loadgen-2 loadgen-3 loadgen-4 --force --grace-period=0 2>/dev/null; \
          trap - INT' INT
    while true; do
      date -u
      kubectl -n "$NS" get hpa taskapp-backend
      kubectl -n "$NS" top pods -l app.kubernetes.io/name=backend 2>/dev/null
      echo
      sleep 10
    done
  } | tee "$DIR/hpa-scale.txt"
}

argocd() {
  { hdr "Argo CD applications — Synced + Healthy  ($(date -u))"
    run kubectl -n argocd get applications
    echo "(Also screenshot the Argo UI app tree -> argocd-synced.png)"
  } | tee "$DIR/argocd-synced.txt"
}

failover() {
  { hdr "FAILOVER — drain a worker (not the one running postgres) and stay up  ($(date -u))"
    local PG_NODE VICTIM CODES
    PG_NODE="$(kubectl -n "$NS" get pod taskapp-postgres-0 -o jsonpath='{.spec.nodeName}')"
    echo "postgres-0 is on: $PG_NODE (will NOT drain this — local-path PV is node-pinned)"
    VICTIM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
              | grep -v "^$PG_NODE$" | grep -i worker | head -1)"
    [ -z "$VICTIM" ] && VICTIM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v "^$PG_NODE$" | head -1)"
    echo "draining victim: $VICTIM"
    CODES="$(mktemp)"
    ( for _ in $(seq 1 300); do curl -s -o /dev/null -w '%{http_code}\n' "https://$FRONTEND_HOST/"; sleep 0.2; done ) > "$CODES" &
    local LOOP=$!
    run kubectl drain "$VICTIM" --ignore-daemonsets --delete-emptydir-data --timeout=120s
    hdr "pods after drain — displaced replicas rescheduled onto remaining nodes"
    run kubectl -n "$NS" get pods -o wide --sort-by=.spec.nodeName
    kill "$LOOP" 2>/dev/null; wait "$LOOP" 2>/dev/null
    hdr "HTTP codes during the drain (want: all 200 — app stayed up)"
    sort "$CODES" | uniq -c; rm -f "$CODES"
    hdr "uncordon the node"
    run kubectl uncordon "$VICTIM"
  } | tee "$DIR/failover.txt"
}

safe() { nodes; spread; tls; argocd; }

cmd="${1:-}"; case "$cmd" in
  nodes|spread|tls|persist|zerodowntime|hpa|argocd|failover|safe) "$cmd" ;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
