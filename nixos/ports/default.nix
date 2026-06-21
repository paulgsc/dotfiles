{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.networking.managedPorts;

  portModule = types.submodule {
    options = {
      port = mkOption {
        type = types.port;
        description = "Port number to open";
      };

      protocol = mkOption {
        type = types.enum ["tcp" "udp" "both"];
        default = "tcp";
        description = "Protocol type";
      };

      service = mkOption {
        type = types.str;
        description = "Name of the service using this port";
        example = "nginx";
      };

      description = mkOption {
        type = types.str;
        default = "";
        description = "Human-readable description of what uses this port";
        example = "Web server for production site";
      };

      lastUsed = mkOption {
        type = types.str;
        default = "2025-10-12";
        description = "ISO date when port was last verified as needed (YYYY-MM-DD)";
      };

      owner = mkOption {
        type = types.str;
        default = "system";
        description = "Team or person responsible for this port";
        example = "devops-team";
      };

      externalAccess = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this port needs to be accessible from outside the local network";
      };

      interfaces = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Real network interface names to restrict ingress to (e.g. "eth0", "lo").
          Do NOT pass CIDR subnets here — use srcSubnets for subnet-based restrictions.
          Ports with interfaces = ["lo"] and no srcSubnets are omitted from the firewall
          entirely: nixos-fw does not filter loopback traffic.
        '';
        example = ["eth0" "wlan0"];
      };

      srcSubnets = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Source IP subnets (CIDR notation) that may reach this port (LAN scoping).
          Generates: iptables -A nixos-fw -s <subnet> -p <proto> --dport <port> -j nixos-fw-accept
          The port is NOT added to allowedTCPPorts/allowedUDPPorts (not globally open).
        '';
        example = ["10.0.0.0/24" "192.168.1.0/24"];
      };
    };
  };

  portRangeModule = types.submodule {
    options = {
      from = mkOption {
        type = types.port;
        description = "Start of port range (inclusive)";
      };

      to = mkOption {
        type = types.port;
        description = "End of port range (inclusive)";
      };

      protocol = mkOption {
        type = types.enum ["tcp" "udp" "both"];
        default = "tcp";
        description = "Protocol type";
      };

      service = mkOption {
        type = types.str;
        description = "Name of the service using this port range";
      };

      description = mkOption {
        type = types.str;
        default = "";
        description = "Why this range is needed";
      };

      lastUsed = mkOption {
        type = types.str;
        default = "2025-10-12";
        description = "ISO date when range was last verified as needed";
      };

      owner = mkOption {
        type = types.str;
        default = "system";
        description = "Team or person responsible";
      };
    };
  };

  # Predicate helpers
  isGlobalPort = p: p.interfaces == [] && p.srcSubnets == [];
  isLoopbackOnly = p: p.interfaces == ["lo"] && p.srcSubnets == [];

  # Only ports with no interface/subnet restriction go into allowedTCPPorts
  globalPorts = filter isGlobalPort cfg.ports;

  # Ports scoped by source subnet
  subnetScopedPorts = filter (p: p.srcSubnets != []) cfg.ports;

  # Ports scoped by real interface name (not lo-only, not subnet-scoped)
  ifaceScopedPorts = filter (p:
    p.srcSubnets == [] && p.interfaces != [] && !(isLoopbackOnly p))
  cfg.ports;

  # Only globally-open ports enter allowedTCPPorts/allowedUDPPorts
  tcpPorts = flatten (
    (map (p: optional (p.protocol == "tcp" || p.protocol == "both") p.port) globalPorts)
    ++ (map (r:
      if r.protocol == "tcp" || r.protocol == "both"
      then range r.from r.to
      else [])
    cfg.portRanges)
  );

  udpPorts = flatten (
    (map (p: optional (p.protocol == "udp" || p.protocol == "both") p.port) globalPorts)
    ++ (map (r:
      if r.protocol == "udp" || r.protocol == "both"
      then range r.from r.to
      else [])
    cfg.portRanges)
  );

  portProtos = p:
    if p.protocol == "both" then ["tcp" "udp"] else [p.protocol];

  # LAN-scoped rules: -s <subnet> restricts by origin IP (not interface name)
  subnetRuleLines =
    concatMapStrings (p:
      concatMapStrings (subnet:
        concatMapStrings (proto:
          "iptables -A nixos-fw -s ${subnet} -p ${proto} --dport ${toString p.port} -j nixos-fw-accept\n"
        ) (portProtos p)
      ) p.srcSubnets
    ) subnetScopedPorts;

  # Interface-restricted rules using real interface names
  ifaceRuleLines =
    concatMapStrings (p:
      concatMapStrings (iface:
        concatMapStrings (proto:
          "iptables -A nixos-fw -i ${iface} -p ${proto} --dport ${toString p.port} -j nixos-fw-accept\n"
        ) (portProtos p)
      ) p.interfaces
    ) ifaceScopedPorts;

  auditReport = pkgs.writeTextFile {
    name = "port-audit-report";
    text = ''
      # Port Audit Report
      # Total Ports: ${toString (length cfg.ports)} | Ranges: ${toString (length cfg.portRanges)}

      ## Globally Open Ports (allowedTCPPorts — all interfaces)
      ${concatMapStringsSep "\n" (p: ''
          - ${toString p.port}/${p.protocol}  ${p.service}: ${p.description}
            Owner: ${p.owner} | Last Used: ${p.lastUsed} | External: ${
          if p.externalAccess
          then "YES"
          else "No"
        }
        '')
        globalPorts}

      ## LAN-Scoped Ports (iptables -s <subnet> — NOT in allowedTCPPorts)
      ${concatMapStringsSep "\n" (p: ''
          - ${toString p.port}/${p.protocol}  ${p.service}: ${p.description}
            Allowed from: ${concatStringsSep ", " p.srcSubnets} | Owner: ${p.owner} | Last Used: ${p.lastUsed}
        '')
        subnetScopedPorts}

      ## Loopback-Only Ports (no firewall rule — bind service to 127.0.0.1)
      ${concatMapStringsSep "\n" (p: ''
          - ${toString p.port}/${p.protocol}  ${p.service}: ${p.description}
        '')
        (filter isLoopbackOnly cfg.ports)}

      ## Port Ranges (globally open)
      ${concatMapStringsSep "\n" (r: ''
          - ${toString r.from}-${toString r.to}/${r.protocol}  ${r.service}: ${r.description}
            Owner: ${r.owner} | Last Used: ${r.lastUsed}
        '')
        cfg.portRanges}

      ## Security Summary
      ${
        if any (p: p.externalAccess) cfg.ports
        then "WARNING: some ports marked externalAccess = true"
        else "OK: no ports marked for external access"
      }
      NOTE: autoRetire is not enforced at build time (Nix eval is pure; no wall-clock access).
      Manually review ports with lastUsed older than ${toString cfg.autoRetire.daysUntilRetirement} days.
      After rebuild, verify scoping: sudo nft list ruleset | grep -A2 'nixos-fw'
    '';
  };
