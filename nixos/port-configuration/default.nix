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
      # Web services
      {
        port = 80;
        protocol = "tcp";
        service = "nginx";
        description = "HTTP web server";
        externalAccess = false;
      }
      # SSH
      {
        port = 22;
        protocol = "tcp";
        service = "openssh";
        description = "SSH remote access";
        externalAccess = true;
      }

      # Development servers
      {
        port = 3000;
        protocol = "tcp";
        service = "file-host";
        description = "Axum server";
        externalAccess = false;
      }

      # Monitoring
      {
        port = 3001;
        service = "grafana";
        description = "Grafana dashboards - accessed from browsers";
        externalAccess = false;
      }
      {
        port = 6379;
        service = "redis";
        description = "Redis - only for Docker internal network";
        externalAccess = false;
        interfaces = [];
      }
      {
        port = 5540;
        service = "redisinsight";
        description = "Redis admin UI - accessed from browser";
        externalAccess = false;
        interfaces = [];
      }
      {
        port = 9090;
        service = "prometheus";
        description = "Prometheus - accessed from Grafana + browsers";
        externalAccess = false;
      }
      {
        port = 9115;
        service = "blackbox-exporter";
        description = "Prometheus blackbox exporter";
        externalAccess = false;
        interfaces = [];
      }
      {
        port = 9256;
        protocol = "tcp";
        service = "node-exporter";
        description = "Node exporter for Prometheus";
        lastUsed = "2025-10-12";
        owner = "devops-team";
        externalAccess = false;
      }

      # Application specific
      {
        port = 5050;
        service = "vite-www";
        description = "WWW project dev server - accessed from browsers";
        externalAccess = false;
        interfaces = ["lo"]; # localhost only
      }
      {
        port = 6006;
        service = "storybook";
        description = "Storybook component dev - accessed from browsers";
        externalAccess = false;
      }
      {
        port = 3030;
        protocol = "tcp";
        service = "metabase";
        description = "Metabase Dashboard";
        lastUsed = "2025-10-12";
        owner = "realtime-team";
        externalAccess = false;
      }
      {
        port = 9100;
        service = "node-exporter";
        description = "CPU Monitoring";
        externalAccess = false;
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
