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
   Cloudflare (authoritative DNS for maishatu.com)         Let's Encrypt
        ▲  1. lego adds/removes a TXT record                  │ 2. reads it,
        │     with the API token                              │    issues *.home.maishatu.com
 ┌── nixos box (10.0.0.X) ─────────────────────────────────────┴───────┐
 │ security.acme (lego) ─► cert, renewed ─► Caddy :443 ─► services     │
 │ Unbound :53  home.maishatu.com, *.home.maishatu.com → 10.0.0.X      │
 │              everything else → resolved itself, from the root down  │
 └──────────────▲───────────────────────────────────▲─────────────────┘
                │ DNS (router hands out 10.0.0.X)   │ HTTPS, stays on the LAN
          phones, laptops, desktops ────────────────┘
```

- **Certificate.** Let's Encrypt checks that you own the domain with the DNS-01 challenge:
  `lego` puts a TXT record in Cloudflare through an API token, Let's Encrypt reads it, and
  issues `*.home.maishatu.com`. Nothing on this machine is exposed to the internet: no
  port forwarding, no tunnel. The certificate's private key is made on this machine and
  never leaves it.
- **Names → this machine.** Some routers and ISPs drop public DNS answers that point at a
  private address like `10.0.0.X` (DNS-rebinding protection). So the names don't depend on
  public DNS: Unbound on this machine answers `home.maishatu.com` and every name under it
  from local data, and the router hands Unbound out as the network's DNS server. Those
  queries never leave the LAN, so nothing can filter them.
- **Everything else.** Unbound is a full resolver, not a forwarder: it looks every other
  name up itself, starting at the root servers, and checks DNSSEC signatures. No
  third-party resolver (Cloudflare's 1.1.1.1, Google's 8.8.8.8, or the ISP's) is in the
  path. It also drops any answer from the internet that points into a private range, the
  same rebinding protection the router had.
- **Traffic.** Devices talk to this machine directly over the LAN. Nothing is proxied
  through Cloudflare.

### Who sees what

| Party | Before (status quo) | After |
| ----- | ------------------- | ----- |
| ISP's DNS resolver | Every domain the LAN looks up | Nothing: it is no longer asked |
| ISP, on the wire | Which servers you connect to, plus your DNS queries | The same. Unbound's queries to nameservers are unencrypted, so the ISP can still read them |
| Each site's nameservers | Lookups for their own domain, from the ISP's resolver | Lookups for their own domain, from your public IP. With qname minimisation, root and TLD servers only see the part of the name they serve (e.g. `com.`) |
| Cloudflare | Nothing | An API call to add/remove one random TXT record at each renewal (about every 60 days). It already hosts the domain's DNS |
| Let's Encrypt / the public | Nothing | `*.home.maishatu.com` and `home.maishatu.com` in Certificate Transparency logs. Not the service names |

## Steps

Placeholder: `10.0.0.X` is this machine's LAN address. The domain is `maishatu.com`, and
the services live under `home.maishatu.com`.

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
`maishatu.com`_ → **Continue → Create Token**. Copy the token: Cloudflare only shows it once.

This token can only edit DNS for this one zone. Don't use the Global API Key.

### 3. Store the token as an encrypted secret

The token goes into `secrets/nixos.yaml`, encrypted and committed with everything else
(sops-nix). Every machine decrypts it at boot with its own SSH host key, into
`/run/secrets/cloudflare-dns-token`. There is no file to copy onto a machine and nothing
to remember per machine.

If you haven't done the one-time setup yet, follow [docs/secrets.md](secrets.md) →
"One-time setup". Then add the token:

```sh
sops secrets/nixos.yaml
# add this line, save, quit:
#   cloudflare-dns-token: <the token from step 2>
git add secrets/nixos.yaml && git commit -m "secrets: cloudflare-dns-token"
```

`nixos/secrets` declares this secret as soon as `tls.enable` is on. A build where
`secrets/nixos.yaml` is missing, or doesn't contain `cloudflare-dns-token`, fails with a
message saying which.

### 4. (Optional) Publish a public record for devices that skip the LAN DNS

Skip this unless some device won't use the LAN DNS (step 7). Let's Encrypt doesn't need it,
and every device on the LAN DNS gets its answer from Unbound.

dash.cloudflare.com → `maishatu.com` → **DNS → Records → Add record**:

| Type | Name     | IPv4 address | Proxy status              |
| ---- | -------- | ------------ | ------------------------- |
| A    | `*.home` | `10.0.0.X`   | **DNS only** (grey cloud) |

It must be grey: Cloudflare's proxy (orange) can't reach a private address. It adds no new
party, since Cloudflare already serves this domain's DNS, but it does publish your private
address (harmless: unreachable from outside), and routers or resolvers with rebind
protection will still drop it.

### 5. Flip the switch in `nixos/configuration.nix`

The `subdomains` block starts with two values. Set the address from step 1 and flip the
switch:

```nix
trustedLan = true;
lanAddress = "10.0.0.X";
```

`trustedLan` moves `baseDomain` from `nixos.local` to `home.maishatu.com` and turns on
`tls` and `lanDns` together. Then rebuild:

```sh
sudo nixos-rebuild switch --flake .#nixos
```

The build refuses to evaluate, with a message saying why, when `lanAddress` isn't an IPv4
address (the committed `"10.0.0.?"` isn't), when `secrets/nixos.yaml` lacks the token,
when a host name is not a valid DNS label (`file_host` with an underscore isn't), or when
a host overrides `domain`, which the wildcard certificate wouldn't cover.

### 6. Check it on the machine itself

```sh
# the certificate: issuer Let's Encrypt, names *.home.maishatu.com and home.maishatu.com
journalctl -u 'acme-*' -n 50 --no-pager
sudo openssl x509 -in /var/lib/acme/home.maishatu.com/cert.pem -noout \
  -issuer -ext subjectAltName -enddate

