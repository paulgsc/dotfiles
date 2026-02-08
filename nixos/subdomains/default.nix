{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  # 'cfg' is a shorthand for our custom option path to keep the code readable.
  cfg = config.services.subdomains;

  # HELPER: serviceEnabled
  # This checks the global NixOS 'config' to see if a specific systemd service
  # (like 'plex' or 'nextcloud') is actually enabled. We use this later to
  # automatically hide a subdomain if the underlying service is turned off.
  serviceEnabled = name: let
    svc = config.systemd.services.${name} or null;
  in
    if svc == null
    then false
    else (svc.enable or false);

  # HELPER: fqdn
  # Constructs the full URL. If a specific host has a 'domain' override, use it;
  # otherwise, append the subdomain name to the 'baseDomain'.
  fqdn = name: hostCfg: let
    suffix =
      if hostCfg.domain != null
      then hostCfg.domain
      else cfg.baseDomain;
  in "${name}.${suffix}";

  # HELPER: hostActive
  # A logic gate: A subdomain is only "active" if:
  # 1. The subdomain itself is enabled.
  # 2. It isn't tied to a systemd service, OR the tied service is enabled.
  hostActive = name: hostCfg:
    hostCfg.enable && (hostCfg.service == null || serviceEnabled hostCfg.service);

  # RENDERER: renderCaddy
  # This function transforms our high-level 'hosts' options into the
  # specific structure 'services.caddy.virtualHosts' expects.
  renderCaddy = name: hostCfg: let
    fullDomain = fqdn name hostCfg;
  in
    # mkIf ensures that if the host isn't active, no config is generated at all.
    mkIf (hostActive name hostCfg) {
      # The attribute name here (e.g., "api.example.com") becomes the Caddy site address.
      ${fullDomain} = {
        # Caddy's 'extraConfig' is a multi-line string that acts as the Caddyfile body.
        extraConfig = ''
          # If proxyPass is set, generate a 'reverse_proxy' directive.
          # Unlike Nginx, Caddy handles Websockets automatically here.
          ${optionalString (hostCfg.proxyPass != null) "reverse_proxy ${hostCfg.proxyPass}"}

          # If a root path is set, tell Caddy where files live and enable the file server.
          ${optionalString (hostCfg.root != null) ''
            root * ${hostCfg.root}
            file_server
          ''}

          # Allow the user to inject custom Caddyfile snippets (like headers or matchers).
          ${hostCfg.extraConfig}
        '';
      };
    };
in {
  options.services.subdomains = {
    # Main toggle for this entire custom module.
    enable = mkEnableOption "Declarative subdomain management";

    # We keep 'backend' so you can toggle between webservers if you ever switch back.
    backend = mkOption {
      type = types.enum ["nginx" "caddy"];
      default = "caddy";
      description = "The webserver backend that will actually serve the traffic.";
    };

    baseDomain = mkOption {
      type = types.str;
      description = "The default root domain (e.g., 'mydomain.com').";
    };

    # These 'defaults' are largely placeholders for Caddy since it manages
    # SSL (ACME) and WebSockets by default without needing manual flags.
    defaults = {
      acme = mkOption {
        type = types.bool;
        default = true;
      };
      forceSSL = mkOption {
        type = types.bool;
        default = true;
      };
    };

    # The 'hosts' attribute set where the user defines their subdomains.
    hosts = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          enable = mkEnableOption "Enable this specific subdomain";

          domain = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Override baseDomain (e.g., use a .net instead of .com).";
          };

          service = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Only show this subdomain if this systemd service is running.";
          };

          proxyPass = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "The internal URL to proxy to (e.g., 'http://127.0.0.1:8080').";
          };

          root = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to static files if not proxying.";
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Raw Caddyfile lines to add to this virtual host.";
          };
        };
      }));
      default = {};
    };
  };

  # The actual work happens here: translating our options into NixOS system settings.
  config = mkIf cfg.enable (mkMerge [
    # If the user chose 'caddy' as the backend:
    (mkIf (cfg.backend == "caddy") {
      # 1. Enable the official NixOS Caddy service.
      services.caddy.enable = true;

      # 2. Map over our 'hosts' list and apply the 'renderCaddy' function to each.
      # mapAttrsToList returns a list of configs, and mkMerge flattens them into one set.
      services.caddy.virtualHosts = mkMerge (mapAttrsToList renderCaddy cfg.hosts);
    })
  ]);
}
