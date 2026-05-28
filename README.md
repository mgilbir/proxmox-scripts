# proxmox-scripts

Helper scripts for Proxmox VE, in the style of the
[community-scripts](https://github.com/community-scripts/ProxmoxVE) add-ons.

## `tools/addon/add-caddy-proxy-lxc.sh`

Installs [Caddy](https://caddyserver.com/) into an **existing** LXC container
and configures it as a reverse proxy for a domain, forwarding to a local port
inside that container. TLS is provisioned automatically via Let's Encrypt.

Run it **on the Proxmox VE host** (interactive — use a real terminal):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mgilbir/proxmox-scripts/main/tools/addon/add-caddy-proxy-lxc.sh)"
```

It will:

1. Let you pick a running container (`whiptail` list of `pct list`).
2. Prompt for the domain, the local port to proxy to (`localhost:PORT`), and
   the Let's Encrypt challenge method.
3. Install Caddy if it isn't already present (Debian/Ubuntu via the official
   apt repo; Alpine via `apk`).
4. Write a per-domain file under `/etc/caddy/sites/<domain>.caddy`, imported by
   `/etc/caddy/Caddyfile`. Re-run it to add more domains.
5. Validate the config, reload Caddy, and tag the container `caddy`.

### TLS challenge methods

| Method | When to use |
| --- | --- |
| **HTTP / TLS-ALPN** | The host is publicly reachable on ports 80/443. |
| **DNS-01** | The host is **not** publicly reachable (e.g. the domain's A record points to a Tailscale `100.x` address). Caddy proves ownership through your DNS provider's API, so no inbound access is needed. |

For DNS-01 the script installs the matching
[`caddy-dns`](https://github.com/caddy-dns) plugin via `caddy add-package`
(Debian/Ubuntu only — on Alpine, build with `xcaddy` first) and stores API
credentials in `/etc/caddy/caddy.env` (`chmod 600`), loaded through a systemd
`EnvironmentFile` drop-in and referenced from the Caddyfile via `{env.*}`
placeholders so secrets never land in the site files.

Built-in providers: **Cloudflare, DNSimple, Gandi, DigitalOcean, Hetzner,
deSEC, Porkbun, AWS Route 53**, plus a **manual** option to point at any other
`caddy-dns` module.

### Removing a proxy

Delete the site file inside the container and reload Caddy:

```bash
rm /etc/caddy/sites/<domain>.caddy
systemctl reload caddy
```
