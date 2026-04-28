"""cilium_toolchain — exposes the pinned, sha256-pinned Cilium install
manifest as a `ToolchainInfo` so consumer rules (`cilium_install`,
`cilium_health_check`) can resolve it without depending on the manifest's
specific path.
"""

load("//private:providers.bzl", "CiliumInfo")

CILIUM_TOOLCHAIN_TYPE = Label("//toolchain:cilium")

def _toolchain_impl(ctx):
    info = CiliumInfo(
        version = ctx.attr.version,
        manifest = ctx.file.manifest,
        namespace = ctx.attr.namespace,
    )
    return [
        platform_common.ToolchainInfo(cilium = info),
        DefaultInfo(files = depset([ctx.file.manifest])),
    ]

cilium_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "manifest": attr.label(allow_single_file = True, mandatory = True),
        "manifest_sha256": attr.string(
            doc = "Recorded for diagnostics; sha256 verification happens at " +
                  "manifest-render time, not at toolchain resolution.",
        ),
        "namespace": attr.string(
            default = "kube-system",
            doc = "Namespace Cilium's manifest installs into. Always " +
                  "'kube-system' — the chart hard-codes it.",
        ),
    },
)
