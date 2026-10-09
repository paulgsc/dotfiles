# Trusted HTTPS on the LAN

Module: `nixos/subdomains` (`services.subdomains.tls` and `services.subdomains.lanDns`).

## The user story

Every device on the home network (desktop, laptop, Android phone, a guest's phone)
reaches the services on this machine by name over HTTPS, with a certificate it already
trusts. You don't install a mkcert CA on each device, and you never click "proceed
anyway". Once a browser has seen one of these names, it refuses a bad certificate or
plain HTTP for it outright (HSTS), so a warning page is no longer something you can click
through.

## How it fits together

```
                        Cloudflare (owns the domain)
                         │                     ▲
     public record       │                     │ 1. lego writes a TXT record
     *.home.<domain> →   │                     │    through the API token
     10.0.0.X (grey)     │                     │
                         ▼                     │
 devices that skip  ─► 1.1.1.1 ──────┐   ┌── nixos box ──────────────────────┐
 LAN DNS                             │   │ security.acme (lego)              │
                                     │   │   2. Let's Encrypt checks the TXT │
 devices on LAN DNS ─► dnsmasq ──────┼──►│   3. *.home.<domain> cert, renewed│
 (router hands out       on the box  │   │ Caddy :443 ── serves that cert    │
  10.0.0.X)                          │   │   └─ reverse_proxy to services    │
                                     ▼   └───────────────────────────────────┘
                          name → 10.0.0.X → HTTPS → lock icon
```

- **Certificate.** Let's Encrypt checks that you own the domain with the DNS-01 challenge:
  `lego` puts a TXT record in Cloudflare through an API token, Let's Encrypt reads it, and
  issues `*.home.<domain>`. Nothing on this machine is exposed to the internet: no port
  forwarding, no tunnel.
- **Names → this machine, two ways.** Some routers and ISPs drop public DNS answers that
  point at a private address like `10.0.0.X` (DNS-rebinding protection). To get around
  that:
  1. **LAN DNS (primary).** dnsmasq on this machine answers `home.<domain>` and every name
     under it from local data. The router hands it out as the network's DNS server, so
     those queries never reach the router's or ISP's resolver, and nothing can filter
     them. For every other name dnsmasq forwards to Cloudflare (1.1.1.1), not to the ISP,
     and it applies rebinding protection of its own to those names.
  2. **Public record (fallback).** The same name is also published in Cloudflare DNS, set
     to "DNS only". This covers a device that skips LAN DNS (Chrome's Secure DNS,
     Android's Private DNS, the router's secondary server), as long as the resolver it
     uses doesn't filter private answers. Cloudflare's 1.1.1.1 doesn't.

| Device resolves through                      | Answer comes from        | Can a rebind filter drop it? |
| -------------------------------------------- | ------------------------ | ---------------------------- |
| dnsmasq on this box (DHCP-provided)          | dnsmasq, locally         | No                           |
| 1.1.1.1 / Android Private DNS `one.one.one.one` | public Cloudflare record | No (encrypted, not filtered) |
| The router's own DNS or the ISP's            | public record            | **Yes**: avoid this path     |

## Steps

Placeholders: `<domain>` is the domain you bought on Cloudflare, and `10.0.0.X` is this
machine's LAN address.

### 1. Give this machine a fixed LAN address

Find its current address and MAC:

```sh
ip -4 -br addr        # e.g. enp3s0  UP  10.0.0.23/24
ip -br link           # MAC of the same interface
```

In the router's admin page, add a **DHCP reservation** (also called "static lease" or
"address reservation") that ties that MAC to that address. Everything below points at
this address, so it can't be allowed to change. It must be inside `10.0.0.0/24`, the
subnet the firewall admits.

### 2. Create a Cloudflare API token

dash.cloudflare.com → profile icon → **My Profile → API Tokens → Create Token** →
template **Edit zone DNS** → under _Zone Resources_ choose _Include · Specific zone ·
`<domain>`_ → **Continue → Create Token**. Copy the token: Cloudflare only shows it once.

This token can only edit DNS for this one zone. Don't use the Global API Key.

### 3. Put the token on this machine (never in git)

```sh
sudo install -d -m 0700 /var/lib/secrets
sudo sh -c 'umask 077; cat > /var/lib/secrets/cloudflare-dns-token'
# paste the token, press Enter, then Ctrl-D
sudo ls -l /var/lib/secrets/cloudflare-dns-token   # -rw------- root root
```

The file holds only the token. systemd hands it to the ACME service as a credential
(`LoadCredential`), so it stays root-only and never enters the Nix store.

### 4. Publish the fallback record in Cloudflare

dash.cloudflare.com → `<domain>` → **DNS → Records → Add record**:

| Type | Name     | IPv4 address | Proxy status            |
| ---- | -------- | ------------ | ----------------------- |
| A    | `*.home` | `10.0.0.X`   | **DNS only** (grey cloud) |

It must be grey: Cloudflare's proxy (orange) can't reach a private address. Let's Encrypt
doesn't use this record, so issuing works without it. It's there for the devices in the
table above. Publishing a private address is harmless: it can't be reached from outside
your network.

### 5. Turn it on in `nixos/configuration.nix`

```nix
subdomains = {
  enable = true;
  backend = "caddy";
  baseDomain = "home.<domain>";

  tls.enable = true;

  lanDns = {
    enable = true;
    address = "10.0.0.X";
  };

  hosts = {
    "file-host" = { ... };   # unchanged
  };
};
```

