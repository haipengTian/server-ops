# Optional Antigravity egress

This separate sing-box Compose project converts a server-local VLESS Reality
link to a SOCKS5 endpoint on CLIProxyAPI's existing Docker network. No host port
is published. The backend image and nginx configuration remain unchanged.

The supported input is one VLESS/TCP/Reality link with `xtls-rprx-vision`.
Other node protocols are not accepted by this helper. sing-box v1.14.3 is pinned
to its release manifest digest; the configuration was checked with that image
on Linux/amd64 using synthetic credentials.

Run as root after installing CLIProxyAPI:

```bash
cd /opt/server-ops/cliproxyapi
bash egress/setup.sh
bash egress/status.sh
```

Paste the VLESS link only at the hidden terminal prompt. Do not put it in a
shell command or chat, commit it, or print the generated configuration. Input
is not echoed or included in error messages. The helper validates the input
and runs `sing-box check` before replacing any existing configuration.

Configuration lives in `/opt/cliproxyapi/secrets/egress/config.json` by default:
directory 0700, file 0600, owner UID/GID 10001. The previous configuration, if
any, is retained as `config.previous.json`. Normal CLIProxyAPI backups already
include `secrets`. The dedicated proxy mounts this directory read-only with
SELinux relabeling; the application does not mount it.

`setup.sh` recreates only the proxy and does not change the application's proxy
settings. If proxy startup fails, inspect the separate project before changing
application settings. `status.sh` tests SOCKS5 connectivity and remote DNS from
the actual application container, then shows the egress IP reported by IPinfo.
This is a network check, not Google eligibility or model-call acceptance.

After the proxy check succeeds, set a target Antigravity credential's
`proxy_url` to `socks5://cliproxyapi-egress:1080` in its details editor. Start
with one credential and confirm the request selected that credential. An
account-specific proxy overrides the global proxy; `direct` forces direct
access. If a global proxy is desired later, use Configuration Panel's proxy
URL field (`requests.proxy-url` in v8 YAML).

Only containers attached to the existing dedicated backend network can reach
the unauthenticated SOCKS endpoint. Do not attach unrelated containers or add
`ports`/host networking. A successful proxy request does not establish that
Google accepts this egress IP; repeat the same-account/model test.

To stop using it, first clear the relevant account/global proxy settings, then:

```bash
export EGRESS_NETWORK_NAME=cliproxyapi-custom_backend
docker compose --env-file .env -f egress/compose.yml \
  -p cliproxyapi-custom-egress stop egress
```

Replace the network and project prefix if `COMPOSE_PROJECT_NAME` was customized.
To restore the previous node locally (after verifying that file exists):

```bash
cp -p /opt/cliproxyapi/secrets/egress/config.previous.json \
  /opt/cliproxyapi/secrets/egress/config.json
export EGRESS_NETWORK_NAME=cliproxyapi-custom_backend
docker compose --env-file .env -f egress/compose.yml \
  -p cliproxyapi-custom-egress up -d --force-recreate egress
bash egress/status.sh
```

Use the same `up -d --force-recreate egress` after restoring the secrets
directory from a backup: recreation rebinds the restored directory and applies
the correct SELinux label. Parent lifecycle
commands manage the application only; this separate proxy has its own
`unless-stopped` restart policy.
