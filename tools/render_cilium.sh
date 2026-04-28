#!/usr/bin/env bash
# tools/render_cilium.sh — render the Cilium helm chart to a static YAML
# manifest under private/manifests/. Maintainer-side only; not invoked by
# `bazel build` or `bazel test`. Mirrors rules_capsule's render_capsule.sh.
#
# Usage:
#     bash tools/render_cilium.sh <chart-version>            # e.g. 1.16.5
#     bash tools/render_cilium.sh <chart-version> --update   # also auto-edit
#                                                            # private/versions.bzl
#
# Requires `helm` (3.x) on PATH. The Cilium chart repo is added at run time
# (`helm repo add cilium https://helm.cilium.io/`) and pulled; the chart
# itself is cached under a tmpdir and not committed (only the rendered YAML
# is). Helm is **not** required at consumer test time.
set -euo pipefail

VERSION="${1:?usage: tools/render_cilium.sh <chart-version> [--update]}"
UPDATE=0
[[ "${2:-}" == "--update" ]] && UPDATE=1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTS_DIR="$REPO_ROOT/private/manifests"
VERSIONS_BZL="$REPO_ROOT/private/versions.bzl"
OUT="$MANIFESTS_DIR/cilium-${VERSION}.yaml"

if ! command -v helm >/dev/null 2>&1; then
    echo "ERROR: helm not found on PATH." >&2
    exit 127
fi

mkdir -p "$MANIFESTS_DIR"
WORKDIR=$(mktemp -d -t render-cilium-XXXXXX)
# shellcheck disable=SC2064
trap "rm -rf '$WORKDIR'" EXIT

echo "[render_cilium] adding cilium helm repo"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

echo "[render_cilium] pulling cilium/cilium $VERSION"
helm pull cilium/cilium --version "$VERSION" --destination "$WORKDIR" >/dev/null

CHART_TGZ="$WORKDIR/cilium-${VERSION}.tgz"
if [[ ! -f "$CHART_TGZ" ]]; then
    echo "ERROR: expected $CHART_TGZ; helm pull produced:" >&2
    ls "$WORKDIR" >&2
    exit 1
fi

echo "[render_cilium] rendering: --kube-version 1.32.0, hubble disabled, --include-crds, ns=kube-system"
# --kube-version 1.32.0:
#     The chart guards `securityContext.appArmorProfile` (and a handful of
#     other fields) with `semverCompare ">=1.30" .Capabilities.KubeVersion`.
#     `helm template` otherwise defaults to a stub kube version that trips
#     those guards inconsistently. Pinning to 1.32 matches the kindest/node
#     image rules_cilium tests against (rules_kind v0.1.2 with k8s 1.32, see
#     DESIGN.md decision #16).
# --set hubble.enabled=false:
#     The chart self-signs a Hubble CA + server cert via genCA/genSignedCert
#     on every render, so cilium-ca / hubble-server-certs Secrets churn and
#     the manifest sha is never stable. The smoke test only asserts
#     NetworkPolicy enforcement; Hubble is out of scope for v0.1.
helm template cilium "$CHART_TGZ" \
    --namespace kube-system \
    --kube-version 1.32.0 \
    --include-crds \
    --set hubble.enabled=false \
    > "$OUT"

SHA256=$(sha256sum "$OUT" | awk '{print $1}')
LINES=$(wc -l < "$OUT")

echo
echo "[render_cilium] OK"
echo "    file:   $OUT"
echo "    sha256: $SHA256"
echo "    lines:  $LINES"

if (( UPDATE )); then
    echo
    echo "[render_cilium] updating $VERSIONS_BZL"
    python3 - "$VERSIONS_BZL" "$VERSION" "$SHA256" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
m = re.search(r"(CILIUM_VERSIONS\s*=\s*\{)([\s\S]*?)(\n\})", src)
if not m:
    sys.exit("could not locate CILIUM_VERSIONS dict in versions.bzl")
head, body, tail = m.group(1), m.group(2), m.group(3)
entry = f'\n    "{version}": {{\n        "manifest_sha256": "{sha}",\n    }},'
existing = re.search(rf'\n    "{re.escape(version)}":[\s\S]*?\n    \}},', body)
new_body = (body[:existing.start()] + entry + body[existing.end():]) if existing else (body.rstrip(",\n ") + "," + entry)
new_src = src[:m.start()] + head + new_body + tail + src[m.end():]
open(path, "w").write(new_src)
print(f"  wrote CILIUM_VERSIONS['{version}'] = manifest_sha256 = {sha}")
PY
    echo
    echo "Next: bump MODULE.bazel's \`cilium.version(version = \"$VERSION\")\` and"
    echo "      \`bazel test //tests:...analysis\` to verify."
else
    echo
    echo "Next steps (re-run with --update to do this automatically):"
    echo "  1. Add or update in private/versions.bzl::CILIUM_VERSIONS:"
    echo
    echo "       \"$VERSION\": {"
    echo "           \"manifest_sha256\": \"$SHA256\","
    echo "       },"
    echo
    echo "  2. Bump MODULE.bazel's \`cilium.version(version = \"$VERSION\")\`."
fi
