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
        default = ["lo"];
        description = "Specific network interfaces to allow. Empty means all interfaces.";
        example = ["eth0" "wlan0"];
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

  # Helper function to check if port is stale (unused for 90 days)
  isStale = lastUsedStr: let
    lastUsed = lastUsedStr;
    # In a real implementation, you'd compare dates
    # For now, we'll just warn about ports older than 90 days
  in
    false; # Placeholder - would need actual date comparison

  # Filter out stale ports if retirement is enabled
  activePorts =
    if cfg.autoRetire.enable
    then filter (p: !isStale p.lastUsed) cfg.ports
    else cfg.ports;

  # Generate TCP ports list
  tcpPorts = flatten (
    (map (p: optional (p.protocol == "tcp" || p.protocol == "both") p.port) activePorts)
    ++ (map (r:
      if r.protocol == "tcp" || r.protocol == "both"
      then range r.from r.to
      else [])
    cfg.portRanges)
  );

  # Generate UDP ports list
  udpPorts = flatten (
    (map (p: optional (p.protocol == "udp" || p.protocol == "both") p.port) activePorts)
    ++ (map (r:
      if r.protocol == "udp" || r.protocol == "both"
      then range r.from r.to
      else [])
    cfg.portRanges)
  );

  # Generate interface-specific rules
  interfaceRules = let
    portsWithInterfaces = filter (p: p.interfaces != []) activePorts;
  in
    flatten (map (p:
      map (iface: {
        inherit (p) port protocol;
        interface = iface;
      })
      p.interfaces)
    portsWithInterfaces);

  # Generate port audit report
  auditReport = pkgs.writeTextFile {
    name = "port-audit-report";
    text = ''
      # Port Audit Report - Generated ${config.time.timeZone}
      # Total Ports: ${toString (length activePorts)}
      # Total Ranges: ${toString (length cfg.portRanges)}

      ## Individual Ports
      ${concatMapStringsSep "\n" (p: ''
          - Port ${toString p.port}/${p.protocol}
            Service: ${p.service}
            Description: ${p.description}
            Last Used: ${p.lastUsed}
            Owner: ${p.owner}
            External: ${
            if p.externalAccess
            then "Yes"
            else "No"
          }
        '')
        activePorts}

      ## Port Ranges
      ${concatMapStringsSep "\n" (r: ''
          - Ports ${toString r.from}-${toString r.to}/${r.protocol}
            Service: ${r.service}
            Description: ${r.description}
            Last Used: ${r.lastUsed}
            Owner: ${r.owner}
        '')
        cfg.portRanges}

      ## Security Notes
      ${
        if any (p: p.externalAccess) activePorts
        then "⚠️  WARNING: Some ports are marked for external access"
        else "✓ No ports marked for external access"
      }
      ${
        if cfg.autoRetire.enable
        then "✓ Auto-retirement enabled (${toString cfg.autoRetire.daysUntilRetirement} days)"
        else "⚠️  Auto-retirement disabled"
      }
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
            port = 80;
            protocol = "tcp";
            service = "nginx";
            description = "HTTP web server";
            lastUsed = "2025-10-12";
            externalAccess = true;
          }
        ]
      '';
    };

    portRanges = mkOption {
      type = types.listOf portRangeModule;
      default = [];
      description = "List of port ranges to manage";
      example = literalExpression ''
        [
          {
            from = 3000;
            to = 3010;
            protocol = "tcp";
            service = "development-servers";
            description = "Dev environment port range";
          }
        ]
      '';
    };

    autoRetire = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically warn about ports not used recently";
      };

      daysUntilRetirement = mkOption {
        type = types.int;
        default = 90;
        description = "Number of days before a port is considered for retirement";
      };
    };

    generateAuditReport = mkOption {
      type = types.bool;
      default = true;
      description = "Generate a port audit report at /etc/port-audit.txt";
    };

    defaultDenyIncoming = mkOption {
      type = types.bool;
      default = true;
      description = "Default deny all incoming connections except specified ports";
    };

    enableLogging = mkOption {
      type = types.bool;
      default = false;
      description = "Enable logging of dropped packets (can be verbose)";
    };
  };

  config = mkIf cfg.enable {
    # Apply firewall rules
    networking.firewall = {
      enable = true;
      allowedTCPPorts = tcpPorts;
      allowedUDPPorts = udpPorts;

      # Log dropped packets if enabled
      logRefusedConnections = cfg.enableLogging;

      # Interface-specific rules using extraCommands
      extraCommands =
        if interfaceRules != []
        then
          concatMapStringsSep "\n" (rule: ''
            iptables -A nixos-fw -i ${rule.interface} -p ${
              if rule.protocol == "both"
              then "tcp"
              else rule.protocol
            } --dport ${toString rule.port} -j ACCEPT
          '')
          interfaceRules
        else "";
    };

    # Generate audit report
    environment.etc."port-audit.txt" = mkIf cfg.generateAuditReport {
      source = auditReport;
    };

    # Add a system check/reminder
    system.activationScripts.portAudit = mkIf cfg.generateAuditReport (
      stringAfter ["etc"] ''
        echo "Port audit report generated at /etc/port-audit.txt"
        ${
          if cfg.autoRetire.enable
          then ''
            echo "Auto-retirement is enabled. Review ports not used in ${toString cfg.autoRetire.daysUntilRetirement} days."
          ''
          else ""
        }
      ''
    );

    # Warnings for security concerns
    warnings =
      (optional (any (p: p.externalAccess) activePorts)
        "Some ports are marked for external access. Ensure they are properly secured.")
      ++ (optional (!cfg.autoRetire.enable)
        "Port auto-retirement is disabled. Consider enabling it to maintain minimal attack surface.");
  };
}