in {
  options.networking.managedPorts = {
    enable = mkEnableOption "managed port configuration system";

    ports = mkOption {
      type = types.listOf portModule;
      default = [];
      description = "List of individual ports to manage";
      example = literalExpression ''
        [
          {
            port = 22;
            protocol = "tcp";
            service = "openssh";
            description = "SSH — LAN only";
            srcSubnets = ["10.0.0.0/24"];
          }
        ]
      '';
    };

    portRanges = mkOption {
      type = types.listOf portRangeModule;
      default = [];
      description = "List of port ranges to manage (globally open)";
    };

    autoRetire = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When true, surfaces a reminder in the audit report and a build warning.
          Does NOT filter ports — Nix eval is pure and cannot compare lastUsed
          against the real current date at build time.
        '';
      };

      daysUntilRetirement = mkOption {
        type = types.int;
        default = 90;
        description = "Stale threshold used in audit report reminders.";
      };
    };

    generateAuditReport = mkOption {
      type = types.bool;
      default = true;
      description = "Generate a port audit report at /etc/port-audit.txt";
    };

    enableLogging = mkOption {
      type = types.bool;
      default = false;
      description = "Enable logging of dropped packets (can be verbose)";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # Catch accidental CIDRs in interfaces (slash is the tell)
        assertion = all (p: all (iface: !(hasInfix "/" iface)) p.interfaces) cfg.ports;
        message = ''
          networking.managedPorts: one or more ports has a CIDR in `interfaces`.
          `interfaces` must be real interface names (e.g. "eth0", "lo").
          Use `srcSubnets` for subnet restrictions (e.g. "10.0.0.0/24").
        '';
      }
    ];

    networking.firewall = {
      enable = true;
      allowedTCPPorts = tcpPorts;
      allowedUDPPorts = udpPorts;
      logRefusedConnections = cfg.enableLogging;
      extraCommands = ''
        ${subnetRuleLines}
        ${ifaceRuleLines}
      '';
    };

    environment.etc."port-audit.txt" = mkIf cfg.generateAuditReport {
      source = auditReport;
    };

    system.activationScripts.portAudit = mkIf cfg.generateAuditReport (
      stringAfter ["etc"] ''
        echo "Port audit report generated at /etc/port-audit.txt"
        ${
          if cfg.autoRetire.enable
          then ''echo "Review ports with lastUsed older than ${toString cfg.autoRetire.daysUntilRetirement} days (manual review required)."''
          else ""
        }
      ''
    );

    warnings =
      (optional (any (p: p.externalAccess) cfg.ports)
        "networking.managedPorts: some ports are marked externalAccess = true. Ensure they are properly secured.")
      ++ (optional cfg.autoRetire.enable
        "networking.managedPorts: autoRetire.enable is set but retirement is NOT enforced at build time. Use /etc/port-audit.txt for manual review.");
  };
}
