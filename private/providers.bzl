"""Providers exported by rules_cilium."""

CiliumInfo = provider(
    doc = "The resolved Cilium install: pinned version + path to the " +
          "pre-rendered manifest YAML. Cilium installs into kube-system; " +
          "the namespace is captured here for downstream rules that want " +
          "to query Cilium pods.",
    fields = {
        "version": "Cilium version string, e.g. '1.16.5'.",
        "manifest": "File: the pre-rendered Cilium install YAML.",
        "namespace": "string: namespace Cilium installs into (always 'kube-system').",
    },
)
