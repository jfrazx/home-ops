# Unifi TLS passthrough — needs its own Gateway

## What happened

The `internal` Gateway (`kubernetes/apps/kube-system/cilium/gateway/internal.yaml`)
used to have a `unifi-tls` listener (TLS passthrough, port 443, hostname
`unifi-dashboard.${SECRET_DOMAIN}`) alongside the normal `https` listener
(Terminate, port 443, hostname `*.${SECRET_DOMAIN}`).

After the Cilium upgrade to v1.20.0 (2026-08-02), Cilium started correctly
enforcing the Gateway API rule that a Terminate and a Passthrough listener on
the same port must have non-overlapping hostnames. `*.${SECRET_DOMAIN}`
always overlaps `unifi-dashboard.${SECRET_DOMAIN}`, so both listeners on port
443 flipped to `Conflicted`/`Invalid`, the Gateway stopped programming port
443 at all, and **every HTTPRoute on the internal Gateway lost HTTPS access**
(36 routes affected).

Fix applied for now: removed the `unifi-tls` listener entirely. This restores
HTTPS for all normal internal HTTPRoutes. Unifi TLS passthrough is currently
**not exposed**.

## Pre-existing bug (unrelated to the Cilium upgrade)

Even before this, the passthrough listener never actually worked:
`unifi-tls` listener hostname was `unifi-dashboard.${SECRET_DOMAIN}`, but the
`TLSRoute` (`kubernetes/apps/network/unifi-controller/app/tlsroute.yaml`) uses
hostname `unifi.${SECRET_DOMAIN}`, matching the actual cert
(`app/certificate.yaml` only covers `unifi.${SECRET_DOMAIN}` /
`unifi-controller.${SECRET_DOMAIN}`). Gateway status confirmed
`attachedRoutes: 0` on `unifi-tls` — the hostnames never matched, so the
route never attached to the listener in the first place.

## Proper fix

Cilium's documented workaround for this exact Terminate+Passthrough-on-same-port
conflict is to split them across separate Gateways
(see [cilium/cilium#32292](https://github.com/cilium/cilium/issues/32292)).

1. Create a new Gateway (e.g. `internal-passthrough`) in
   `kubernetes/apps/kube-system/cilium/gateway/`, with a single TLS listener:
   - `protocol: TLS`, `port: 443`, `tls.mode: Passthrough`
   - `hostname: "unifi.${SECRET_DOMAIN}"` (matching the TLSRoute/cert, not the
     old, wrong `unifi-dashboard` hostname)
   - its own `addresses.value` IP — pool `pool`
     (`CiliumLoadBalancerIPPool`) has free IPs in `10.168.2.97-119`; `.98` and
     `.99` are already taken by `internal`/`external`, pick another free one.
   - `infrastructure.annotations["external-dns.alpha.kubernetes.io/hostname"]`
     set to the new Gateway's own hostname so external-dns can point
     `unifi.${SECRET_DOMAIN}` at the new IP.
2. Update `tlsroute.yaml`'s `parentRefs` to point at the new Gateway instead
   of `internal`/`unifi-tls`.
3. Verify: `kubectl get gateway internal-passthrough -n kube-system -o yaml`
   shows the listener `Programmed`, `attachedRoutes: 1`, and
   `https://unifi.${SECRET_DOMAIN}` reaches the controller with its own cert
   (passthrough, not the shared wildcard cert).
