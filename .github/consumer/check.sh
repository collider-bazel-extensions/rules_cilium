#!/usr/bin/env bash
# Consumer checks against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do):
#   1. no cilium.version() in the root resolves and a cilium_install builds
#      against rules_cilium's own pinned version
#   2. the same tag twice in the root resolves
#   3. a root adding another name keeps rules_cilium's own @cilium
#   4. an unsupported version fails, naming cilium.version
#   5. @rules_cilium//... loads (tests/ and tools/ are not shipped)
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_cilium"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests tools; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
own_version="$(grep -A3 '^cilium.version(' "$src/MODULE.bazel" | sed -n 's/.*version = "\(.*\)".*/\1/p')"
[[ -n "$own_version" ]] || { echo "FAIL: no cilium.version() in MODULE.bazel" >&2; exit 1; }

consumer() { # <name> <extra MODULE.bazel lines>
    local c="$work/$1"
    mkdir -p "$c"
    if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
    cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_cilium")
local_path_override(module_name = "rules_cilium", path = "$src")
$2
MOD
    cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_cilium//:defs.bzl", "cilium_install")

cilium_install(name = "cilium")
BUILD
    echo "$c"
}

hub_version() { # <consumer dir> <repo name>
    local base
    base="$(cd "$1" && bazel info output_base)"
    sed -n 's/^    version = "\(.*\)",$/\1/p' "$base/external/rules_cilium++cilium+$2/BUILD.bazel" | sort -u
}

# 1. No cilium.version(): resolves, builds, uses rules_cilium's own version.
c="$(consumer untagged "")"
(cd "$c" && bazel mod deps >/dev/null && bazel build //:cilium)
got="$(hub_version "$c" cilium)"
[[ "$got" == "$own_version" ]] || { echo "FAIL: untagged consumer got '$got', want $own_version" >&2; exit 1; }
echo "PASS: untagged root resolves, cilium $own_version"

# 2. The same tag twice in the root.
c="$(consumer twice "cilium = use_extension(\"@rules_cilium//:extensions.bzl\", \"cilium\")
cilium.version(version = \"$own_version\")
cilium.version(version = \"$own_version\")
use_repo(cilium, \"cilium\")")"
(cd "$c" && bazel mod deps >/dev/null && bazel build //:cilium)
echo "PASS: repeated identical cilium.version resolves"

# 3. A root adding another name still gets rules_cilium's own @cilium.
c="$(consumer extra "cilium = use_extension(\"@rules_cilium//:extensions.bzl\", \"cilium\")
cilium.version(name = \"cilium_extra\", version = \"$own_version\")
use_repo(cilium, \"cilium_extra\")")"
(cd "$c" && bazel mod deps >/dev/null && bazel build //:cilium)
echo "PASS: root adding a name keeps @cilium"

# 4. An unsupported version fails with a message naming cilium.version.
c="$(consumer unsupported 'cilium = use_extension("@rules_cilium//:extensions.bzl", "cilium")
cilium.version(version = "0.0.1")')"
if (cd "$c" && bazel mod deps) > "$work/unsupported.out" 2>&1; then
    echo "FAIL: unsupported version resolved" >&2; exit 1
fi
grep -q 'cilium.version(version = "0.0.1") is not supported' "$work/unsupported.out" || {
    cat "$work/unsupported.out" >&2; echo "FAIL: unsupported version: wrong error" >&2; exit 1; }
echo "PASS: unsupported version fails clearly"

# 5. //... loads.
(cd "$work/untagged" && bazel query @rules_cilium//... >/dev/null)
echo "PASS: @rules_cilium//... loads"
