"""Per-version hub repo: emits one cilium_toolchain per platform, gated on
target_compatible_with. The pinned manifest itself lives in the source
tree at //private/manifests/cilium-<ver>.yaml; the hub just records the
version and exposes it via the toolchain.
"""

load(":versions.bzl", "CILIUM_VERSIONS", "PLATFORMS")

_HUB_BUILD_TMPL = """\
load("@rules_cilium//toolchain:toolchain.bzl", "cilium_toolchain")

package(default_visibility = ["//visibility:public"])

{toolchains}
"""

_HUB_TC_TMPL = """\
cilium_toolchain(
    name = "{plat}_impl",
    version = "{version}",
    manifest = "@rules_cilium//private/manifests:cilium-{version}.yaml",
    manifest_sha256 = "{manifest_sha256}",
)

toolchain(
    name = "{plat}",
    toolchain_type = "@rules_cilium//toolchain:cilium",
    target_compatible_with = {compat},
    toolchain = ":{plat}_impl",
)
"""

def _hub_repo_impl(rctx):
    version = rctx.attr.version
    if version not in CILIUM_VERSIONS:
        fail("rules_cilium: unknown version '{}'. Known: {}".format(
            version,
            sorted(CILIUM_VERSIONS.keys()),
        ))
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))

    manifest_sha = CILIUM_VERSIONS[version]["manifest_sha256"]
    chunks = []
    for plat, compat in PLATFORMS.items():
        chunks.append(_HUB_TC_TMPL.format(
            plat = plat,
            version = version,
            manifest_sha256 = manifest_sha,
            compat = repr(compat),
        ))
    rctx.file("BUILD.bazel", _HUB_BUILD_TMPL.format(
        toolchains = "\n".join(chunks),
    ))

_cilium_hub_repository = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

def cilium_version_repository(name, version):
    """Materialize the hub repo for one Cilium version."""
    if version not in CILIUM_VERSIONS:
        fail("rules_cilium: unknown version '{}'. Known: {}".format(
            version,
            sorted(CILIUM_VERSIONS.keys()),
        ))
    _cilium_hub_repository(name = name, version = version)
