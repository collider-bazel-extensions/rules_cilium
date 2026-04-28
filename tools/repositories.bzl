"""Maintainer-only repository rule that downloads + extracts the Cilium
helm chart (`cilium-<ver>.tgz`) at the sha pinned in
`//private:versions.bzl`. The extracted tree exposes a `:files`
filegroup that downstream `helm_template` actions consume.

This is dev-only — consumers of rules_cilium never see this. The
chart download happens only when running the maintainer flow:

    bazel run //tools:render_writeback_<dotted_version>

The committed pre-rendered manifest at
`private/manifests/cilium-<ver>.yaml` is what `cilium_install`
applies at runtime.
"""

load("//private:versions.bzl", "CILIUM_VERSIONS")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(["**/*"]),
)
"""

def _impl(rctx):
    version = rctx.attr.version
    if version not in CILIUM_VERSIONS:
        fail("rules_cilium: unknown chart version '{}'. Known: {}".format(
            version,
            sorted(CILIUM_VERSIONS.keys()),
        ))
    pin = CILIUM_VERSIONS[version]
    rctx.download_and_extract(
        url    = pin["chart_url"],
        sha256 = pin["chart_sha256"],
    )
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _BUILD)

cilium_chart_repository = repository_rule(
    implementation = _impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)
