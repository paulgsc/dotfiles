{
  lib,
  config,
  pkgs,
  ...
}:
# The public half of file_host's MCP endpoint (paulgsc/server, docs/identity.md,
# "AI services acting for a subject"): Tailscale Funnel to a loopback-only
# Caddy site that passes the five paths an AI service's servers call and
# answers 404 for everything else. Funnel's relays forward the caller's
# encrypted connection; tailscaled on this box holds the certificate and
# terminates TLS, so no third party reads what crosses. The approval page
# stays on the LAN, where the passkeys are. docs/lesson-mcp-tunnel.md has the
# one-time setup and the values paulgsc/server's .env needs to match.
#
# Invariants:
#   LM1  Only `publicPaths` cross Funnel; every other path is a 404 at Caddy.
#   LM2  Funnel's origin (the Caddy site) listens on loopback only.
#   LM3  No caller's address reaches file_host, a log on this box, or
#        Tailscale's log servers: Caddy drops the address headers (tailscaled
#        sets X-Forwarded-For to the caller) and keeps no access log;
#        tailscaled uploads no logs, and its serve log lines that name a
#        caller are dropped before the journal stores them.
#   LM4  Retired with the Cloudflare Tunnel: there is no tunnel credential to
#        place. tailscaled keeps its node key in its own state.
#   LM5  Funnel is on only while this module is: the unit that turns it on
#        turns it off when it stops, since tailscaled persists the setting.
#   LM6  Joining the tailnet opens no port to tailnet devices. tailscaled's
#        default netfilter mode puts `-i tailscale0 -j ACCEPT` ahead of the
#        NixOS firewall; with it off, that firewall alone governs tailscale0.
#        Funnel's connections (peerAPI, serve) are handled in tailscaled's
#        userspace stack and never reach it.
# checks.x86_64-linux.lesson-mcp-gate holds LM1 and LM3's header half by
# running Caddy on the rendered site, asserts LM2, LM3's log half, LM5 and LM6 on
# the rendered units, and matches LM3's journal filter against every log line
# in the pinned tailscale's serve.go that names a peer address.
with lib; let
  cfg = config.services.lessonMcp;
  tailscale = config.services.tailscale.package;

  # What an AI service's servers call (paulgsc/server, file_host
  # src/routes/{oauth,mcp}.rs). Exact paths, not prefixes: the approval and
  # grant routes under /api/v1/oauth are the app's, and the app is on the LAN.
  publicPaths = [
    "/.well-known/oauth-authorization-server"
    "/.well-known/oauth-protected-resource/api/v1/mcp"
    "/api/v1/oauth/register"
    "/api/v1/oauth/token"
    "/api/v1/mcp"
  ];

  # Headers that name an address or place. tailscaled sets X-Forwarded-For to
  # the caller; the rest are client-forgeable and dropped for the same reason.
  # file_host keys its rate limiter on the first X-Forwarded-For hop, so with
  # these gone every public caller shares one bucket, which is the same trade
  # the some-ui nginx makes for the LAN.
  addressHeaders = [
    "X-Forwarded-For"
    "X-Real-Ip"
    "Forwarded"
    "True-Client-Ip"
    "Cf-Connecting-Ip"
    "Cf-Connecting-Ipv6"
    "Cf-Ipcountry"
  ];

  # tailscaled's log lines that print a Funnel caller's address
  # (ipn/ipnlocal/serve.go; the check keeps this list complete for the pinned
  # tailscale). They are error paths, but a scanner can provoke them. systemd
  # drops a message matching a `~` pattern before the journal stores it.
  # No backslashes or quotes: unit-file parsing would have its own say about
  # them (hence `didn.t`).
  callerLogPatterns = [
    "~getConn didn.t complete from "
    "~no matching ingress serve handler for "
    "~local-serve: no handler for "
    "~[(]from [^)]*[)] to "
    "~ingress: (denied; no ingress cap|bad request) from "
  ];
in {
  options.services.lessonMcp = {
    enable = mkEnableOption "Tailscale Funnel to file_host's MCP endpoint";

    port = mkOption {
      type = types.port;
      default = 8787;
      description = "Loopback port of the Caddy site Funnel delivers to.";
    };

    upstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:3000";
      description = "file_host, as published by its container on the host.";
    };
  };

  config = mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      # tailscaled's own logs go to log.tailscale.io unless this is set.
      disableUpstreamLogging = true;
      # Keep this box's DNS as it is; Funnel needs MagicDNS on the tailnet,
      # not on this node. netfilter off: LM6.
      extraSetFlags = ["--accept-dns=false" "--netfilter-mode=off"];
      # openFirewall stays false: UDP 41641 only speeds up direct paths, and
      # Funnel works without any inbound port.
    };

    systemd.services.tailscaled.serviceConfig.LogFilterPatterns = callerLogPatterns;

    # tailscaled persists Funnel in its state, so this unit both sets it and,
    # on stop (including when a rebuild removes it), clears it (LM5).
    systemd.services.lesson-mcp-funnel = {
      description = "Tailscale Funnel to the lesson MCP gate";
      after = ["tailscaled.service" "tailscaled-set.service" "caddy.service"];
      requires = ["tailscaled.service"];
      wantedBy = ["multi-user.target"];
      path = [tailscale pkgs.jq];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # `tailscale funnel` waits for Funnel to be allowed on the tailnet
        # when it is not, so bound it; Restart retries after the admin step.
        TimeoutStartSec = "2min";
        Restart = "on-failure";
        RestartSec = "2min";
        ExecStop = "-${getExe tailscale} funnel --https=443 off";
      };
      script = ''
        for _ in $(seq 60); do
          [ "$(tailscale status --json --peers=false | jq -r .BackendState)" = Running ] && break
          sleep 1
        done
        tailscale funnel --bg --yes --https=443 http://127.0.0.1:${toString cfg.port}
      '';
    };

    services.subdomains.hosts.lesson-mcp = {
      enable = true;
      # Any Host: tailscaled forwards the caller's (`<machine>.<tailnet>.ts.net`),
      # and only it can reach a loopback listener from outside.
      address = "http://:${toString cfg.port}";
      bind = ["127.0.0.1"];
      proxyPass = cfg.upstream;
      allowPaths = publicPaths;
      stripRequestHeaders = addressHeaders;
      accessLog = false;
    };

    networking.managedPorts.ports = [
      {
        inherit (cfg) port;
        protocol = "tcp";
        service = "caddy";
        description = "Origin of the lesson MCP Funnel: Caddy on loopback, passing only the public OAuth and MCP paths to file_host. tailscaled dials out and terminates TLS here, so nothing is opened inbound.";
        externalAccess = true;
        interfaces = ["lo"];
        lastUsed = "2026-10-07";
      }
    ];
  };
}
