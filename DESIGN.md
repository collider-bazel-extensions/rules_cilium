# rules_cilium — design decisions

Hermetic [Cilium](https://cilium.io/) CNI install + readiness for Bazel
tests. Composes with `rules_kind` (cluster must be created with the default
CNI disabled — see decision #6) and `rules_itest`.

The primary motivator is **NetworkPolicy enforcement testing**. kind's
default CNI (`kindnet`) does not enforce NetworkPolicy, so any Bazel test
that wants to verify cross-pod / cross-tenant isolation needs a real CNI.
Cilium is the most capable choice; this rule set is the smallest path to
"NetworkPolicy actually denies traffic" being assertable in a Bazel test.

All decisions inherited from the sibling
`rules_pg`/`rules_temporal`/`rules_kind`/`rules_playwright`/`rules_capsule`/`rules_certmanager`
family. Cilium-specific divergences are flagged.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | rules_capsule precedent |
| 2 | Module extension shape | One tag class: `version` (download). No `system` mode — Cilium is an in-cluster operator, not a host CLI. | rules_capsule |
| 3 | Toolchain type | `CILIUM_TOOLCHAIN_TYPE = Label("//toolchain:cilium")`. `ToolchainInfo(cilium = …)` carries the pinned manifest. | All siblings |
| 4 | Manifest provisioning | Cilium chart **pre-rendered** by `tools/render_cilium.sh` into `private/manifests/cilium-<ver>.yaml`. Sha256-pinned; committed. Helm is **not** required at consumer test time. | rules_capsule pattern (Cilium chart is helm-only — the project's `quick-install.yaml` exists but lags chart releases). |
| 5 | Public surface | `cilium_install`, `cilium_health_check` + `CiliumInfo` provider. CRs (`CiliumNetworkPolicy`, etc.) are consumer-authored YAML; no rule for them in v0.1. | All siblings |
| 6 | Cluster prereq | **Consumer must disable kind's default CNI.** The kind config needs `networking.disableDefaultCNI: true` (and optionally `kubeProxyMode: none` for Cilium's kube-proxy replacement). Without this, kindnet runs alongside Cilium and the cluster's behavior is undefined. v0.1.0 documented this; v0.1.1 ships `config/kind-cilium.yaml` as a public exported `filegroup` (`@rules_cilium//config:kind_cilium_config`) that consumers reference directly. | Cilium-specific divergence |
| 7 | rules_itest integration | `cilium_install` produces an `itest_service.exe`-shaped target (long-running `kubectl apply` + `kubectl wait` for DaemonSet ready); `cilium_health_check` is the readiness probe. **No pass-through `services=` attr.** | All siblings |
| 8 | rules_kind dependency | **Examples-only.** The rule itself depends on neither `rules_kind` nor any cluster-provider rule; just needs `KUBECONFIG` (or env-var-named-kubeconfig). | rules_capsule precedent |
| 9 | Platform matrix v1 | Platform-independent (kubectl + YAML). Validated on Linux x86_64; macOS pending. | rules_capsule |
| 10 | MODULE deps (consumer-visible) | `bazel_skylib`, `platforms`, `rules_python`. **No `rules_oci`, no `rules_helm`.** rules_kind / rules_itest / rules_shell are dev-only for the smoke test. | rules_capsule |
| 11 | Default test tags | `["cilium"]`; internal wrapper rules tagged `manual`. Smoke tests also `["requires-network", "no-sandbox"]`. | All siblings |
| 12 | Naming | snake_case rules, `MixedCaseInfo` providers, `UPPER_SNAKE` constants. | All siblings |
| 13 | Update workflow | `tools/render_cilium.sh <chart-version>` requires host helm. Adds `helm repo add cilium https://helm.cilium.io/`, pulls, renders with `--kube-version 1.29.0 --include-crds --set hubble.enabled=false`, writes `private/manifests/cilium-<ver>.yaml`. See decisions #16 and #17 for the two render flags. | rules_capsule pattern |
| 14 | Runtime lifecycle | One Python `private/launcher.py`: env setup, kubectl exec, SIGTERM forwarding. Install path waits for cilium DaemonSet to be Available before idling — same Deployments-Available-blocks-idle pattern that rules_certmanager v0.1.2 ported in. | rules_certmanager v0.1.2 precedent |
| 15 | kubectl provisioning | **Host kubectl required**, OR `$KUBECTL` env (set by rules_kind's per-cluster env file). | rules_capsule precedent |
| 16 | `--kube-version 1.32.0` at render time | Cilium 1.16.5's chart guards `securityContext.appArmorProfile` (and a handful of other 1.30+ fields) with `semverCompare ">=1.30" .Capabilities.KubeVersion`. `helm template` defaults to a stub kube version that trips those guards inconsistently. Pinning to 1.32.0 matches the kindest/node image the smoke test runs against (rules_kind v0.1.2 added k8s 1.32 specifically because kindest/node:v1.32.2 ships runc 1.2.5, fixing the bind-mount-remount-RO EPERM bug under rootless podman + kernel 6.x that breaks Cilium's agent on the older v1.29.2 image). Bump in lockstep when rules_kind ships a newer node image. | Cilium-specific |
| 18 | rules_kind ≥ 0.1.2 | The smoke test pins `k8s_version = "1.32"` because Cilium's agent and several core k8s components (`kube-proxy`, etc.) trigger a runc 1.1.x bind-mount bug on modern kernels. rules_kind v0.1.2 added k8s 1.32 (kind v0.27.0 + kindest/node:v1.32.2 + kubectl 1.32.2) for exactly this reason; older rules_kind versions only ship 1.29 and won't work. | Cilium-specific |
| 17 | `--set hubble.enabled=false` at render time | The chart self-signs a Hubble CA + server cert via `genCA`/`genSignedCert` on every render, so `secret/cilium-ca` and `secret/hubble-server-certs` churn and the manifest sha is never stable. Disabling Hubble produces a deterministic render. The smoke test only asserts NetworkPolicy enforcement; Hubble (observability) is out of scope for v0.1 and will be re-enabled in a later release once we pin a fixed CA via values. | Cilium-specific |

## Cilium-specific notes

- **Cilium installs into `kube-system`** (not its own namespace). The chart's templates target `kube-system` by default; we render with `--namespace kube-system`.
- **Render values**. v0.1 renders the chart with two overrides only: `--kube-version 1.29.0` (decision #16) and `--set hubble.enabled=false` (decision #17). This produces a Cilium that uses kubelet-allocated CIDRs (`ipam.mode: cluster-pool`) and runs alongside kube-proxy. For Cilium-as-kube-proxy-replacement (KPR) mode or Hubble-on, consumers will need a render variant — deferred.
- **NetworkPolicy enforcement is tested via `kubectl exec` connectivity probes** in the smoke test, not just by checking Cilium pods are Running. This is the assertion that makes rules_cilium worth shipping.

## v0.1.0 status (planning)

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | planned |
| Module extension (`version` only) | planned |
| Pinned Cilium 1.16.5 (rendered, sha256-pinned) | planned |
| `cilium_install`, `cilium_health_check` rules | planned |
| `launcher.py` | planned |
| Analysis tests | planned |
| In-tree smoke test (kind w/o default CNI + Cilium + NetworkPolicy enforcement assertion) | planned |
| `tools/render_cilium.sh` | planned |
| End-to-end runtime | planned (validated locally; macOS pending) |

## Deferred

- **Cilium as kube-proxy replacement** (KPR mode). Different render values; v0.1.x.
- **Cluster mesh / multi-cluster** topology. Out of scope for v1.
- **CR-shaped rules** (`cilium_network_policy`, etc.). Consumers author YAML.
- **Hermetic kubectl.**
- **Hermetic Cilium CLI** (`cilium status`, `cilium connectivity test`). Useful but heavy; not v0.1.
- ~~Reference kind config as exported file.~~ Shipped in v0.1.1 — see decision #6.
