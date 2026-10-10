{
  lib,
  config,
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
  hostActive = _name: hostCfg:
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

          # With a real certificate, tell browsers to refuse plain HTTP and
          # certificate warnings for this name from now on: once seen, there
          # is no "proceed anyway" button (docs/lan-tls.md, "The user story").
          ${optionalString cfg.tls.enable ''header Strict-Transport-Security "max-age=31536000"''}

          # Allow the user to inject custom Caddyfile snippets (like headers or matchers).
          ${hostCfg.extraConfig}
        '';
        # Serve the wildcard certificate security.acme fetches below instead of
        # letting Caddy pick an issuer itself (for *.local that was its own
        # internal CA, which no other device trusts).
        useACMEHost = mkIf cfg.tls.enable cfg.baseDomain;
      };
    };

  activeHosts = filterAttrs hostActive cfg.hosts;

  # A DNS label: what Let's Encrypt will put in a certificate. "file_host" is
  # not one (underscore), and a name the CA refuses fails the whole order.
  isDnsLabel = name: builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" name != null;
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

    # One publicly trusted wildcard certificate (*.baseDomain) from Let's
    # Encrypt, proved through Cloudflare's DNS API (DNS-01), so nothing on
    # this machine has to be reachable from the internet.  Every device
    # already trusts it: no mkcert CA to install, no "trust this site".
    # Walkthrough: docs/lan-tls.md.
    tls = {
      enable = mkEnableOption "a Let's Encrypt wildcard certificate for baseDomain via Cloudflare DNS-01";

      cloudflareTokenFile = mkOption {
        type = types.str;
        description = ''
          Runtime path of a file holding only a Cloudflare API token with
          Zone:DNS:Edit on the zone baseDomain lives in.  Read by systemd
          (LoadCredential), so it never enters the Nix store.  nixos/secrets
          sets it to the sops-nix secret; there is deliberately no default
          path for someone to remember to fill.
        '';
      };
    };

    # A resolver on this machine (Unbound) for the whole LAN.  It answers
    # baseDomain and every name under it with this machine's LAN address
    # from local data, so a router's or ISP's DNS-rebinding filter never sees
    # those names.  Every other name it resolves itself, from the root
    # servers down, with DNSSEC validation: no forwarder, so no third-party
    # resolver sees the LAN's lookups.  Hand it out as the LAN's DNS server
    # from the router (docs/lan-tls.md step 7).
    lanDns = {
      enable = mkEnableOption "a recursive LAN resolver (Unbound) answering baseDomain locally";

      address = mkOption {
        type = types.str;
        example = "10.0.0.2";
        description = "This machine's fixed IPv4 LAN address (reserve it in the router's DHCP).  Unbound listens here and on loopback only.";
      };

      allowedSubnets = mkOption {
        type = types.listOf types.str;
        default = ["10.0.0.0/24"];
        description = "Who may query it (Unbound access-control, and the firewall via networking.managedPorts).";
      };
    };

    # The 'hosts' attribute set where the user defines their subdomains.
    hosts = mkOption {
      type = types.attrsOf (types.submodule (_: {
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

    (mkIf cfg.tls.enable {
      assertions = [
        {
          assertion = !(hasSuffix ".local" cfg.baseDomain);
          message = ''
            services.subdomains.tls needs a domain you own (e.g. "home.example.com"),
            not "${cfg.baseDomain}": .local is mDNS-only and no public CA issues for it.
          '';
        }
        {
          assertion = all isDnsLabel (attrNames activeHosts);
          message = ''
            services.subdomains.hosts: with tls enabled every host name must be a DNS
            label (lowercase letters, digits, inner hyphens); got
            ${concatStringsSep ", " (filter (n: !isDnsLabel n) (attrNames activeHosts))}.
          '';
        }
        {
          assertion = all (h: h.domain == null) (attrValues activeHosts);
          message = ''
            services.subdomains.hosts.<name>.domain cannot be set with tls enabled:
            the one wildcard certificate covers only *.${cfg.baseDomain}.
          '';
        }
      ];

      # Caddy's own module adds group = "caddy" and reloadServices = caddy for
      # any cert a vhost names in useACMEHost, so renewals reach it unattended.
      security.acme = {
        acceptTerms = true;
        certs.${cfg.baseDomain} = {
          domain = "*.${cfg.baseDomain}";
          extraDomainNames = [cfg.baseDomain];
          dnsProvider = "cloudflare";
          credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = cfg.tls.cloudflareTokenFile;
          # lego finds the zone through a recursive resolver, then asks the
          # zone's own nameservers whether the TXT record is up.  With lanDns
          # on, use this machine's Unbound, which leaves _acme-challenge
          # names to recursion (below); without it, the system resolver.
          dnsResolver = mkIf cfg.lanDns.enable "127.0.0.1:53";
        };
      };
    })

    (mkIf cfg.lanDns.enable {
      assertions = [
        {
          assertion = builtins.match "([0-9]{1,3}\\.){3}[0-9]{1,3}" cfg.lanDns.address != null;
          message = ''
            services.subdomains.lanDns.address must be this machine's IPv4 LAN address
            (the router's DHCP reservation, docs/lan-tls.md step 1); got "${cfg.lanDns.address}".
          '';
        }
      ];

      services.unbound = {
        enable = true;
        # Serve the LAN only; this machine keeps resolving through whatever
        # NetworkManager is handed, so an Unbound failure cannot take its own
        # DNS down with it.  ACME asks 127.0.0.1 explicitly (above).
        resolveLocalQueries = false;
        settings.server = {
          # The LAN address and loopback, not 0.0.0.0: Docker's bridges make
          # this machine multihomed, and a wildcard bind can answer from the
          # wrong source address.  ip-freebind (module default) lets Unbound
          # start before DHCP has handed the address out.
          interface = ["127.0.0.1" cfg.lanDns.address];
          access-control = ["127.0.0.0/8 allow"] ++ map (net: "${net} allow") cfg.lanDns.allowedSubnets;

          # baseDomain and every name under it: this machine, from local data.
          local-zone = [
            ''"${cfg.baseDomain}." redirect''
            # ...except ACME's challenge names, which must resolve for real
            # (from Cloudflare's nameservers) for lego's propagation check.
            ''"_acme-challenge.${cfg.baseDomain}." transparent''
          ];
          local-data = [''"${cfg.baseDomain}. A ${cfg.lanDns.address}"''];

          # DNS-rebinding protection for every *other* name: an answer from
          # the internet that points into a private range is dropped.  Local
          # data above is not subject to it.
          private-address = [
            "10.0.0.0/8"
            "172.16.0.0/12"
            "192.168.0.0/16"
            "169.254.0.0/16"
            "fd00::/8"
            "fe80::/10"
          ];

          # Leak as little as the protocol allows: send each nameserver only
          # the labels it needs (the default, made explicit), say nothing
          # about this server.
          qname-minimisation = true;
          hide-identity = true;
          hide-version = true;
          # Refresh popular names before they expire, so the LAN rarely
          # waits on a full recursion.
          prefetch = true;
        };
      };

      networking.managedPorts.ports = [
        {
          port = 53;
          protocol = "both";
          service = "unbound";
          description = "LAN DNS (Unbound): answers ${cfg.baseDomain} locally, resolves the rest itself (services.subdomains.lanDns)";
          srcSubnets = cfg.lanDns.allowedSubnets;
        }
      ];
    })
  ]);
}
