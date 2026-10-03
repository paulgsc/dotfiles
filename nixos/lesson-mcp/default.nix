{
  lib,
  config,
  ...
}:
# The public half of file_host's MCP endpoint (paulgsc/server, docs/identity.md,
# "AI services acting for a subject"): a Cloudflare Tunnel to a loopback-only
# Caddy site that passes the six paths an AI service's servers call and answers
# 404 for everything else. The approval page stays on the LAN, where the
# passkeys are. docs/lesson-mcp-tunnel.md has the one-time setup and the values
# paulgsc/server's .env needs to match.
#
# Invariants:
#   LM1  Only `publicPaths` cross the tunnel; every other path is a 404 at Caddy.
#   LM2  The tunnel's origin listens on loopback only, never on the LAN.
#   LM3  No caller's address reaches file_host or a log on this box: the
#        address headers are dropped before proxying, and the site keeps no
#        access log.
#   LM4  The tunnel's credentials never enter the Nix store.
# checks.x86_64-linux.lesson-mcp-gate runs Caddy on this module's rendered site
# and holds LM1 and LM3's header half; the assertions below hold LM2 and LM4.
with lib; let
  cfg = config.services.lessonMcp;

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

  # Every header Cloudflare (or a client) can use to name an address or place.
  # file_host keys its rate limiter on the first X-Forwarded-For hop, so with
  # these gone every public caller shares one bucket, which is the same
  # trade the some-ui nginx makes for the LAN.
  addressHeaders = [
    "Cf-Connecting-Ip"
    "Cf-Connecting-Ipv6"
    "Cf-Ipcountry"
    "True-Client-Ip"
    "X-Forwarded-For"
    "X-Real-Ip"
    "Forwarded"
  ];
in {
  options.services.lessonMcp = {
    enable = mkEnableOption "the public tunnel to file_host's MCP endpoint";

    hostname = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "lessons.example.com";
      description = ''
        The public hostname the tunnel serves. It is the origin of
        OAUTH_ISSUER and OAUTH_RESOURCE in paulgsc/server's .env, and AI
        services remember it, so changing it means reconnecting each one.
      '';
    };

    tunnelId = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "00000000-0000-0000-0000-000000000000";
      description = "The id `cloudflared tunnel create` printed.";
    };

    credentialsFile = mkOption {
      # A string, not a path: a path literal would be copied into the store.
      type = types.str;
      default = "/var/lib/cloudflared/lesson-mcp.json";
      description = ''
        The tunnel's credentials JSON, root-owned and 0600. systemd hands it
        to cloudflared with LoadCredential.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8787;
      description = "Loopback port of the Caddy site the tunnel delivers to.";
    };

    upstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:3000";
      description = "file_host, as published by its container on the host.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.hostname != null && cfg.tunnelId != null;
          message = "services.lessonMcp: set hostname and tunnelId (docs/lesson-mcp-tunnel.md).";
        }
        {
          assertion = !(hasPrefix builtins.storeDir cfg.credentialsFile);
          message = "services.lessonMcp.credentialsFile is in the Nix store, which every user can read. Keep it under /var/lib.";
        }
      ];
    }

    # Only once both values are set; the assertion above says which is missing.
    (mkIf (cfg.hostname != null && cfg.tunnelId != null) {
      services.cloudflared = {
        enable = true;
        tunnels.${cfg.tunnelId} = {
          inherit (cfg) credentialsFile;
          ingress.${cfg.hostname} = "http://127.0.0.1:${toString cfg.port}";
          default = "http_status:404";
        };
      };

      services.subdomains.hosts.lesson-mcp = {
        enable = true;
        address = "http://${cfg.hostname}:${toString cfg.port}";
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
          description = "Origin of the lesson MCP tunnel: Caddy on loopback, passing only the public OAuth and MCP paths to file_host. cloudflared dials out, so nothing is opened inbound; the public side is Cloudflare's.";
          externalAccess = true;
          interfaces = ["lo"];
          lastUsed = "2026-10-03";
        }
      ];
    })
  ]);
}
