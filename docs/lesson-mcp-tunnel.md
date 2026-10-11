# Lesson MCP tunnel

`nixos/lesson-mcp` puts file_host's MCP endpoint on the internet so that
claude.ai, ChatGPT or Claude Code can call it for you once you have approved
them. It exposes nothing else. The design is in paulgsc/server's
`docs/identity.md`, "AI services acting for a subject". This page covers the
box's side of it.

```
AI service ──TLS──▶ Tailscale Funnel relay ──same encrypted bytes──▶ tailscaled on this box
                    (cannot decrypt)                                  (holds the certificate)
                                                                            │ decrypted here
                          Caddy on 127.0.0.1:8787 ── 5 exact paths ──▶ file_host on 127.0.0.1:3000
                                                  └─ anything else ──▶ 404
```

The box dials out to Tailscale; nothing is opened on the router or the
firewall, and the public name points at Tailscale's relays, not your home
address.

## What crosses, and what does not

| Path | Who calls it |
|---|---|
| `GET /.well-known/oauth-authorization-server` | the AI service, to find the token endpoint |
| `GET /.well-known/oauth-protected-resource/api/v1/mcp` | the AI service, after a 401 from `/mcp` |
| `POST /api/v1/oauth/register` | the AI service, once |
| `POST /api/v1/oauth/token` | the AI service, for a code or a refresh |
| `POST /api/v1/mcp` | the AI service, with a token |

The approval page (`https://nixos.local:5173/connect`) and the routes it calls
(`/api/v1/oauth/authorize/requests/*`, `/api/v1/oauth/grants`) do not cross.
Your passkeys are bound to `nixos.local`, so you approve each service once,
from home.

The paths are compared exactly as sent: case matters, and no wildcards or
dot-segment cleaning apply. Caddy's own `path` matcher cleans a path before it
compares (`/api/v1/shelf/../mcp` matches `/api/v1/mcp`) but proxies the path
uncleaned, which would let a crafted path reach a route behind the gate.

### Invariants

- **LM1:** only those five paths reach file_host through Funnel. Everything
  else is a 404 from Caddy.
- **LM2:** Funnel's origin (Caddy, port 8787) listens on loopback only.
- **LM3:** no caller's address reaches file_host, a log on this box, or
  Tailscale's log servers.
  - `tailscaled` sets `X-Forwarded-For` to the caller, and Caddy drops it
    along with the other address headers.
  - The Caddy site keeps no access log. NixOS's Caddy writes one per host by
    default, with request headers.
  - `tailscaled` uploads no logs (`TS_NO_LOGS_NO_SUPPORT`).
  - Its few log lines that print a Funnel caller's address (error paths in
    `ipn/ipnlocal/serve.go`) are dropped before the journal stores them
    (`LogFilterPatterns`).
- **LM4:** retired with the Cloudflare Tunnel. There is no tunnel credential
  to place; `tailscaled` keeps its node key in its own state.
- **LM5:** Funnel is on only while the module is. `tailscaled` persists the
  setting, so the `lesson-mcp-funnel` unit turns it off when it stops, and a
  rebuild that removes the unit stops it.

- **LM6:** joining the tailnet opens no port to tailnet devices. By default
  `tailscaled` adds `-i tailscale0 -j ACCEPT` ahead of the NixOS firewall,
  which would let every device in the tailnet reach every port on the box:
  Redis, `file_host`'s operator routes, NATS. The module runs it with
  `--netfilter-mode=off`, so the NixOS firewall alone governs `tailscale0`.
  It admits LAN ports only from `10.0.0.0/24`, and tailnet addresses are
  `100.64.0.0/10`. Funnel is unaffected: `tailscaled` handles its connections
  in its own userspace network stack, before the kernel firewall sees them.

`checks.x86_64-linux.lesson-mcp-gate` (CI, "lesson MCP gate") does three
things:
- It runs Caddy on the rendered site and probes 27 paths and the address
  headers, covering LM1 and LM3's header half.
- It asserts LM2, LM3's upload half, LM5 and LM6 on the rendered units.
- It reads the pinned tailscale's `serve.go` and fails if any log line there
  that names a peer address is not covered by the journal filter. A
  tailscale bump that adds or rewords one turns CI red until the list in
  `nixos/lesson-mcp/default.nix` is updated.

