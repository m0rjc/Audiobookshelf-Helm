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

The UID and GID were chosen manually. I created entries in `/etc/passwd` and `/etc/group` for documentation
purposes on my system, rather than have anonymous users and groups. You
may wish to accept your Linux distributions defaulting when creating new system accounts. My system warned that
10500 was outside the `SYS_UID_MAX` range. If you use different IDs then set your values in `values.yaml`.


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
- **Internet egress** disabled by default — if your media files already contain embedded metadata and cover art, no outbound internet access is needed. Enable `networkPolicy.allowMetadataFetching` if you want Audiobookshelf to fetch cover art and metadata from online sources (Google Books, Audible, OpenLibrary, etc.). When enabled, this permits outbound HTTP/HTTPS (ports 80 and 443) to **all public IPs** (private ranges are excluded). This is broader than strictly necessary, but these metadata sources rely on CDNs with changing IPs, making IP-level restrictions impractical. For tighter control, DNS-based egress policies (supported by Cilium but not Calico) could restrict traffic to specific hostnames

> **Note:** Network policies require a CNI plugin that supports enforcement (e.g., Calico or Cilium). Claude says: "The default microk8s CNI does **not** enforce network policies — the resources will exist but have no effect.". My cluster is running Calico, which documentation suggests is default.

## Use in a Unifi Network with UDM Pro

My setup is a Unifi UDM Pro network. My Kubernetes node already has a static IP address assigned. All I had to do was add a new DNS entry for `audiobookshelf.local` resolving to that static IP. This makes
the audiobooks accessible from my home network. There is no access from outside my network.

The web client was found to be perfectly adequate for listening at home on PC or mobile device.


## The .local domain and Apple clients

Apple devices such as IPhones require mDNS setup to resolve hosts in the local domain. 

Install acahi-utils:

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
# The subshell fetches the current local IP dynamically
ExecStart=/bin/bash -c "/usr/bin/avahi-publish -a -R %I $(ip route get 1 | awk '{print $7;exit}')"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Reload and enable the alias

```
sudo systemctl daemon-reload
sudo systemctl enable --now avahi-alias@audiobookshelf.local.service
```

This can be checked using the `avahi-resolve` command, or normal networking tools if your system is set up to use mDNS in its name resolution (`/etc/nsswitch.conf`)

```
avahi-resolve -n audiobookshelf.local
```

To check systemd use

```
systemctl list-units --type=service "avahi-alias*"
```


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
