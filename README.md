# Audiobookshelf Helm Chart

A Helm chart for deploying [Audiobookshelf](https://www.audiobookshelf.org/) — a self-hosted audiobook and podcast server — on [microk8s](https://microk8s.io/) Kubernetes clusters.

## Features

- **Rootless deployment** — runs as non-root user (UID 10500) with all Linux capabilities dropped
- **Network policies** — default-deny model with explicit allow rules for ingress and DNS
- **Persistent storage** — separate volumes for config and metadata with retain policy
- **Read-only media mount** — audiobook files mounted read-only from the host
- **Health checks** — liveness and readiness probes on `/healthcheck`

## Prerequisites

- microk8s with the `dns` and `ingress` addons enabled:
  ```bash
  microk8s enable dns ingress
  ```
- Audiobook files available on the host (default: `/srv/audiobooks`)
- Persistent storage directories created on the host:
  ```bash
  sudo mkdir -p /var/lib/audiobookshelf/config /var/lib/audiobookshelf/metadata
  sudo chown 10500:10500 /var/lib/audiobookshelf/config /var/lib/audiobookshelf/metadata
  ```

## Installation

```bash
helm install audiobookshelf ./audiobookshelf
```

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
- **Internet egress** disabled by default — enable `networkPolicy.allowMetadataFetching` if you want Audiobookshelf to fetch cover art and metadata from the internet. When enabled, this permits outbound HTTP/HTTPS (ports 80 and 443) to **all public IPs** (private ranges are excluded). This is broader than strictly necessary, but the metadata sources Audiobookshelf uses (Google Books, Audible, OpenLibrary, etc.) rely on CDNs with changing IPs, making IP-level restrictions impractical. For tighter control, DNS-based egress policies (supported by Cilium but not Calico) could restrict traffic to specific hostnames

> **Note:** Network policies require a CNI plugin that supports enforcement (e.g., Calico or Cilium). The default microk8s CNI does **not** enforce network policies — the resources will exist but have no effect. To enable enforcement on microk8s, run:
> ```bash
> microk8s enable network
> ```

## Architecture

```
Internet → Nginx Ingress → Service (:80) → Pod (:13378)
                                              ├── /audiobooks  (host, read-only)
                                              ├── /config      (PV, 1Gi)
                                              └── /metadata    (PV, 5Gi)
```

## Uninstalling

```bash
helm uninstall audiobookshelf
```

Persistent volumes use a `Retain` reclaim policy, so config and metadata are preserved after uninstall.
