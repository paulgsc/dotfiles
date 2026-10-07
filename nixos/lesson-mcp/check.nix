# checks.<system>.lesson-mcp-gate: runs Caddy on the site services.lessonMcp
# renders, in front of an upstream that echoes what reached it, and asks it the
# questions LM1-LM3 (./default.nix) answer; checks LM2, LM3's log half, LM5 and LM6
# on the rendered units; and matches LM3's journal filter against the pinned
# tailscale's serve.go. Run it with
#   nix build --no-link .#checks.x86_64-linux.lesson-mcp-gate
{
  pkgs,
  nixosConfiguration,
}: let
  inherit (pkgs) lib;
  port = 18787;
  upstreamPort = 18780;
  # What tailscaled forwards as Host: the caller's, i.e. the Funnel name.
  hostname = "nixos.tail0000.ts.net";

  enabled =
    (nixosConfiguration.extendModules {
      modules = [
        {
          services.lessonMcp = {
            # The host config leaves it off until the tailnet exists.
            enable = lib.mkForce true;
            inherit port;
            upstream = "http://127.0.0.1:${toString upstreamPort}";
          };
        }
      ];
    })
    .config;

  address = "http://:${toString port}";
  vhost = enabled.services.caddy.virtualHosts.${address};
  funnel = enabled.systemd.services.lesson-mcp-funnel;
  tailscaled = enabled.systemd.services.tailscaled.serviceConfig;
  logPatterns = tailscaled.LogFilterPatterns;

  # LM2, LM3's log half and LM5 are facts about the rendered units, not about
  # a running Caddy, so they are checked at eval.
  evalFailures =
    lib.optional (vhost.listenAddresses != ["127.0.0.1"]) "LM2: the site listens on ${toString vhost.listenAddresses}, not 127.0.0.1 alone"
    ++ lib.optional (vhost.logFormat != null) "LM3: the site keeps an access log"
    ++ lib.optional (!(lib.elem "TS_NO_LOGS_NO_SUPPORT=true" tailscaled.Environment)) "LM3: tailscaled uploads its logs"
    ++ lib.optional enabled.services.tailscale.openFirewall "tailscale opens an inbound port"
    ++ lib.optional (!(lib.elem "--netfilter-mode=off" enabled.services.tailscale.extraSetFlags)) "LM6: tailscaled's netfilter rules accept everything on tailscale0"
    ++ lib.optional (lib.elem "tailscale0" enabled.networking.firewall.trustedInterfaces) "LM6: the firewall trusts tailscale0"
    ++ lib.optional (!(lib.hasInfix "funnel --bg --yes --https=443 http://127.0.0.1:${toString port}\n" funnel.script)) "Funnel targets somewhere other than the site"
    ++ lib.optional (!(lib.hasSuffix "funnel --https=443 off" (funnel.serviceConfig.ExecStop or ""))) "LM5: stopping the Funnel unit leaves Funnel on"
    ++ lib.optional (!(funnel.serviceConfig.RemainAfterExit or false)) "LM5: the Funnel unit exits, so nothing runs its ExecStop";

  # LM3's journal half: every log line in the pinned tailscale's serve.go that
  # prints a peer address must match one of tailscaled's LogFilterPatterns.
  # A tailscale bump that adds or rewords one fails here until the list in
  # ./default.nix covers it.
  logScan = pkgs.writeText "log-scan.py" ''
    import json, re, sys
    src = open(sys.argv[1]).read()
    patterns = [p.removeprefix("~") for p in json.load(open(sys.argv[2]))]
    calls = re.findall(r'logf\(\s*"((?:[^"\\]|\\.)*)"\s*,([^\n]*)', src)
    named = [(fmt, args) for fmt, args in calls if re.search(r"srcAddr|SrcAddr|remoteAddr|RemoteAddr", args)]
    if len(named) < 5:
        sys.exit(f"FAIL LM3 scan: found {len(named)} address-naming log lines; the pattern no longer reads serve.go")
    fail = 0
    for fmt, _ in named:
        msg = re.sub(r"%[vsdq]", "203.0.113.7:443", fmt)
        hit = [p for p in patterns if re.search(p, msg)]
        print(("ok  " if hit else "FAIL") + f" LM3 journal: {fmt!r}")
        fail |= not hit
    sys.exit(fail)
  '';

  caddyfile = pkgs.writeText "Caddyfile" ''
    {
      admin off
      auto_https off
      persist_config off
    }
    ${address} {
      bind ${lib.concatStringsSep " " vhost.listenAddresses}
      ${vhost.extraConfig}
    }
  '';

  # Answers 200 with the path it was asked for and every header it got.
  echo = pkgs.writeText "echo.py" ''
    import http.server, json, sys
    class H(http.server.BaseHTTPRequestHandler):
        def answer(self):
            body = json.dumps({"path": self.path, "headers": dict(self.headers)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        do_GET = do_POST = do_DELETE = answer
        def log_message(self, *args):
            pass
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
  '';
in
  assert lib.assertMsg (evalFailures == []) (lib.concatStringsSep "; " evalFailures);
    pkgs.runCommand "lesson-mcp-gate" {nativeBuildInputs = [pkgs.caddy pkgs.curl pkgs.python3 pkgs.jq];} ''
      export HOME=$TMPDIR XDG_DATA_HOME=$TMPDIR XDG_CONFIG_HOME=$TMPDIR
      python3 ${logScan} ${enabled.services.tailscale.package.src}/ipn/ipnlocal/serve.go ${pkgs.writeText "log-patterns.json" (builtins.toJSON logPatterns)}
      caddy validate --adapter caddyfile --config ${caddyfile}
      python3 ${echo} ${toString upstreamPort} &
      caddy run --adapter caddyfile --config ${caddyfile} &
      # Both must answer before the first probe: Caddy alone answers the 404s,
      # and an upstream still starting turns the allowed paths into 502s.
      for _ in $(seq 50); do
        curl -s -o /dev/null http://127.0.0.1:${toString upstreamPort}/ \
          && curl -s -o /dev/null http://127.0.0.1:${toString port}/ && break
        sleep 0.2
      done

      fail=0
      ask() { # method path -> "<status> <path upstream saw, or - if it saw nothing>"
        curl -s --path-as-is -X "$1" -H 'Host: ${hostname}' -o body -w '%{http_code}' \
          "http://127.0.0.1:${toString port}$2" > status
        seen=$(jq -r .path body 2>/dev/null || echo -)
        echo "$(cat status) ''${seen:--}"
      }
      expect() { # method path want
        got=$(ask "$1" "$2")
        if [ "$got" != "$3" ]; then echo "FAIL $1 $2: want '$3', got '$got'"; fail=1; else echo "ok   $1 $2 -> $got"; fi
      }

      # LM1: the public paths reach file_host unchanged.
      expect GET  /.well-known/oauth-authorization-server "200 /.well-known/oauth-authorization-server"
      expect GET  /.well-known/oauth-protected-resource/api/v1/mcp "200 /.well-known/oauth-protected-resource/api/v1/mcp"
      expect POST /api/v1/oauth/register "200 /api/v1/oauth/register"
      expect POST /api/v1/oauth/token "200 /api/v1/oauth/token"
      expect POST /api/v1/mcp "200 /api/v1/mcp"
      expect POST '/api/v1/mcp?x=1' "200 /api/v1/mcp?x=1"

      # LM1: everything else stops at Caddy.
      expect GET  / "404 -"
      expect POST /api/v1/oauth/authorize/requests "404 -"
      expect GET  /api/v1/oauth/grants "404 -"
      expect GET  /api/v1/shelf "404 -"
      expect GET  /api/v1/subjects/stats "404 -"
      expect GET  /health "404 -"
      expect GET  /metrics "404 -"
      expect POST /api/v1/mcpx "404 -"
      expect POST /api/v1/mcp/ "404 -"
      expect POST /api/v1/mcp/extra "404 -"
      expect GET  /.well-known/oauth-authorization-server/extra "404 -"
      expect GET  /.well-known/openid-configuration "404 -"
      expect GET  /api/v1/mcp/../shelf "404 -"
      expect GET  /api/v1/mcp/..%2fshelf "404 -"
      expect GET  /api/v1/oauth/token/../grants "404 -"
      expect GET  //api/v1/shelf "404 -"
      expect GET  /api/v1/shelf/../mcp "404 -"
      expect POST /x/../api/v1/mcp "404 -"
      expect POST /api/v1/shelf/..%2fmcp "404 -"
      expect POST /api/v1/./mcp "404 -"
      expect POST /API/V1/MCP "404 -"

      # LM3: no address a caller or Cloudflare names reaches file_host.
      curl -s -X POST -o body http://127.0.0.1:${toString port}/api/v1/mcp \
        -H 'Host: ${hostname}' \
        -H 'Cf-Connecting-Ip: 203.0.113.7' -H 'Cf-Connecting-Ipv6: 2001:db8::7' \
        -H 'Cf-Ipcountry: ZZ' -H 'True-Client-Ip: 203.0.113.7' \
        -H 'X-Forwarded-For: 203.0.113.7' -H 'X-Real-Ip: 203.0.113.7' \
        -H 'Forwarded: for=203.0.113.7'
      # tailscaled sets X-Forwarded-For to the caller. Caddy, trusting no proxy,
      # would replace it with 127.0.0.1; the strip removes it outright, and
      # this holds both, so trusting tailscaled later cannot pass it through.
      if grep -qiE '203\.0\.113\.7|2001:db8::7|"ZZ"' body || jq -e '.headers | keys | map(ascii_downcase) | index("x-forwarded-for")' body >/dev/null; then
        echo "FAIL LM3: an address header reached file_host:"; jq .headers body; fail=1
      else
        echo "ok   LM3: upstream saw $(jq -c '.headers | keys' body)"
      fi

      [ "$fail" -eq 0 ] && touch $out
    ''
