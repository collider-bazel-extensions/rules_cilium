"""Bzlmod extension for the maintainer-only chart fetch.

Mirrors the `version`-tag-class shape used by the public extension. Fires
only when rules_cilium is the root module — consumers don't pull the chart.
"""

load("//tools:repositories.bzl", "cilium_chart_repository")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),
})

def _impl(mctx):
    for mod in mctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.version:
            cilium_chart_repository(
                name = "cilium_chart_" + tag.version.replace(".", "_"),
                version = tag.version,
            )

cilium_chart = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
