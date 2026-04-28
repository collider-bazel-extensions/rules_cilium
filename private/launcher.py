#!/usr/bin/env python3
"""Runtime launcher for cilium_install / cilium_health_check.

Same role as launcher.py in rules_pg / rules_temporal / rules_kind /
rules_playwright / rules_capsule / rules_certmanager. Owns:

- env setup (KUBECONFIG resolution; honor $KUBECTL from rules_kind's per-
  cluster env file before falling back to PATH)
- exec of `kubectl` against the resolved kubeconfig
- SIGTERM/SIGINT forwarding so itest can stop the long-running install
  service cleanly
- in install mode: applies the pinned Cilium manifest, then waits for the
  cilium DaemonSet (and operator Deployment) to become Ready before going
  to sleep — same pattern rules_certmanager v0.1.2 ported in to avoid
  downstream services racing on partial readiness
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time


def _resolve_runfiles(rel: str) -> str:
    rfd = os.environ.get("RUNFILES_DIR") or os.environ.get("TEST_SRCDIR")
    if not rfd:
        return rel
    candidate = os.path.join(rfd, "_main", rel)
    if os.path.exists(candidate):
        return candidate
    candidate = os.path.join(rfd, rel)
    if os.path.exists(candidate):
        return candidate
    return rel


def _kubeconfig_from_env(name: str) -> str | None:
    if name and os.environ.get(name):
        return os.environ[name]
    if os.environ.get("KUBECONFIG"):
        return os.environ["KUBECONFIG"]
    return None


def _resolve_kubectl() -> str | None:
    """Prefer `$KUBECTL` (set by rules_kind's per-cluster env file) over PATH."""
    cand = os.environ.get("KUBECTL")
    if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
        return cand
    return shutil.which("kubectl")


def _run(cmd: list[str], env: dict[str, str]) -> int:
    print("rules_cilium: " + " ".join(cmd), file=sys.stderr, flush=True)
    return subprocess.run(cmd, env=env).returncode


def _install(args, env: dict[str, str]) -> int:
    manifest = _resolve_runfiles(args.manifest)
    if not os.path.isfile(manifest):
        print(f"rules_cilium: manifest not in runfiles: {manifest}", file=sys.stderr)
        return 2

    kubectl = _resolve_kubectl()
    if not kubectl:
        print(
            "rules_cilium: kubectl not found. Set $KUBECTL (e.g. via "
            "rules_kind's env file) or put kubectl on $PATH.",
            file=sys.stderr,
        )
        return 127

    kubeconfig = _kubeconfig_from_env(args.kubeconfig_env)
    if not kubeconfig:
        print(
            f"rules_cilium: no kubeconfig — set ${args.kubeconfig_env} or $KUBECONFIG.",
            file=sys.stderr,
        )
        return 2
    env["KUBECONFIG"] = kubeconfig

    apply_cmd = [kubectl, "--kubeconfig", kubeconfig, "-n", args.namespace,
                 "apply", "-f", manifest, "--server-side=true",
                 "--validate=false"]
    rc = 1
    for attempt in (1, 2):
        rc = _run(apply_cmd, env)
        if rc == 0:
            break
        if attempt == 1:
            print(
                f"rules_cilium: apply attempt {attempt} failed; "
                f"retrying once after 5s.",
                file=sys.stderr,
            )
            time.sleep(5)
    if rc != 0:
        return rc

    # Wait for cilium DaemonSet and operator to be ready before idling.
    # Without this, downstream services (or the smoke test) hit a window
    # where Cilium is "applied" but pod networking isn't yet functional —
    # any test pod that comes up before this point will be Pending until
    # the CNI is ready. Blocking here gives that machinery time to settle.
    print(f"rules_cilium: waiting for cilium DaemonSet in {args.namespace}",
          file=sys.stderr, flush=True)
    rc = _run(
        [kubectl, "--kubeconfig", kubeconfig, "-n", args.namespace,
         "rollout", "status", "ds/cilium", "--timeout=300s"],
        env,
    )
    if rc != 0:
        return rc
    rc = _run(
        [kubectl, "--kubeconfig", kubeconfig, "-n", args.namespace,
         "rollout", "status", "deploy/cilium-operator", "--timeout=300s"],
        env,
    )
    if rc != 0:
        return rc

    print("rules_cilium: install applied; sleeping until SIGTERM",
          file=sys.stderr, flush=True)
    while True:
        time.sleep(3600)


def _health_check(args, env: dict[str, str]) -> int:
    kubectl = _resolve_kubectl()
    if not kubectl:
        print("rules_cilium: kubectl not found.", file=sys.stderr)
        return 127

    kubeconfig = _kubeconfig_from_env(args.kubeconfig_env)
    if not kubeconfig:
        print(
            f"rules_cilium: no kubeconfig — set ${args.kubeconfig_env} or $KUBECONFIG.",
            file=sys.stderr,
        )
        return 2
    env["KUBECONFIG"] = kubeconfig

    ns = args.namespace
    # Three-step probe: CRDs registered (proves the manifest finished
    # applying), DaemonSet pods all Ready, operator Available.
    rc = _run(
        [kubectl, "--kubeconfig", kubeconfig, "get", "crd",
         "ciliumnetworkpolicies.cilium.io", "-o", "name"],
        env,
    )
    if rc != 0:
        return rc
    rc = _run(
        [kubectl, "--kubeconfig", kubeconfig, "-n", ns, "rollout", "status",
         "ds/cilium", "--timeout=0s"],
        env,
    )
    if rc != 0:
        return rc
    rc = _run(
        [kubectl, "--kubeconfig", kubeconfig, "-n", ns, "wait",
         "deploy/cilium-operator", "--for=condition=Available", "--timeout=0s"],
        env,
    )
    return rc


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["install", "health_check"], required=True)
    ap.add_argument("--manifest", default="")
    ap.add_argument("--namespace", default="kube-system")
    ap.add_argument("--kubeconfig-env", default="KUBECONFIG")
    args = ap.parse_args(argv[1:])

    env = os.environ.copy()

    if args.mode == "install":
        proc_func = lambda: _install(args, env)
    else:
        proc_func = lambda: _health_check(args, env)

    def handle(_signum, _frame):
        sys.exit(143)

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    return proc_func() or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
