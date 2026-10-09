_: {
  # Every port this box serves, and who may reach it.  Verified against the
  # box with `ss -tlnp` on 2026-10-09, after paulgsc/server#416 and
  # paulgsc/some-ui#1703 were deployed.
  #
  # Two kinds of port, governed by different things (see nixos/ports for why):
  #
  #   * HOST PROCESSES: nixos-fw sees their traffic, so `srcSubnets` and
  #     `interfaces` below are the policy.
  #   * DOCKER-PUBLISHED: nothing here can scope them.  The host IP in the
  #     compose `ports:` entry is the policy, and each entry below says which
  #     one it is.  `srcSubnets` on one of these only matters if a host
  #     process ever takes that port instead (file_host via `cargo run`).
  #     Box-only and no-host-port ports use `interfaces = ["lo"]`, which
  #     generates no firewall rule and files them under "Loopback-Only" in
  #     /etc/port-audit.txt.
  networking.managedPorts = {
    enable = true;

    # autoRetire surfaces a reminder in the audit report but does NOT filter ports at
    # build time (Nix eval is pure; no wall-clock access). Review the report manually.
    autoRetire = {
      enable = true;
      daysUntilRetirement = 90;
    };

    generateAuditReport = true;
    enableLogging = false;

    ports = [
      # ═══════════════════════════════════════════════════════════
      # Host processes (nixos-fw governs these)
      # ═══════════════════════════════════════════════════════════
      {
        port = 22;
        protocol = "tcp";
        service = "openssh";
        description = "SSH remote access (LAN only)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # home LAN subnet
      }

      {
        port = 80;
        protocol = "tcp";
        service = "caddy";
        description = "HTTP: Caddy reverse proxy for *.nixos.local subdomains (nixos/subdomains, a NixOS service, not Docker)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # LAN access (phone/tablet)
        lastUsed = "2026-10-09";
      }

      {
        port = 443;
        protocol = "tcp";
        service = "caddy";
        description = "HTTPS: Caddy reverse proxy for *.nixos.local subdomains (nixos/subdomains, a NixOS service, not Docker)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        lastUsed = "2026-10-09";
      }

      {
        port = 5173;
        protocol = "tcp";
        service = "vite-www";
        description = "some-ui www Vite dev server (binds 0.0.0.0, strictPort). When the Docker www runs instead it publishes its HTTPS listener here, compose 0.0.0.0 (some-ui#1703), which this rule does not govern.";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        lastUsed = "2026-10-09";
      }

      {
        port = 6006;
        protocol = "tcp";
        service = "storybook";
        description = "Storybook component dev (browser-accessed from LAN via nixos.local)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # headless box; browsed from Windows PC over mDNS
      }

      {
        port = 3141;
        protocol = "tcp";
        service = "typst-preview";
        description = "tinymist live-preview HTTP server (vim binds --data-plane-host nixos.local:3141, matching the browsed URL's host -- tinymist v0.14.18 validates the WebSocket Origin against the bind hostname itself, so a wildcard 0.0.0.0 bind here would make the preview page load but its WebSocket connection fail; this firewall rule still restricts LAN reachability regardless of bind host)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
      }

      # ═══════════════════════════════════════════════════════════
      # Docker, LAN: compose publishes on 0.0.0.0 (IPv4 only)
      # Reached from the Windows PC or the phone.  srcSubnets below
      # does NOT restrict these; the compose host IP is the policy.
      # ═══════════════════════════════════════════════════════════
      {
        port = 3000;
        protocol = "tcp";
        service = "file-host";
        description = "Axum file host (server#416: compose 0.0.0.0; the phone reaches it, and it has its own auth). srcSubnets covers the `cargo run -p file_host` case, a host process.";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 3001;
        protocol = "tcp";
        service = "grafana";
        description = "Grafana dashboards (server#416: compose 0.0.0.0; browsed from Windows at nixos.local:3001)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 3030;
        protocol = "tcp";
        service = "metabase";
        description = "Metabase (server#416: compose 0.0.0.0; browsed from Windows at nixos.local:3030)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 5540;
        protocol = "tcp";
        service = "redisinsight";
        description = "Redis admin UI, no login (server#416: compose 0.0.0.0; browsed from Windows at nixos.local:5540)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 5050;
        protocol = "tcp";
        service = "openai-edge-tts-proxy";
        description = "OpenAI Edge TTS proxy, nginx -> python backend (some-ui#1703: compose 0.0.0.0; plain-HTTP pages reach it)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 5172;
        protocol = "tcp";
        service = "www";
        description = "Docker www HTTP listener (some-ui#1703: compose 0.0.0.0). Its HTTPS listener shares 5173 with vite dev, above.";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      # ═══════════════════════════════════════════════════════════
      # Docker, box only: compose publishes on 127.0.0.1
      # No auth on any of these.  From Windows, tunnel:
      #   ssh -L <port>:localhost:<port> paulg@nixos.local
      # ═══════════════════════════════════════════════════════════
      {
        port = 6379;
        protocol = "tcp";
        service = "redis";
        description = "Redis, no password (server#416: compose 127.0.0.1). Containers use redis:6379; host tools use 127.0.0.1:6379.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 4222;
        protocol = "tcp";
        service = "nats";
        description = "NATS client pub/sub, no auth (server#416: compose 127.0.0.1). obs/scripts/nats_audio_sender.py on Windows can no longer reach it, by choice.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 8222;
        protocol = "tcp";
        service = "nats";
        description = "NATS HTTP monitoring API (server#416: compose 127.0.0.1). nats-exporter reads it over monitoring-network.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 9090;
        protocol = "tcp";
        service = "prometheus";
        description = "Prometheus UI, no login; --web.enable-lifecycle accepts POST /-/quit (server#416: compose 127.0.0.1). Grafana reads it over monitoring-network.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 11434;
        protocol = "tcp";
        service = "ollama";
        description = "Ollama model server, no auth (server#416: compose 127.0.0.1). Containers use http://ollama:11434.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      # ═══════════════════════════════════════════════════════════
      # Docker, no host port at all
      # Reachable only by name on the monitoring-network bridge, where
      # Prometheus scrapes them.  `interfaces = ["lo"]` doesn't claim
      # they're loopback-bound; it's the closest fit in this schema for
      # "no host exposure, so no firewall rule" and keeps them in the
      # audit trail.
      # ═══════════════════════════════════════════════════════════
      {
        port = 7777;
        protocol = "tcp";
        service = "nats-exporter";
        description = "NATS metrics for Prometheus (server#416: no host port)";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 8080;
        protocol = "tcp";
        service = "cadvisor";
        description = "cAdvisor container metrics (server#416: no host port). Runs privileged with /var/run mounted, so it must never get one back.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 9100;
        protocol = "tcp";
        service = "node-exporter";
        description = "Node exporter, CPU/system metrics (server#416: no host port)";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 9115;
        protocol = "tcp";
        service = "blackbox-exporter";
        description = "Prometheus blackbox exporter (server#416: no host port)";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 9121;
        protocol = "tcp";
        service = "redis-exporter";
        description = "Redis metrics for Prometheus (server#416: no host port)";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      {
        port = 9256;
        protocol = "tcp";
        service = "process-exporter";
        description = "Per-process metrics for Prometheus (server#416: no host port)";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-10-09";
      }

      # ═══════════════════════════════════════════════════════════
      # Docker, no host port: log aggregation, NOT YET DEPLOYED
      # These arrive with paulgsc/server#340, which is still an open
      # PR (not on server main as of 2026-10-09).  Listed ahead of time
      # because each must stay off the host network when it lands.
      # ═══════════════════════════════════════════════════════════
      {
        port = 3100;
        protocol = "tcp";
        service = "loki";
        description = "Loki log aggregation HTTP API (grpc 9096 unused — single-instance, in-memory ring). auth_enabled: false, so this must never reach the host network; Grafana/Prometheus consume it as loki:3100 over monitoring-network only. Pending server#340.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-09-20";
      }

      {
        port = 9080;
        protocol = "tcp";
        service = "promtail";
        description = "Promtail metrics/health endpoint, scraped by Prometheus as promtail:9080 over monitoring-network only. Pending server#340.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-09-20";
      }

      {
        port = 2375;
        protocol = "tcp";
        service = "docker-socket-proxy";
        description = "tecnativa/docker-socket-proxy, CONTAINERS-only, fronting the real docker.sock for promtail's container discovery/log-reading. Effectively root-equivalent to whatever can reach it — stays off the host entirely, monitoring-network only. Pending server#340.";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
        lastUsed = "2026-09-20";
      }
    ];

    portRanges = [];
  };
}
