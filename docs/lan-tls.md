# Trusted HTTPS on the LAN

Module: `nixos/subdomains` (`services.subdomains.tls`). Secret: `nixos/secrets`.

## What this does

Devices on the home network reach the services on this machine by name, over HTTPS, with
a certificate they already trust: no mkcert CA to install on each device, no certificate
warning.

This is deliberately the smallest version. It adds no ports, no new service listening on
the network, and nothing on the router beyond a reserved address. One switch turns it on,
and the same switch turns it off again (see "Undo").

## How it fits together

```
   Cloudflare (DNS for maishatu.com)                       Let's Encrypt
     *.home.maishatu.com → 10.0.0.X                             │ 2. reads it,
        ▲  1. lego adds/removes a TXT record                     │    issues *.home.maishatu.com
        │     with the API token                                 │
 ┌── nixos box (10.0.0.X) ───────────────────────────────────────┴──┐
 │ security.acme (lego) ─► cert, renewed ─► Caddy :443 ─► services  │
 └───────────────────────────────────────────▲──────────────────────┘
                                             │ HTTPS, stays on the LAN
   phone / laptop ── "where is file-host.home.maishatu.com?" ──► the DNS it already
                     uses (Xfinity's) ──► Cloudflare: "10.0.0.X"
```

- **Certificate.** Let's Encrypt checks that you own the domain with the DNS-01 challenge:
  `lego` puts a TXT record in Cloudflare through an API token, Let's Encrypt reads it, and
  issues `*.home.maishatu.com`. The connection goes outward only; nothing has to reach this
  machine from the internet. The certificate's private key is made here and never leaves.
- **Names → this machine.** One public DNS record, `*.home.maishatu.com → 10.0.0.X`.
  Devices look it up through the DNS they already use. The address is private, so it's
  useless to anyone outside your network.
- **Traffic.** Devices talk to this machine directly over the LAN. Nothing is proxied
  through Cloudflare.

### Who sees what

