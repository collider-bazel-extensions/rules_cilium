"""Bzlmod extension. Same shape as rules_capsule / rules_certmanager."""

load("//private:repositories.bzl", "cilium_version_repository")

_version_tag = tag_class(attrs = {
    "name": attr.string(default = "cilium"),
    "version": attr.string(mandatory = True),
})

def _impl(mctx):
    # Only honor `version` tags from the root module. Without this guard,
    # rules_cilium's own `cilium.version()` call (needed for its in-tree
    # smoke test) and a downstream consumer's call would each try to emit
    # a `@cilium` repo with the same name and Bazel would collide them.
    # Mirrors rules_certmanager v0.1.1's fix for the same issue.
    for mod in mctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.version:
            cilium_version_repository(name = tag.name, version = tag.version)

cilium = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
