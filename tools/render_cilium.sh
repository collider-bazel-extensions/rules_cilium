#!/usr/bin/env bash
# tools/render_cilium.sh — thin shim around the Bazel-native render flow.
#
# Maintainer flow for adding/updating a Cilium version:
#   1. Edit private/versions.bzl::CILIUM_VERSIONS to add/change the entry,
#      including chart_url + chart_sha256. Compute the chart sha:
#          curl -fsSL "https://helm.cilium.io/cilium-${VERSION}.tgz" \
#              | sha256sum
#   2. Add (or update) a `helm_template` + `sh_binary` block in
#      tools/BUILD.bazel for the new version.
#   3. Run this script:
#          bash tools/render_cilium.sh <version>
#      It just invokes `bazel run //tools:render_writeback_<dotted_version>`,
#      which renders via the hermetic helm binary supplied by rules_helm,
#      writes the output to private/manifests/, and updates manifest_sha256
#      in private/versions.bzl.
#
# Host helm is NOT required at any point — the helm binary comes from
# rules_helm (declared as a dev dependency in MODULE.bazel).
set -euo pipefail

VERSION="${1:?usage: tools/render_cilium.sh <version>}"
TARGET="//tools:render_writeback_$(echo "$VERSION" | tr '.' '_')"

echo "[render_cilium] $TARGET"
exec bazel run "$TARGET"
