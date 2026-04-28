# rules_cilium

Hermetic [Cilium](https://cilium.io/) CNI install + readiness for Bazel
tests. Drops into [`rules_itest`](https://github.com/dzbarsky/rules_itest)
and composes with [`rules_kind`](https://github.com/collider-bazel-extensions/rules_kind)
(or any cluster the consumer provides via `KUBECONFIG`).

The motivator is **NetworkPolicy enforcement testing**. kind's default CNI
(`kindnet`) does not enforce NetworkPolicy, so any Bazel test that wants to
verify cross-pod / cross-tenant isolation needs a real CNI. Cilium is the
most capable choice; this rule set is the smallest path to "NetworkPolicy
actually denies traffic" being assertable in a Bazel test.

**Supported platforms (v0.1):** Linux (x86\_64). macOS untested but the
rule is platform-independent (just kubectl + a static YAML). See
[Contributing](#contributing).

**Pinned versions:** Cilium 1.16.5. The chart is pre-rendered by
`tools/render_cilium.sh` and committed under `private/manifests/` —
**no `helm` is required at consumer test time**.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Cluster requirement](#cluster-requirement-disable-the-default-cni)
- [Rules](#rules)
  - [cilium\_install](#cilium_install)
  - [cilium\_health\_check](#cilium_health_check)
- [`rules_itest` integration](#rules_itest-integration)
- [Providers](#providers)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Local-dev caveat: Cilium under rootless container engines](#local-dev-caveat-cilium-under-rootless-container-engines)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_cilium", version = "0.1.0")

cilium = use_extension("@rules_cilium//:extensions.bzl", "cilium")
cilium.version(version = "1.16.5")
use_repo(cilium, "cilium")

register_toolchains("@cilium//:all")
```

`rules_cilium` is **Bzlmod-only** in v0.1. Until it lands in BCR, consume
via `archive_override` or a git pin pointing at a tag.

For the in-tree smoke test composition, you also need
[`rules_kind`](https://github.com/collider-bazel-extensions/rules_kind)
**≥ 0.1.2** (which adds k8s 1.32 — required because of a runc 1.1.x bug
on the older 1.29 node image, see
[caveat](#local-dev-caveat-cilium-under-rootless-container-engines)).

---

## Quickstart

```python
load("@rules_cilium//:defs.bzl", "cilium_install", "cilium_health_check")

# Long-running: applies the pinned Cilium manifest into kube-system on
# whatever cluster `$KUBECONFIG` points at, then waits for ds/cilium and
# deploy/cilium-operator to be Available.
cilium_install(name = "cilium")

# Readiness: the CiliumNetworkPolicy CRD is registered + the agent
# DaemonSet is rolled out + the operator Deployment is Available.
cilium_health_check(name = "cilium_health")
```

The rule itself doesn't bring up a cluster — it just installs Cilium into
one you already have. For a kind-based composition that asserts
NetworkPolicy actually enforces, see
[`rules_itest` integration](#rules_itest-integration) and the in-tree
`tests/smoke_test.sh`.

---

## Cluster requirement: disable the default CNI

Cilium replaces the cluster's CNI. Under `kind`, the default `kindnet`
DaemonSet must be **disabled** in the kind config — otherwise kindnet
runs alongside Cilium and routing/policy enforcement is undefined:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
```

Pass it to `kind_cluster` via the `config` attr:

```python
kind_cluster(
    name = "cluster",
    k8s_version = "1.32",         # see caveat below — 1.29 won't work
    config = "kind-config.yaml",
)
```

(See `tests/kind-config.yaml` for the exact reference.)

---

## Rules

### `cilium_install`

```python
cilium_install(
    name = "cilium",
    kubeconfig_env = "KUBECONFIG",
)
```

`kubectl apply --server-side -f` of the toolchain's pinned Cilium manifest
into `kube-system`, then waits for `ds/cilium` rollout and the
`deploy/cilium-operator` Available condition before idling. Two-pass apply
with retry to handle transient CRD-registration races (the chart doesn't
ship CRDs; cilium-operator registers them at runtime, so the first apply
of a CR may race the operator startup).

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `kubeconfig_env` | `string` | `"KUBECONFIG"` | Env var holding the kubeconfig path. Under `rules_kind` + `rules_itest` you typically point this at whatever `kind_cluster`'s env file exports (often just `KUBECONFIG` after sourcing). |

### `cilium_health_check`

```python
cilium_health_check(
    name = "cilium_health",
)
```

Three-step probe: (1) the `ciliumnetworkpolicies.cilium.io` CRD is
registered (proves cilium-operator started); (2) `ds/cilium` rollout is
complete (the agent is enforcing on every node); (3)
`deploy/cilium-operator` is `Available=True`. `rules_itest` retries until
success or timeout.

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `kubeconfig_env` | `string` | `"KUBECONFIG"` | Env var holding the kubeconfig path. |

---

## `rules_itest` integration

`rules_cilium` integrates by emitting `itest_service.exe` / `health_check`-shaped
targets. Composition is the consumer's job — no pass-through `services=`
attr, matching the
`rules_pg`/`rules_temporal`/`rules_kind`/`rules_playwright`/`rules_capsule`/`rules_certmanager`
convention.

The in-tree smoke test is the canonical reference. Composition shape:

```python
load("@rules_cilium//:defs.bzl", "cilium_install", "cilium_health_check")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. The cluster — kindnet disabled (see above).
kind_cluster(
    name = "cluster",
    k8s_version = "1.32",
    config = "kind-config.yaml",
)
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Cilium.
cilium_install(name = "cilium_bin")
cilium_health_check(name = "cilium_health_bin")

# 3. Wrappers that bind the cluster-source-agnostic rule binaries to the
#    specific rules_kind cluster (source the env file with `set -a` so
#    KUBECONFIG/KUBECTL cross the `exec` boundary).
sh_binary(
    name = "cilium_install_wrapper",
    srcs = ["cilium_install_wrapper.sh"],
    data = [":cilium_bin"],
)
sh_binary(
    name = "cilium_health_wrapper",
    srcs = ["cilium_health_wrapper.sh"],
    data = [":cilium_health_bin"],
)
itest_service(
    name = "cilium_svc",
    exe = ":cilium_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":cilium_health_wrapper",
)
```

The `tests/` directory has the wrapper shell scripts and an end-to-end
test that applies a `client` Pod, a `server` Pod, and a `NetworkPolicy`
that denies all egress from `client` — then asserts the connection
actually breaks. This is the assertion that justifies pulling Cilium in:
kindnet would silently let traffic through.

---

## Providers

### `CiliumInfo`

| Field | Type | Description |
|---|---|---|
| `version` | `string` | Cilium version, e.g. `"1.16.5"` |
| `manifest` | `File` | The pre-rendered, sha256-verified manifest (chart rendered with `--kube-version 1.32.0 --set hubble.enabled=false`). |
| `namespace` | `string` | Always `"kube-system"` (the chart targets it by default). |

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Cilium manifest | Fully hermetic. Pre-rendered by `tools/render_cilium.sh` from the upstream helm chart and committed under `private/manifests/`. sha256 pinned in `private/versions.bzl`. | Update via `bash tools/render_cilium.sh <version> --update`. Requires host `helm` 3.x — only at maintainer side. |
| `kubectl` | **Not vendored.** v0.1 honors `$KUBECTL` env (set by `rules_kind`'s per-cluster env file) and falls back to `$PATH`. | Future: bundle a hermetic kubectl via toolchain. |
| Target cluster | Out of scope — bring your own (`rules_kind`, real cluster, etc.). | The rule reads `KUBECONFIG` from env. |
| Cilium container images | **Pulled at runtime** by the cluster's nodes. Not pre-loaded. | Future: optional `images = [...]` attr for pre-loading via `kind_cluster.images`. |
| Hubble (observability) | **Disabled** in the rendered manifest. | Re-enabling requires pinning the self-signed Hubble TLS so the manifest sha is stable; deferred. |

---

## Local-dev caveat: Cilium under rootless container engines

Cilium's agent DaemonSet has an init container (`mount-bpf-fs`) that runs
`mount -t bpf bpffs /sys/fs/bpf` *inside* the kind node. Under **rootless
container engines** (rootless Docker, rootless Podman) the kind node runs
in a user namespace that does not grant CAP_SYS_ADMIN against the host
kernel for filesystem-type mounts, so the mount returns `EPERM` and the
agent stays in `Init:Error`.

The in-tree smoke test therefore does **not** pass under rootless Podman
or rootless Docker. To run it locally:

- **Rootful Docker** (the default `dockerd` setup on Linux) — works.
- **Rootful Podman** — `sudo podman …` works.
- **CI on GitHub Actions** uses rootful Docker by default — the workflow
  in `.github/workflows/ci.yml` exercises the smoke job there.

Analysis tests + the smoke composition build still work fine under
rootless engines. Only the live smoke run needs rootful access.

This is also why the rule set requires **rules_kind ≥ 0.1.2 / k8s 1.32**:
the older `kindest/node:v1.29.2` ships runc 1.1.12, which has an unrelated
bind-mount-remount-RO `EPERM` bug on Linux kernel 6.x that kills
`kube-proxy` and Cilium's agent under any rootless engine. `kindest/node:v1.32.2`
ships runc 1.2.5 and is unaffected — so on rootless engines you'd hit
*two* walls instead of one without the bump.

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned Cilium version: `bash tools/render_cilium.sh <new-version> --update`.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted: macOS validation

The rule is platform-independent (kubectl + static YAML), but no one has
run the smoke test on Darwin. A green smoke run on macOS — even a pasted
log from `bazel test //tests:smoke_test` — would unblock the macOS
support claim. Filing an issue with the result is plenty.