Because the address headers are dropped, file_host's rate limiter sees every
public caller as one client, the same trade some-ui's nginx makes. Funnel has
no rate-limit or firewall settings of its own. If a stranger's traffic ever
crowds out your services, turn Funnel off (below). Don't forward addresses to
fix it.

## What Tailscale sees

Content: nothing. `tailscaled` on this box holds the TLS certificate and
decrypts; Funnel's relays forward encrypted bytes. Tailscale does see
metadata:
- each caller's address;
- the hostname;
- when requests happen and how large they are;
- your tailnet's device list and keys, as its coordination server.

Two further points:
- **Tailscale could in principle issue a certificate for the `ts.net` name
  and intercept.** That would be an active attack, visible in public
  Certificate Transparency logs. Tailnet Lock guards the separate risk of
  Tailscale adding a device to your tailnet.
- **The `ts.net` name is public.** It shows up in those same logs, so
  scanners will find it. The gate is what answers them.

## One-time setup

1. **Create a tailnet** at <https://login.tailscale.com>. You sign in with a
   Google, GitHub, Apple or Microsoft account; the Personal plan is free. Pick
   the tailnet's name now (DNS page → "Rename tailnet"). AI services remember
   the address, so renaming later means connecting each of them again.

2. **In the admin console:**
   - DNS: enable **MagicDNS** and **HTTPS Certificates**.
   - Access controls: allow Funnel by adding to the policy file:

     ```json
     "nodeAttrs": [
       { "target": ["autogroup:member"], "attr": ["funnel"] }
     ]
     ```

3. **Turn the module on** in `nixos/configuration.nix`
   (`lessonMcp.enable = true;`), then `sudo nixos-rebuild switch --flake .#nixos`.

4. **Log the box in:** `sudo tailscale up`, then open the URL it prints.
   Then, in the admin console's Machines page, open `nixos` →
   **Disable key expiry**. Otherwise the node key expires after 180 days and
   Funnel goes down with it.

5. **Start Funnel:** `lesson-mcp-funnel` retries every two minutes until
   step 4 is done. To skip the wait, run
   `sudo systemctl restart lesson-mcp-funnel`. Confirm with
   `tailscale funnel status`.

6. **Point file_host at it.** Find the public name with
   `tailscale status --json | jq -r .Self.DNSName`, and drop the trailing
   dot. Put it in paulgsc/server's `.env` (its `example.env` documents each
   variable), then recreate the container (`docker compose up -d file-host`):

   ```sh
   OAUTH_ISSUER="https://nixos.<tailnet>.ts.net"
   OAUTH_RESOURCE="https://nixos.<tailnet>.ts.net/api/v1/mcp"
   OAUTH_AUTHORIZE_URL="https://nixos.local:5173/connect"
   # The prompt get_lesson_prompt hands out: the host path is mounted into the
   # container, and file_host reads it at the container path.
   MCP_LESSON_PROMPT_HOST_FILE="<your some-ui checkout>/packages/ui/topik/src/lib/topik/generation/lesson-prompt.md"
   MCP_LESSON_PROMPT_FILE="/app/lesson-prompt.md"
   ```

## Checking it

```sh
systemctl status tailscaled lesson-mcp-funnel
tailscale funnel status
curl -s https://nixos.<tailnet>.ts.net/.well-known/oauth-authorization-server | jq .issuer
curl -si -X POST https://nixos.<tailnet>.ts.net/api/v1/mcp | grep -i www-authenticate   # 401, names the metadata
curl -so /dev/null -w '%{http_code}\n' https://nixos.<tailnet>.ts.net/api/v1/oauth/grants   # 404
```

## Turning it off

- **Now:** `sudo systemctl stop lesson-mcp-funnel`, which runs
  `tailscale funnel --https=443 off`. Nothing else on the box changes.
- **For good:** set `lessonMcp.enable = false;` and rebuild. That stops the
  unit, which turns Funnel off, and stops `tailscaled` unless something else
  enables it.

## Not here

- **Frame-busting for `/connect`.** The page is served by some-ui's `vite dev`
  on port 5173, not by this Caddy, so its `frame-ancestors` header is set in
  `apps/www/vite.config.ts`.
- **Reaching the box from your other devices over the tailnet.** LM6 keeps
  that closed. Opening a port to them is a firewall rule on `tailscale0`
  added on purpose, not a side effect of joining.
