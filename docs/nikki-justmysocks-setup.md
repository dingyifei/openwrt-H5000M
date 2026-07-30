# nikki + JustMySocks: auto-updating subs with automatic failover

This is the runtime setup for the **nikki** (mihomo/Clash.Meta) proxy that replaced v2rayA in
the loaded image. It shows how to get the two behaviours v2rayA lacked:

1. **Subscriptions that refresh themselves** (and keep the last-good copy if a refresh fails).
2. **Automatic failover** — when the server you're on goes down, mihomo switches to another
   node in your subscription on its own, and switches back when it recovers.

Both are native mihomo features (`proxy-providers` + a health-checked `url-test`/`fallback`
group); nikki is just the LuCI wrapper around mihomo. Nothing here is baked into the firmware —
**your JustMySocks credentials never live in the repo or image.** You paste your subscription
URL into the config once, on the device.

> The app ships config-less (same posture as v2rayA). This doc is the recipe you apply on first
> run. There is no default profile with nodes in it.

## 1. Get your JustMySocks subscription URL

JustMySocks gives you a **subscription link** (Services → your service → *"Subscription (Clash)"*
if offered, otherwise the plain *"Subscription"* link). Either works — mihomo's provider parser
reads Clash-format and base64 SS/v2ray lists. Copy that URL; it is what auto-updates.

## 2. Open nikki

LuCI → **Services → Nikki** (or `https://192.168.10.1/` → Services). The core is mihomo; nikki
runs it as a service and gives it the profile below.

## 3. The mihomo profile (the whole feature is here)

nikki runs a mihomo `config.yaml`. Point it at the profile below (paste your JustMySocks URL into
`url:`). This is the minimal config that does auto-update + failover; extend the `rules` to taste.

> This is exactly what the **`h5000m-nikki-defaults`** package ships to `/etc/nikki/profiles/jms.yaml`
> on a fresh install (with placeholder URLs) — so usually you just fill in the two `url:` fields.
> nikki's *mixin* supplies the ports/tun/dns/sniffer, so the profile only needs providers +
> groups + rules.

```yaml
# ---- the subscription(s), auto-refreshed -------------------------------------
# TWO providers = JMS's two mirror domains for the SAME service (jjsubmarines.com + jmssub.net).
# Paste your sub URL into both (same service/id, just the two domains): if one domain is blocked,
# the other still delivers the node list. JMS returns a base64 ss/vless/vmess list, which mihomo
# parses directly here (nikki's built-in "Subscription" page can't — it wants Clash YAML).
# `interval` is the auto-refresh period in SECONDS; a failed fetch keeps the last-good copy.
proxy-providers:
  jms:
    type: http
    url: "https://jjsubmarines.com/members/getsub.php?service=YOUR_SERVICE&id=YOUR_ID"
    path: ./providers/jms.yaml
    interval: 3600            # refresh hourly
    health-check: { enable: true, url: "https://www.gstatic.com/generate_204", interval: 60, timeout: 2000, lazy: true }
  jms-backup:
    type: http
    url: "https://jmssub.net/members/getsub.php?service=YOUR_SERVICE&id=YOUR_ID"
    path: ./providers/jms-backup.yaml
    interval: 3600
    health-check: { enable: true, url: "https://www.gstatic.com/generate_204", interval: 60, timeout: 2000, lazy: true }

# ---- the failover group ------------------------------------------------------
# url-test = automatic: mihomo keeps every node's latency fresh from the health-check above and
# routes through the lowest-latency HEALTHY node across BOTH providers. When your current node
# stops answering it is dropped and traffic moves to the next healthy one, then back when it
# recovers. `tolerance` stops flapping between two near-equal nodes.
proxy-groups:
  - name: PROXY
    type: select
    proxies: [AUTO]
    use: [jms, jms-backup]
  - name: AUTO
    type: url-test
    use: [jms, jms-backup]
    url: "https://www.gstatic.com/generate_204"
    interval: 60
    tolerance: 50             # ms

# LAN/private go DIRECT via IP-CIDR (no geodata download needed); everything else via PROXY.
# To also bypass mainland-China destinations, add `GEOIP,CN,DIRECT` before MATCH once mihomo
# geodata is in place (mihomo downloads the MMDB on first run; needs internet).
rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - MATCH,PROXY
```

### If you'd rather stick to one preferred node and only fall back on failure
Swap the `AUTO` group's `type: url-test` for `type: fallback`. `fallback` uses the **first** node
in order and only moves to the next when the current one fails its health check — then returns to
the preferred one once it is healthy again. Same health-check block drives it.

## 4. Apply and verify

1. Save the profile in nikki and **Enable** the service.
2. **Auto-update:** the provider fetches immediately, then every `interval`. In nikki's overview
   the `jms` provider shows a node count and a "last updated" time; it should tick over on
   schedule. A failed fetch leaves the previous nodes in place (check the mihomo log).
3. **Failover:** with traffic flowing through `AUTO`, make the current node unreachable (e.g. on
   the router, temporarily drop egress to that node's IP:port) and watch the active node in the
   `AUTO` group switch to another within a couple of health-check intervals — then switch back
   when you remove the block.

## Notes
- nikki requires nftables/firewall4 (this image uses fw4) and pulls `mihomo`, `curl`, `yq`, and
  the tproxy/tun kmods as dependencies — all handled by the package install.
- `mihomo` here is the **meta** core, built from source and signed with the H5000M plugin key
  (it is not in the official OpenWrt feeds). See `docs/superpowers/specs/` for the build design.
- This coexists with the FM350 cellular uplink; the proxy sits above whatever WAN mwan3 selects.
