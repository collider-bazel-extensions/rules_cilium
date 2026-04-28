#!/usr/bin/env bash
# tools/writeback.sh — invoked by `bazel run //tools:render_writeback_<ver>`.
# Copies the helm_template-rendered YAML from bazel-bin into the source
# tree, then updates CILIUM_VERSIONS[<ver>].manifest_sha256 in
# private/versions.bzl.
set -euo pipefail

SRC_BAZEL_BIN="${1:?usage: writeback.sh <bazel-bin source> <dest path under workspace> <version>}"
DEST_REL="${2:?missing dest path}"
VERSION="${3:?missing version}"

WORKSPACE="${BUILD_WORKSPACE_DIRECTORY:?BUILD_WORKSPACE_DIRECTORY not set; run via 'bazel run', not 'bazel test'}"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
RENDERED="${RUNFILES_DIR}/_main/${SRC_BAZEL_BIN}"
[[ -f "$RENDERED" ]] || { echo "writeback: missing rendered YAML at $RENDERED" >&2; exit 1; }

DEST="${WORKSPACE}/${DEST_REL}"
mkdir -p "$(dirname "$DEST")"
cp -f "$RENDERED" "$DEST"

SHA256=$(sha256sum "$DEST" | awk '{print $1}')
LINES=$(wc -l < "$DEST")

echo "writeback: wrote $DEST"
echo "  sha256: $SHA256"
echo "  lines:  $LINES"

VERSIONS_BZL="${WORKSPACE}/private/versions.bzl"
python3 - "$VERSIONS_BZL" "$VERSION" "$SHA256" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
pat = re.compile(
    r'("' + re.escape(version) + r'":\s*\{[\s\S]*?"manifest_sha256":\s*")[0-9a-f]+(")',
    re.MULTILINE,
)
new, n = pat.subn(r'\g<1>' + sha + r'\g<2>', src)
if n == 0:
    sys.exit(f"writeback: could not find manifest_sha256 for version {version} in {path}")
open(path, "w").write(new)
print(f"writeback: updated CILIUM_VERSIONS['{version}'].manifest_sha256 in {path}")
PY
