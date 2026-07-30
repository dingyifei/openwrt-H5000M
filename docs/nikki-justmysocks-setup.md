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

```yaml
# ---- basic transparent-proxy plumbing (nikki manages the tproxy/nft side) ----
mixed-port: 7890
mode: rule
log-level: warning
# nikki enables tun/tproxy itself; leave the interface bits to the LuCI app.

# ---- the subscription, auto-refreshed ----------------------------------------
# `interval` is the auto-update period in SECONDS: mihomo re-fetches on that schedule and, if a
# fetch fails, KEEPS the last good copy and retries next interval (exactly your "refresh subs in
# case they failed" requirement). health-check is what makes failover possible (below).
proxy-providers:
  jms:
    type: http
    url: "https://<PASTE-YOUR-JUSTMYSOCKS-SUBSCRIPTION-URL>"
    interval: 3600            # refresh hourly
    path: ./providers/jms.yaml
    # Only pull the nodes you actually want into the failover set. JustMySocks names its nodes
    # things like "JMS-xxx ..."; adjust the regex to include SS + v2ray but drop info/traffic
    # pseudo-nodes some panels inject.
    filter: "(?i)(jms|gia|bwg|shadowsocks|ss|v2ray|vmess)"
    exclude-filter: "(?i)(剩余|流量|expire|traffic|官网|website)"
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 60            # probe every 60s
      timeout: 2000           # ms
      lazy: true              # only probe the group that is actually in use

# ---- the failover group ------------------------------------------------------
# url-test = automatic: mihomo keeps every node's latency fresh from the health-check above and
# routes through the lowest-latency HEALTHY node. When your current node stops answering, it is
# dropped and traffic moves to the next healthy one automatically; when it recovers it becomes
# eligible again. `tolerance` stops it flapping between two near-equal nodes.
proxy-groups:
  - name: AUTO
    type: url-test
    use: [jms]
    url: https://www.gstatic.com/generate_204
    interval: 60
    tolerance: 50             # ms — don't switch for <50ms latency differences
  # A manual override group, handy for testing a specific node.
  - name: PROXY
    type: select
    proxies: [AUTO]
    use: [jms]

rules:
  - GEOIP,CN,DIRECT          # keep China-direct; nikki ships the geoip_cn nft rules too
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
