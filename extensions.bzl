"""Bzlmod extension. Same shape as rules_capsule / rules_certmanager."""

load("//private:repositories.bzl", "cilium_version_repository")
load("//private:versions.bzl", "CILIUM_VERSIONS")

_version_tag = tag_class(attrs = {
    "name": attr.string(default = "cilium"),
    "version": attr.string(mandatory = True),
})

def _versions_by_name(mod):
    """{repo name: version} from one module's tags; conflicting versions fail."""
    out = {}
    for tag in mod.tags.version:
        if tag.name in out and out[tag.name] != tag.version:
            fail("rules_cilium: module {} sets cilium.version(name = \"{}\") to both {} and {}; set one.".format(
                mod.name,
                tag.name,
                out[tag.name],
                tag.version,
            ))
        out[tag.name] = tag.version
    return out

def _impl(mctx):
    # The extension runs once for the whole build and sees every module's
    # tags, but the repos it creates are global, so each name is created
    # once. rules_cilium's own MODULE.bazel imports `@cilium` and registers
    # its toolchain for every consumer, so its own tags always apply (a root
    # without cilium.version() used to fail: `does not generate repository
    # "cilium"`); the root module's tags override them by name and may add
    # names. Other modules' tags are ignored.
    repos = {}
    for mod in mctx.modules:
        if mod.name == "rules_cilium" and not mod.is_root:
            repos.update(_versions_by_name(mod))
    for mod in mctx.modules:
        if mod.is_root:
            repos.update(_versions_by_name(mod))
    for name, version in repos.items():
        if version not in CILIUM_VERSIONS:
            fail("rules_cilium: cilium.version(version = \"{}\") is not supported. Supported: {}".format(
                version,
                ", ".join(sorted(CILIUM_VERSIONS.keys())),
            ))
        cilium_version_repository(name = name, version = version)

cilium = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