| Party | Before | After |
| ----- | ------ | ----- |
| Your DNS resolver (Xfinity's) | Every domain the LAN looks up | The same, plus lookups of `*.home.maishatu.com` |
| Cloudflare | Nothing | Lookups of `*.home.maishatu.com`, arriving from Xfinity's resolver (not from your IP), and an API call adding/removing one random TXT record at each renewal (about every 60 days) |
| The public | Nothing | `*.home.maishatu.com` in Let's Encrypt's Certificate Transparency logs (not the service names), and the record showing the private address `10.0.0.X` |

## Steps

Placeholder: `10.0.0.X` is this machine's LAN address from step 1. Steps 1-5 change
nothing on this machine; step 6 is the switch.

### 1. Give this machine an address that never changes

**Why:** your router hands each device an address when it joins the network (DHCP), and
can hand out a different one next time, after a reboot or a power cut. The DNS record
in step 4 tells every device "`file-host.home.maishatu.com` is at 10.0.0.X", so X has to
stay put.

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

Write the address down for step 4. Xfinity gateways use `10.0.0.x` by default, which is
the range this config's firewall lets in.

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
nix shell nixpkgs#sops -c sops secrets/nixos.yaml
# add this line, save, quit:
#   cloudflare-dns-token: <the token from step 2>
git add secrets/nixos.yaml && git commit -m "secrets: cloudflare-dns-token"
```

`nixos/secrets` declares this secret as soon as `tls.enable` is on. A build where
`secrets/nixos.yaml` is missing, or doesn't contain `cloudflare-dns-token`, fails with a
message saying which.

### 4. Publish the record in Cloudflare

dash.cloudflare.com → `maishatu.com` → **DNS → Records → Add record**:

| Type | Name     | IPv4 address | Proxy status              |
| ---- | -------- | ------------ | ------------------------- |
| A    | `*.home` | `10.0.0.X`   | **DNS only** (grey cloud) |

It must be grey: Cloudflare's proxy (orange) can't reach a private address, and grey means
Cloudflare only answers lookups and never carries your traffic.

### 5. Test that the record reaches your devices

Before touching this machine, check that nothing between your devices and Cloudflare
drops the answer. Give it a few minutes after step 4, then on **each kind of device**:

- **Laptop/desktop (any OS):** `nslookup test.home.maishatu.com`
- **Android:** open Chrome and go to `http://test.home.maishatu.com`. If the name
  resolves, you get an error from Caddy on this machine, or a connection error, but
  *not* `DNS_PROBE_FINISHED_NXDOMAIN`. Do this on Wi-Fi, not mobile data.

`nslookup` should answer `10.0.0.X`. If every device does, go to step 6.

If a device gets no answer (`NXDOMAIN`, `can't find`, `Non-existent domain`), something
between it and Cloudflare drops answers that point at a private address. Stop here:
nothing on this machine has changed yet, and that case needs a different design (a DNS
server on the LAN), which this first cut deliberately leaves out.

### 6. Flip the switch in `nixos/configuration.nix`

At the top of the `subdomains` block:

```nix
trustedLan = true;
```

That moves `baseDomain` from `nixos.local` to `home.maishatu.com` and turns on `tls`.
Then rebuild:

```sh
sudo nixos-rebuild switch --flake .#nixos
```

The build fails, saying which, if `secrets/nixos.yaml` is missing or lacks
`cloudflare-dns-token`.

### 7. Check it on the machine itself

```sh
# the certificate: issuer Let's Encrypt, name *.home.maishatu.com
journalctl -u 'acme-*' -n 50 --no-pager
sudo openssl x509 -in /var/lib/acme/home.maishatu.com/cert.pem -noout \
  -issuer -ext subjectAltName -enddate

# Caddy serves the certificate (no -k: it must verify with the system trust store)
curl -sI --resolve file-host.home.maishatu.com:443:127.0.0.1 https://file-host.home.maishatu.com
```

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

- **New ports: none.** Caddy's 443 and 80 were already open to the LAN, and the
  certificate fetch only makes outgoing connections.
- **New services:** the ACME client (`acme-*` units, run on a timer, outgoing only) and
  the sops-nix step that decrypts the token at boot. Neither listens on the network.
- **The Cloudflare API token** can edit `maishatu.com`'s DNS records: with it, someone
  could point your names elsewhere or get a certificate for them. It's limited to DNS on
  this one zone and stored encrypted (docs/secrets.md). If it leaks, delete it in the
  Cloudflare dashboard and make a new one.
- **Your Cloudflare account** controls the domain itself. Turn on two-factor
  authentication.
- **Shrinks after step 9:** devices stop trusting the mkcert CA, which can sign a
  certificate for any site (`google.com` included).

## Undo

Set `trustedLan = false;` and rebuild, or `sudo nixos-rebuild switch --rollback`. Caddy is
back on `nixos.local` with its internal CA. The certificate, the Cloudflare record, the
token and the encrypted secret stay where they are and do nothing; delete the record and
the token in Cloudflare if you're abandoning this. Nothing is left behind in browsers.

## Living with it

- **Renewal is automatic.** A systemd timer (`acme-renew-home.maishatu.com.timer`)
  re-orders the certificate well before it expires, and Caddy reloads it:
  `systemctl list-timers 'acme-*'`.
- **Adding a service** is one entry under `hosts`. The wildcard certificate and the
  `*.home` record already cover `<name>.home.maishatu.com`.
- **Home names need the internet to resolve**, since the answer comes from Cloudflare.
  During an outage, devices that haven't cached the name won't find it.
- **Not included: forcing HTTPS in browsers (HSTS).** Without it, a browser that meets a
  bad certificate for these names still offers "proceed anyway". Adding it is one header
  in Caddy, but browsers then remember it for up to a year and nothing on this machine can
  take it back, so it's left for after this has run without trouble.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `acme-*` unit fails with `403` / `Authentication error` | Token scoped to the wrong zone, or a wrong value in the secret | Re-create the token for `maishatu.com` (step 2), `sops secrets/nixos.yaml` to replace it, rebuild |
| `acme-*` fails with `NXDOMAIN` / `could not find zone` | `maishatu.com` isn't a zone in this Cloudflare account | Check the domain in the Cloudflare dashboard |
| `too many failed authorizations` / `rateLimited` | Repeated failing attempts hit Let's Encrypt's limits | Undo, fix the cause, wait an hour |
| One device: `DNS_PROBE_FINISHED_NXDOMAIN` | Its DNS drops private answers | Step 5's test on that device; check Android Private DNS / Chrome Secure DNS settings |
| Browser warns `NET::ERR_CERT_COMMON_NAME_INVALID` | Name is two labels deep (`a.b.home.maishatu.com`) | The wildcard covers one label: `<name>.home.maishatu.com` |
| `502 Bad Gateway` | The service behind Caddy isn't running | e.g. `curl -sI http://127.0.0.1:3000` for file-host |
