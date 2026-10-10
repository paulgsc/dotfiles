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

### 1. Give this machine an address that never changes

**Why:** your router hands each device an address when it joins the network (DHCP), and
can hand out a different one next time, after a reboot or a power cut. Unbound tells
every device "`file-host.home.maishatu.com` is at 10.0.0.X", so X has to stay put.

**Find the current address.** On this machine:

```sh
ip -4 -br addr
```

```
lo        UNKNOWN  127.0.0.1/8
enp3s0    UP       10.0.0.23/24      ← this line: the address is 10.0.0.23
docker0   DOWN     172.17.0.1/16
```

Take the line that starts with `10.0.0.` and drop the `/24`. That's the address.

**Make the router always give it that address** ("DHCP reservation", "reserved IP",
"static lease": all the same thing). On an Xfinity gateway, either:

- **Xfinity app:** WiFi → find this machine in the device list (probably `nixos`) →
  **Reserve IP**, or
- **Browser:** open `http://10.0.0.1`, sign in with the gateway's admin password (on its
  label unless you changed it) → **Connected Devices → Devices** → this machine → **Edit**
  → **Reserved IP**, set to the address above.

Routers find the device by its hardware (MAC) address. If yours asks for it, it's on the
same line of `ip -br link` (e.g. `enp3s0 UP aa:bb:cc:dd:ee:ff`). Usually you just pick the
device from a list.

Then put the address in `nixos/configuration.nix` as `lanAddress` (step 5). Xfinity
gateways use `10.0.0.x` by default, which is the range this config's firewall lets in.

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

**On an Xfinity gateway**, check before you plan on the above. Open `http://10.0.0.1` →
**Gateway → Connection → Local IP Network** and look for a DNS server field. Many Xfinity
gateways don't let you change the DNS server they hand out at all. They also give devices
Xfinity's own **IPv6** DNS servers, which a phone may use alongside or instead of
Unbound. If there's no DNS field, the realistic options are:

- **Your own router behind the gateway (most robust).** Put the Xfinity gateway in
  **bridge mode** (Gateway → At a Glance → Bridge Mode) and plug in any router whose
  DHCP DNS setting you control. Your own router then does what this step describes.
- **Set the DNS on each device** (below). This works with the gateway as it is. Devices
  may still use Xfinity's IPv6 DNS servers for some lookups, so test each one with step 8.

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

## What this exposes

**To the internet: nothing new.** No port is forwarded. The gateway blocks unsolicited
inbound traffic, and this machine's firewall only admits `10.0.0.0/24` on 53, 80 and
443. Fetching the certificate goes *outward* (to Cloudflare's API and Let's Encrypt);
nothing has to reach in.

**To devices on your network:**

- **New: DNS on port 53 (Unbound).** Any device on the LAN can ask it to look names up.
  That's its job. It refuses anyone outside `10.0.0.0/24`, listens only on this machine's
  LAN address and loopback, and is a widely deployed, security-focused resolver.
- **Unchanged: HTTPS on 443 (Caddy).** It was already open to the LAN.
- **More eggs in one basket.** This machine now answers every device's DNS. If it's
  compromised, an attacker could send devices to wrong addresses. HTTPS limits the damage:
  a fake `bank.com` still can't produce a certificate your phone trusts. DNSSEC means
  forged answers from outside are rejected, which your ISP's resolver didn't guarantee.

**Off the network: the keys that matter.**

- **The Cloudflare API token** can edit `maishatu.com`'s DNS records. With it, someone
  could point your names elsewhere or get a certificate for them. It's limited to DNS on
  this one zone and stored encrypted (docs/secrets.md). If it leaks, delete it in the
  Cloudflare dashboard and make a new one.
- **Your Cloudflare account** controls the domain itself. Turn on two-factor
  authentication; it's worth more than anything in this file.

**Shrinks: the mkcert root CA.** Right now every device that trusts mkcert's CA would
accept a certificate for *any* site (`google.com` included) signed by the key in
`~/.local/share/mkcert` on your machine. Step 9 removes that trust. After it, devices
trust only certificates that public CAs issue and log publicly.

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
