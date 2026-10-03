# Lesson MCP tunnel

`nixos/lesson-mcp` puts file_host's MCP endpoint on the internet so that
claude.ai, ChatGPT or Claude Code can call it for you once you have approved
them. It exposes nothing else. The design is in paulgsc/server's
`docs/identity.md`, "AI services acting for a subject". This page covers the
box's side of it.

```
AI service ──https──▶ Cloudflare edge ──tunnel (cloudflared dials out)──▶
  Caddy on 127.0.0.1:8787 ── 5 exact paths ──▶ file_host on 127.0.0.1:3000
                          └─ anything else ──▶ 404
```

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
uncleaned. That would let a crafted path reach a route behind the gate.

### Invariants

- **LM1:** only those five paths reach file_host through the tunnel.
  Everything else is a 404 from Caddy.
- **LM2:** the tunnel's origin (Caddy, port 8787) listens on loopback only.
- **LM3:** no caller's address reaches file_host or a log on this box.
  Caddy drops `Cf-Connecting-Ip`, `X-Forwarded-For` and the other address
  headers, and the site keeps no access log (NixOS's Caddy module writes one
  per host by default, with request headers).
- **LM4:** the tunnel's credentials never enter the Nix store.

`checks.x86_64-linux.lesson-mcp-gate` (CI, "lesson MCP gate") runs Caddy on
the rendered site and probes 27 paths and the address headers. It covers LM1
and LM3, and asserts LM2 and LM3's log half at eval. LM4 is an assertion in
the module.

Because the address headers are dropped, file_host's rate limiter sees every
public caller as one client. That is the same trade some-ui's nginx makes. If
a stranger's traffic ever crowds out your services, add a Cloudflare rate
limiting rule for the hostname. Don't forward addresses to fix it.

## What Cloudflare sees

Cloudflare terminates TLS at its edge. Everything that crosses is readable
there: bearer tokens, your progress, and the lessons an AI service keeps. That
is the cost of this tunnel. Tailscale Funnel would terminate TLS on this box
instead, if that cost ever stops being acceptable. The AI service sees the
same content anyway, because that is the point of connecting it.

## One-time setup

You need a domain whose DNS is on Cloudflare. Below, `lessons.example.com`
stands for your hostname.

1. **Create the tunnel**, on the box:

   ```sh
   nix shell nixpkgs#cloudflared
   cloudflared tunnel login                 # browser; writes ~/.cloudflared/cert.pem
   cloudflared tunnel create lesson-mcp     # prints the tunnel id
   cloudflared tunnel route dns lesson-mcp lessons.example.com
   ```

2. **Move the credentials out of your home directory** (LM4):

   ```sh
   sudo install -D -m 0600 -o root -g root \
     ~/.cloudflared/<tunnel-id>.json /var/lib/cloudflared/lesson-mcp.json
   rm ~/.cloudflared/<tunnel-id>.json
   ```

   `cert.pem` is your Cloudflare account's certificate. Only `tunnel create`,
   `route` and `delete` use it; the running tunnel does not. Delete it, and
   run `tunnel login` again the next time you need one of those commands.

3. **Turn the module on** in `nixos/configuration.nix`, then
   `sudo nixos-rebuild switch --flake .#nixos`:

   ```nix
   lessonMcp = {
     enable = true;
     hostname = "lessons.example.com";
     tunnelId = "<tunnel-id>";
   };
   ```

4. **Point file_host at it**, in paulgsc/server's `.env` (its `example.env`
   documents each variable), then recreate the container
   (`docker compose up -d file-host`):

   ```sh
   OAUTH_ISSUER="https://lessons.example.com"
   OAUTH_RESOURCE="https://lessons.example.com/api/v1/mcp"
   OAUTH_AUTHORIZE_URL="https://nixos.local:5173/connect"
   # The prompt get_lesson_prompt hands out: the host path is mounted into the
   # container, and file_host reads it at the container path.
   MCP_LESSON_PROMPT_HOST_FILE="<your some-ui checkout>/packages/ui/topik/src/lib/topik/generation/lesson-prompt.md"
   MCP_LESSON_PROMPT_FILE="/app/lesson-prompt.md"
   ```

5. **Let non-browser clients through.** If Bot Fight Mode is on for the zone,
   it challenges server-to-server calls, and every AI service then fails at
   registration. Turn it off, or skip it for this hostname with a WAF rule.

## Checking it

```sh
systemctl status 'cloudflared-tunnel-*'
curl -s https://lessons.example.com/.well-known/oauth-authorization-server | jq .issuer
curl -si -X POST https://lessons.example.com/api/v1/mcp | grep -i www-authenticate   # 401, names the metadata
curl -so /dev/null -w '%{http_code}\n' https://lessons.example.com/api/v1/oauth/grants   # 404
```

## Not here

- **Frame-busting for `/connect`.** The page is served by some-ui's `vite dev`
  on port 5173, not by this Caddy, so its `frame-ancestors` header is set in
  `apps/www/vite.config.ts`.
- **Changing the hostname later.** Every connected service has stored the old
  issuer, so each one has to be connected again.
