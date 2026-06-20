{
  config,
  pkgs,
  ...
}: {
  # Enable the managed ports system
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
      # SSH - LAN access for management
      # ═══════════════════════════════════════════════════════════
      {
        port = 22;
        protocol = "tcp";
        service = "openssh";
        description = "SSH remote access (LAN only)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # home LAN subnet
      }

      # ═══════════════════════════════════════════════════════════
      # Web Services
      # ═══════════════════════════════════════════════════════════
      {
        port = 80;
        protocol = "tcp";
        service = "nginx";
        description = "HTTP web server (Caddy reverse proxy)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # LAN access (phone/tablet)
        owner = "docker";
      }

      {
        port = 443;
        protocol = "tcp";
        service = "caddy";
        description = "HTTPS web server (Caddy reverse proxy)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"];
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Application Services
      # ═══════════════════════════════════════════════════════════
      {
        port = 3000;
        protocol = "tcp";
        service = "file-host";
        description = "Axum file host server";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # Docker binds 0.0.0.0:3000
        owner = "docker";
      }

      {
        port = 5050;
        protocol = "tcp";
        service = "openai-edge-tts-proxy";
        description = "OpenAI Edge TTS proxy (nginx -> python backend)";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # Docker binds 0.0.0.0:5050
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Development Servers
      # ═══════════════════════════════════════════════════════════
      {
        port = 5173;
        protocol = "tcp";
        service = "vite-www";
        description = "WWW project Vite dev server";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # Docker binds 0.0.0.0:5173
      }

      {
        port = 6006;
        protocol = "tcp";
        service = "storybook";
        description = "Storybook component dev - localhost only";
        externalAccess = false;
        interfaces = ["lo"];
      }

      # ═══════════════════════════════════════════════════════════
      # Databases & Caches (CRITICAL - Minimize exposure)
      # ═══════════════════════════════════════════════════════════
      {
        port = 6379;
        protocol = "tcp";
        service = "redis";
        description = "Redis - LAN monitoring tools only";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # Docker binds 0.0.0.0:6379; no auth → LAN-only
        owner = "docker";
      }

      {
        port = 5540;
        protocol = "tcp";
        service = "redisinsight";
        description = "Redis admin UI - localhost only";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Message Queue
      # ═══════════════════════════════════════════════════════════
      {
        port = 4222;
        protocol = "tcp";
        service = "nats";
        description = "NATS client pub/sub";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # Docker binds 0.0.0.0:4222
        owner = "docker";
      }

      {
        port = 8222;
        protocol = "tcp";
        service = "nats";
        description = "NATS HTTP monitoring API";
        externalAccess = false;
        srcSubnets = ["10.0.0.0/24"]; # Docker binds 0.0.0.0:8222
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Observability Stack (localhost only)
      # ═══════════════════════════════════════════════════════════
      {
        port = 3001;
        protocol = "tcp";
        service = "grafana";
        description = "Grafana dashboards - localhost only";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      {
        port = 9090;
        protocol = "tcp";
        service = "prometheus";
        description = "Prometheus - localhost only";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Metrics Exporters (localhost only)
      # ═══════════════════════════════════════════════════════════
      {
        port = 7777;
        protocol = "tcp";
        service = "nats-exporter";
        description = "Exports NATS metrics in Prometheus format";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      {
        port = 8080;
        protocol = "tcp";
        service = "cadvisor";
        description = "cAdvisor container metrics";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      {
        port = 9100;
        protocol = "tcp";
        service = "node-exporter";
        description = "Node exporter - CPU/system monitoring";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      {
        port = 9115;
        protocol = "tcp";
        service = "blackbox-exporter";
        description = "Prometheus blackbox exporter";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      {
        port = 9121;
        protocol = "tcp";
        service = "redis-exporter";
        description = "Exports Redis metrics in Prometheus format";
        externalAccess = false;
        interfaces = ["lo"];
        owner = "docker";
      }

      {
        port = 9256;
        protocol = "tcp";
        service = "node-exporter";
        description = "Process exporter for Prometheus";
        lastUsed = "2025-10-12";
        owner = "docker";
        externalAccess = false;
        interfaces = ["lo"];
      }

      # ═══════════════════════════════════════════════════════════
      # Typst live preview (localhost only)
      # ═══════════════════════════════════════════════════════════
      {
        port = 3141;
        protocol = "tcp";
        service = "typst-preview";
        description = "tinymist live-preview HTTP server";
        externalAccess = false;
        interfaces = ["lo"];
      }

      # ═══════════════════════════════════════════════════════════
      # Retired / Unused Services
      # ═══════════════════════════════════════════════════════════
      {
        port = 3030;
        protocol = "tcp";
        service = "metabase";
        description = "Metabase Dashboard (RETIRED - not in docker ps)";
        lastUsed = "2025-10-12";
        owner = "realtime-team";
        externalAccess = false;
        interfaces = ["lo"];
      }
    ];

    portRanges = [];
  };
}
