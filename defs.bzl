"""Public API for rules_cilium."""

load("//private:cilium_health_check.bzl", _cilium_health_check = "cilium_health_check")
load("//private:cilium_install.bzl", _cilium_install = "cilium_install")
load("//private:providers.bzl", _CiliumInfo = "CiliumInfo")

cilium_install = _cilium_install
cilium_health_check = _cilium_health_check

CiliumInfo = _CiliumInfo