# LAN DNS answers home names locally...
nix shell nixpkgs#dnsutils -c dig +short @10.0.0.X file-host.home.maishatu.com   # → 10.0.0.X
# ...and resolves everything else itself, with DNSSEC ("ad" in the flags line)
nix shell nixpkgs#dnsutils -c dig @10.0.0.X nixos.org | grep -E 'flags|status'
# ...and refuses a forged signature (status: SERVFAIL)
nix shell nixpkgs#dnsutils -c dig @10.0.0.X dnssec-failed.org | grep status

# Caddy serves the certificate (no -k: it must verify with the system trust store)
curl -sI --resolve file-host.home.maishatu.com:443:127.0.0.1 https://file-host.home.maishatu.com
```

### 7. Make the network use the LAN DNS

In the router's **LAN / DHCP settings**, set the **DNS server** handed to clients to
`10.0.0.X`.

**The secondary DNS server** is a trade-off, because devices use it now and then even
while the primary is up:

- **Leave it empty** (recommended). Every lookup goes through Unbound and nothing else.
  If this machine is off, the LAN has no DNS until it's back.
- **Set it to the router's own address.** The internet keeps resolving while this machine
  is off, through the ISP as before. But a device that happens to use it gets
  `*.home.maishatu.com` only from the optional public record (step 4), and only if the
  router or ISP doesn't filter it. Expect an occasional "site can't be reached" for a home
  name. Don't add a public resolver here (1.1.1.1, 8.8.8.8): that brings back the
  middleman this setup removes.

Devices pick up the new DNS server when they renew their lease. Toggling Wi-Fi off and on
is enough.

**Two device settings bypass the LAN DNS whatever the router says.** Check both:

- **Android → Settings → Network & internet → Private DNS:** set it to **Off** or
  **Automatic**. A provider hostname (e.g. `dns.google`) sends every lookup to that
  provider instead. Automatic tries encrypted DNS to Unbound, which doesn't offer it,
  then falls back to plain DNS to Unbound.
- **Chrome / Edge → Settings → Privacy and security → Security → Use secure DNS:**
  choose **"With your current service provider"** (or turn it off), not a named
  provider.

**If the router can't change the DNS server** (common on ISP-supplied routers), set it on
each device instead:

- **Windows:** Settings → Network → your adapter → DNS server assignment → Manual →
  `10.0.0.X`.
- **Linux (NetworkManager):** `nmcli con mod <connection> ipv4.dns 10.0.0.X
  ipv4.ignore-auto-dns yes`, then reconnect.
- **Android:** long-press the Wi-Fi network → Modify → Advanced → IP settings **Static**,
  DNS 1 `10.0.0.X`. This also pins the phone's address, so pick one outside the router's
  DHCP range.

Another option is to turn the router's DHCP off and let this machine serve DHCP too.
That's a bigger change and isn't covered here.

### 8. Check it on every device

Open `https://file-host.home.maishatu.com`. You should see the lock icon with no warning, and
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

- **Renewal is automatic.** A systemd timer (`acme-renew-home.maishatu.com.timer`) re-orders
  the certificate well before it expires, and Caddy reloads it. To see when it next runs:
  `systemctl list-timers 'acme-*'`.
- **Adding a service** is one entry under `hosts`. The wildcard certificate already covers
  `<name>.home.maishatu.com`, and Unbound already answers it (so does the `*.home` public
  record, if you made one). Nothing changes in Cloudflare.
- **HSTS lasts a year.** Each host sends `Strict-Transport-Security: max-age=31536000`.
  Browsers that have seen it refuse plain HTTP and certificate errors for that name for a
  year, which is the point. It also means you can't quietly move one of these names back
  to HTTP.
- **What becomes public.** See "Who sees what" above.
- **If this machine is down, LAN DNS is down with it** (unless you set a secondary, step
  7). The services on it are down then anyway. Other sites resolve again once it's back.
- **Unbound keeps its DNSSEC root key current by itself** (`/var/lib/unbound/root.key`).
  Nothing to renew by hand.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `acme-*` unit fails with `403` / `Authentication error` | Token scoped to the wrong zone, or a wrong value in the secret | Re-create the token for `maishatu.com` (step 2), `sops secrets/nixos.yaml` to replace it, rebuild |
| `acme-*` fails with `NXDOMAIN` / `could not find zone` | `baseDomain` isn't under a zone in this Cloudflare account | `baseDomain` must end in `maishatu.com` exactly |
| `too many failed authorizations` / `rateLimited` | Repeated failing attempts hit Let's Encrypt's limits | Fix the cause, wait an hour; while experimenting set `security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";` (untrusted test certs), then remove it |
| One device: `DNS_PROBE_FINISHED_NXDOMAIN` for a home name | It isn't using the LAN DNS | Check its Private DNS / Secure DNS settings (step 7); renew its lease; `nslookup file-host.home.maishatu.com` shows which server answered |
| Every device: some sites won't resolve (`SERVFAIL`) | DNSSEC validation failed, or Unbound can't reach nameservers | `journalctl -u unbound -n 50`. A site with broken DNSSEC fails for everyone using a validating resolver; that's validation working |
| `dig @10.0.0.X` times out from another device | Firewall or wrong address | `sudo iptables -S nixos-fw \| grep 'dport 53'`; `lanDns.address` must match step 1 |
| Browser warns `NET::ERR_CERT_COMMON_NAME_INVALID` | Name is two labels deep (`a.b.home.maishatu.com`) or not under `home.maishatu.com` | The wildcard covers one label: `<name>.home.maishatu.com` |
