#!/usr/bin/env bash
# Apply two Pods in `default` and a NetworkPolicy that denies all egress
# from `client`. Then assert that `client` cannot reach `server` via in-
# cluster DNS / Pod IP. This is the assertion that justifies pulling Cilium
# in: kindnet would silently let traffic through, so a passing smoke test
# proves Cilium is actually enforcing.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

echo "smoke_test: applying two pods (server, client)"
"${KCTL[@]}" apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels: { app: server }
spec:
  containers:
    - name: server
      image: registry.k8s.io/e2e-test-images/agnhost:2.45
      args: ["netexec", "--http-port=8080"]
      ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels: { app: client }
spec:
  containers:
    - name: client
      image: registry.k8s.io/e2e-test-images/agnhost:2.45
      command: ["sleep", "3600"]
EOF

echo "smoke_test: waiting for pods Ready"
"${KCTL[@]}" wait pod/server pod/client --for=condition=Ready --timeout=180s

server_ip=$("${KCTL[@]}" get pod server -o jsonpath='{.status.podIP}')
echo "smoke_test: server pod IP=$server_ip"

# Baseline: client → server should succeed (no NetworkPolicy yet).
echo "smoke_test: baseline connectivity check (expect success)"
if ! "${KCTL[@]}" exec client -- /agnhost connect --timeout=5s "$server_ip:8080"; then
  echo "smoke_test: FAIL — baseline connectivity broken; Cilium may not be routing pods" >&2
  exit 1
fi
echo "smoke_test: OK — baseline connect succeeds"

# Now apply a NetworkPolicy that denies all egress from `client`.
echo "smoke_test: applying NetworkPolicy denying client egress"
"${KCTL[@]}" apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-client-egress
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes:
    - Egress
  egress: []
EOF

# Cilium can take a few seconds to reconcile the policy. Retry the connect
# until it consistently fails (or 30s).
echo "smoke_test: probing for enforcement (expect fail)"
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
  if ! "${KCTL[@]}" exec client -- /agnhost connect --timeout=2s "$server_ip:8080" 2>/dev/null; then
    echo "smoke_test: OK — NetworkPolicy enforced; client can no longer reach server"
    exit 0
  fi
  sleep 1
done

echo "smoke_test: FAIL — NetworkPolicy never took effect; Cilium is not enforcing" >&2
"${KCTL[@]}" -n kube-system get pods -l k8s-app=cilium >&2 || true
exit 1