Then rebuild:

```sh
sudo nixos-rebuild switch --flake .#nixos
```

The build refuses to evaluate, with a message saying why, when `baseDomain` is still a
`.local` name, when a host name is not a valid DNS label (`file_host` with an underscore
isn't), or when a host overrides `domain`, which the wildcard certificate wouldn't cover.

### 6. Check it on the machine itself

```sh
# the certificate: issuer Let's Encrypt, names *.home.<domain> and home.<domain>
journalctl -u 'acme-*' -n 50 --no-pager
sudo openssl x509 -in /var/lib/acme/home.<domain>/cert.pem -noout \
  -issuer -ext subjectAltName -enddate

# LAN DNS answers locally
nix shell nixpkgs#dnsutils -c dig +short @10.0.0.X file-host.home.<domain>   # → 10.0.0.X

# Caddy serves the certificate (no -k: it must verify with the system trust store)
curl -sI --resolve file-host.home.<domain>:443:127.0.0.1 https://file-host.home.<domain>
```

### 7. Make the network use the LAN DNS

In the router's **LAN / DHCP settings**:

- **Primary DNS server:** `10.0.0.X`.
- **Secondary DNS server:** `1.1.1.1`. Clients sometimes use the secondary. When they do,
  they get the public record from step 4, and 1.1.1.1 doesn't filter it. Don't use the
  router's own address or the ISP's resolver here: that's where rebind filtering lives.
- If the router has a **DNS-rebind protection** setting with an exception list (OpenWrt
  `rebind_domain`, FRITZ!Box "DNS rebind protection exceptions", pfSense/OPNsense "Private
  domains"), add `home.<domain>` there too, for any device that still asks the router.

Devices pick up the new DNS server when they renew their lease. Toggling Wi-Fi off and on
is enough.

**If the router can't change the DHCP DNS server** (common on ISP-supplied routers), use
the public record and set encrypted DNS on each device instead. Your ISP can't filter or
rewrite encrypted DNS:

- **Android:** Settings → Network & internet → **Private DNS** → _Private DNS provider
  hostname_ → `one.one.one.one`.
- **Chrome / Edge on desktop:** Settings → Privacy and security → Security → **Use secure
  DNS** → Cloudflare (1.1.1.1).
- **Windows, system-wide:** Settings → Network → your adapter → DNS server assignment →
  Manual → `1.1.1.1`, DNS over HTTPS **On**.

### 8. Check it on every device

Open `https://file-host.home.<domain>`. You should see the lock icon with no warning, and
the certificate viewer should say _Issued by: Let's Encrypt_. If a device can't find the
name, see Troubleshooting.

### 9. Retire mkcert's trust

Once every device works, remove the mkcert root CA wherever it was installed. Until you do,
those devices still trust anything that CA signs:

- **Desktop with mkcert:** `mkcert -uninstall`.
- **Android:** Settings → Security & privacy → More security settings → **Encryption &
  credentials → User credentials**. Remove the `mkcert` entry.

`mkcert` itself can stay installed for `localhost`-only development. It just stops being
how other devices reach this machine.

## Living with it

- **Renewal is automatic.** A systemd timer (`acme-renew-home.<domain>.timer`) re-orders
  the certificate well before it expires, and Caddy reloads it. To see when it next runs:
  `systemctl list-timers 'acme-*'`.
- **Adding a service** is one entry under `hosts`. The wildcard certificate already covers
  `<name>.home.<domain>`, LAN DNS already answers it, and so does the `*.home` public
  record. Nothing changes in Cloudflare.
- **HSTS lasts a year.** Each host sends `Strict-Transport-Security: max-age=31536000`.
  Browsers that have seen it refuse plain HTTP and certificate errors for that name for a
  year, which is the point. It also means you can't quietly move one of these names back
  to HTTP.
- **What becomes public.** Let's Encrypt logs every certificate it issues in public
  Certificate Transparency logs. A wildcard keeps your service names out of them: only
  `*.home.<domain>` and `home.<domain>` appear. The public A record shows your private
  address, which is meaningless outside your network.
- **If this machine is down, so is LAN DNS for the primary server.** Clients fall back to
  the secondary (`1.1.1.1`), so the rest of the internet keeps working.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `acme-*` unit fails with `403` / `Authentication error` | Token scoped to the wrong zone, or the file has extra text | Re-create the token for `<domain>` (step 2); file holds only the token |
| `acme-*` fails with `NXDOMAIN` / `could not find zone` | `baseDomain` isn't under a zone in this Cloudflare account | `baseDomain` must end in `<domain>` exactly |
| `too many failed authorizations` / `rateLimited` | Repeated failing attempts hit Let's Encrypt's limits | Fix the cause, wait an hour; while experimenting set `security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";` (untrusted test certs), then remove it |
| One device: `DNS_PROBE_FINISHED_NXDOMAIN` | It uses neither LAN DNS nor a non-filtering resolver | Check its Private DNS / Secure DNS setting; renew its lease |
| `dig @10.0.0.X` times out from another device | Firewall or wrong address | `sudo iptables -S nixos-fw \| grep 'dport 53'`; `lanDns.address` must match step 1 |
| Browser warns `NET::ERR_CERT_COMMON_NAME_INVALID` | Name is two labels deep (`a.b.home.<domain>`) or not under `home.<domain>` | The wildcard covers one label: `<name>.home.<domain>` |
