{
  config,
  pkgs,
  ...
}: {
  # Enable the managed ports system
  networking.managedPorts = {
    enable = true;

    # Configure auto-retirement
    autoRetire = {
      enable = true;
      daysUntilRetirement = 90; # Review ports unused for 90 days
    };

    # Generate audit reports
    generateAuditReport = true;

    # Enable connection logging (useful for debugging, but verbose)
    enableLogging = false;

    # Define individual ports
    ports = [
      # ═══════════════════════════════════════════════════════════
      # SSH - LAN access for management
      # ═══════════════════════════════════════════════════════════
      {
        port = 22;
        protocol = "tcp";
        service = "openssh";
        description = "SSH remote access (LAN only)";
        externalAccess = false; # LAN ≠ Internet
        interfaces = ["10.0.0.0/24"]; # Your home LAN subnet
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
        interfaces = ["10.0.0.0/24"]; # LAN access if browsing from phone/tablet
        owner = "docker";
      }

      {
        port = 443;
        protocol = "tcp";
        service = "caddy";
        description = "HTTPS web server (Caddy reverse proxy)";
        externalAccess = false;
        interfaces = ["10.0.0.0/24"]; # LAN access
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
        interfaces = ["10.0.0.0/24"]; # LAN - Docker exposed 0.0.0.0:3000
        owner = "docker";
      }

      {
        port = 5050;
        protocol = "tcp";
        service = "openai-edge-tts-proxy";
        description = "OpenAI Edge TTS proxy (nginx → python backend)";
        externalAccess = false;
        interfaces = ["10.0.0.0/24"]; # LAN access - Docker exposed 0.0.0.0:5050
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Development Servers (localhost only)
      # ═══════════════════════════════════════════════════════════
      {
        port = 5173;
        protocol = "tcp";
        service = "vite-www";
        description = "WWW project Vite dev server";
        externalAccess = false;
        interfaces = ["10.0.0.0/24"]; # LAN - Docker exposed 0.0.0.0:5173
      }

      {
        port = 6006;
        protocol = "tcp";
        service = "storybook";
        description = "Storybook component dev - accessed from browsers";
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
        description = "Redis - Docker internal + LAN monitoring tools";
        externalAccess = false;
        interfaces = ["10.0.0.0/24"]; # Docker exposed 0.0.0.0:6379
        owner = "docker";
      }

      {
        port = 5540;
        protocol = "tcp";
        service = "redisinsight";
        description = "Redis admin UI - accessed from browser";
        externalAccess = false;
        interfaces = ["lo"]; # Localhost only unless you need LAN access
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
        interfaces = ["10.0.0.0/24"]; # Docker exposed 0.0.0.0:4222
        owner = "docker";
      }

      {
        port = 8222;
        protocol = "tcp";
        service = "nats";
        description = "NATS HTTP monitoring API";
        externalAccess = false;
        interfaces = ["10.0.0.0/24"]; # Docker exposed 0.0.0.0:8222
        owner = "docker";
      }

      # ═══════════════════════════════════════════════════════════
      # Observability Stack (localhost only)
      # ═══════════════════════════════════════════════════════════
      {
        port = 3001;
        protocol = "tcp";
        service = "grafana";
        description = "Grafana dashboards - accessed from browsers";
        externalAccess = false;
        interfaces = ["lo"]; # Localhost only - access via reverse proxy if needed
        owner = "docker";
      }

      {
        port = 9090;
        protocol = "tcp";
        service = "prometheus";
        description = "Prometheus - accessed from Grafana + browsers";
        externalAccess = false;
        interfaces = ["lo"]; # Localhost only
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

    # Define port ranges (useful for development environments)
    portRanges = [
      # Example: Development server pool
      # {
      #   from = 4000;
      #   to = 4010;
      #   protocol = "tcp";
      #   service = "dev-server-pool";
      #   description = "Reserved for ephemeral development servers";
      #   lastUsed = "2025-10-12";
      #   owner = "dev-team";
      # }

      # Example: Microservices range
      # {
      #   from = 8000;
      #   to = 8099;
      #   protocol = "tcp";
      #   service = "microservices";
      #   description = "Port range for microservice instances";
      #   lastUsed = "2025-10-12";
      #   owner = "backend-team";
      # }
    ];
  };
}
