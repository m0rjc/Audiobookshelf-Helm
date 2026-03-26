# Audiobookshelf Helm Chart

A Helm chart for deploying [Audiobookshelf](https://www.audiobookshelf.org/) — a self-hosted audiobook and podcast server — on [microk8s](https://microk8s.io/) Kubernetes clusters.

## Features

- **Rootless deployment** — runs as non-root user (UID 10500) with all Linux capabilities dropped
- **Network policies** — default-deny model with explicit allow rules for ingress and DNS
- **Persistent storage** — separate volumes for config and metadata with retain policy
- **Configurable media mount** — audiobook files mounted from the host; read-only by default but can be set to read-write if you want to use the Audiobookshelf upload feature
- **Health checks** — liveness and readiness probes on `/healthcheck`

## Prerequisites

- microk8s with the `dns`, `ingress`, and `metallb` addons enabled:
  ```bash
  microk8s enable dns ingress metallb
  ```
  When prompted, give metallb an IP range that is unused on your network and routable to the node (e.g. `192.168.100.1-192.168.100.64`).
- Audiobook files available on the host (default: `/srv/audiobooks`)
- Persistent storage directories created on the host:
  ```bash
  sudo mkdir -p /var/lib/audiobookshelf/config /var/lib/audiobookshelf/metadata
  sudo chown 10500:10500 /var/lib/audiobookshelf/config /var/lib/audiobookshelf/metadata
  ```

The UID and GID were chosen manually. I created entries in `/etc/passwd` and `/etc/group` for documentation
purposes on my system, rather than have anonymous users and groups. You
may wish to accept your Linux distributions defaulting when creating new system accounts. My system warned that
10500 was outside the `SYS_UID_MAX` range. If you use different IDs then set your values in `values.yaml`.


## Installation

```bash
helm install audiobookshelf ./audiobookshelf
kubectl apply -f ingress/metallb-service.yaml
```

The second command creates a LoadBalancer service that gives the nginx ingress controller a stable IP from the metallb pool (see [Why metallb?](#why-metallb) below).

## Configuration

Key values in [`values.yaml`](audiobookshelf/values.yaml):

| Parameter | Default | Description |
|---|---|---|
| `namespace` | `audiobookshelf` | Kubernetes namespace |
| `image.repository` | `ghcr.io/advplyr/audiobookshelf` | Container image |
| `image.tag` | `latest` | Image tag |
| `containerPort` | `13378` | Application port |
| `timezone` | `Europe/London` | Container timezone |
| `storage.audiobooks.hostPath` | `/srv/audiobooks` | Path to audiobook files on host |
| `storage.config.hostPath` | `/var/lib/audiobookshelf/config` | Config storage path |
| `storage.config.size` | `1Gi` | Config volume size |
| `storage.metadata.hostPath` | `/var/lib/audiobookshelf/metadata` | Metadata storage path |
| `storage.metadata.size` | `5Gi` | Metadata volume size |
| `ingress.enabled` | `true` | Enable nginx ingress |
| `ingress.hostname` | `audiobookshelf.local` | Ingress hostname |
| `networkPolicy.allowMetadataFetching` | `false` | Allow outbound internet for cover art/metadata |

Override values at install time:

```bash
helm install audiobookshelf ./audiobookshelf \
  --set ingress.hostname=audiobooks.example.com \
  --set timezone=America/New_York
```

## Network Policies

The chart applies a restrictive network policy by default:

- **All traffic denied** unless explicitly allowed
- **Ingress** permitted only from the `ingress` namespace
- **DNS** permitted to `kube-system` for service discovery
- **Internet egress** disabled by default — if your media files already contain embedded metadata and cover art, no outbound internet access is needed. Enable `networkPolicy.allowMetadataFetching` if you want Audiobookshelf to fetch cover art and metadata from online sources (Google Books, Audible, OpenLibrary, etc.). When enabled, this permits outbound HTTP/HTTPS (ports 80 and 443) to **all public IPs** (private ranges are excluded). This is broader than strictly necessary, but these metadata sources rely on CDNs with changing IPs, making IP-level restrictions impractical. For tighter control, DNS-based egress policies (supported by Cilium but not Calico) could restrict traffic to specific hostnames

> **Note:** Network policies require a CNI plugin that supports enforcement (e.g., Calico or Cilium). Claude says: "The default microk8s CNI does **not** enforce network policies — the resources will exist but have no effect.". My cluster is running Calico, which documentation suggests is default.

## Why metallb?

The microk8s ingress addon runs as a DaemonSet and uses `hostPort` to expose ports 80 and 443 on the node. `hostPort` relies on iptables NAT rules set up by the CNI portmap plugin. However, my cluster runs Calico in **eBPF mode** (`bpfConnectTimeLoadBalancing: TCP`), which bypasses iptables entirely. The portmap rules are never applied, so `hostPort` silently does nothing and port 80 is unreachable on the node IP.

metallb solves this by giving the ingress controller a proper LoadBalancer IP. The manifest in `ingress/metallb-service.yaml` creates a service that selects the ingress controller pods and requests a specific IP via the `metallb.universe.tf/loadBalancerIPs` annotation. metallb advertises this IP on the local network using L2 ARP, and Calico eBPF handles the service routing natively.

## Use in a Unifi Network with UDM Pro

My setup is a Unifi UDM Pro network. The metallb IP pool (`192.168.100.0/24`) is on a different subnet from the Kubernetes node, so the Unifi router needs a static route to reach it:

- **Destination:** `192.168.100.0/24`
- **Next hop:** the static IP of the Kubernetes node (e.g. `192.168.1.234`)

This is configured under Settings → Routing → Static Routes in the Unifi controller.

There is no access from outside my network. The web client was found to be perfectly adequate for listening at home on PC or mobile device.


## The .local domain and Apple clients

Apple devices such as iPhones use mDNS to resolve `.local` hostnames and will not use the Unifi DNS entries that work for other clients. Avahi on the Kubernetes node handles this by advertising the service via mDNS.

Install avahi-utils:

```
sudo apt update && sudo apt install avahi-utils -y
```

Create `/etc/systemd/system/avahi-alias@.service` with the following content. The `@` in the filename allows the substitution trick later:

```
[Unit]
Description=Publish %I as alias for %H.local via mDNS
After=avahi-daemon.service
Requires=avahi-daemon.service

[Service]
Type=simple
# -a: Publish an address record
# -R: No-reverse (prevents conflict with the main hostname)
ExecStart=/usr/bin/avahi-publish -a -R %I 192.168.100.1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

The IP is hardcoded to the metallb LoadBalancer address rather than the node's host IP — this is important because port 80 is not reachable on the node IP directly (see [Why metallb?](#why-metallb)).

Reload and enable the alias:

```
sudo systemctl daemon-reload
sudo systemctl enable --now avahi-alias@audiobookshelf.local.service
```

Verify it is working:

```
avahi-resolve -n audiobookshelf.local
systemctl list-units --type=service "avahi-alias*"
```

### mDNS across subnets

mDNS is link-local multicast and does not cross router boundaries. If your Apple devices are on a different network or VLAN from the Kubernetes node, you need to enable **mDNS reflection** (sometimes labelled "Device Discovery") in the Unifi network settings for each relevant network. This causes the Unifi router to relay mDNS traffic between subnets.


## Architecture

```
Client → Unifi router → metallb IP (192.168.100.1:80)
                              │  (L2 ARP + static route for 192.168.100.0/24)
                              ▼
                     nginx-ingress-lb Service
                              │  (LoadBalancer via metallb)
                              ▼
                     Nginx Ingress Controller
                              │  (routes audiobookshelf.local → audiobookshelf service)
                              ▼
                     audiobookshelf Service (:80)
                              │
                              ▼
                         Pod (:13378)
                           ├── /audiobooks  (host path)
                           ├── /config      (PV, 1Gi)
                           └── /metadata    (PV, 5Gi)
```

Apple clients resolve `audiobookshelf.local` via mDNS (avahi on the node), which points to the metallb IP.

## Uninstalling

```bash
helm uninstall audiobookshelf
```

Persistent volumes use a `Retain` reclaim policy, so config and metadata are preserved after uninstall.
