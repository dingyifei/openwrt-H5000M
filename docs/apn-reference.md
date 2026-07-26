# APN reference — China, US, travel eSIM

Backing data for the FM350 auto-APN logic. **Confidence is recorded per row and must be
preserved** — several entries are provider-documentation-only and were never read off real
hardware. A wrong APN on this modem causes a *silent total data failure* (the SIM registers
normally, `+CEREG: 0,1`, and no traffic passes), so accuracy matters more than coverage.

Sources: AOSP `apns-full-conf.xml`, GNOME `mobile-broadband-provider-info`, ITU-T E.212B
(2023), Fibocom FM350 AT manual V2.10, AT&T KM1062162, 3GPP TS 27.007 / 24.301 / 29.272.

---

## ⭐ Read this first: blank APN is the primary path, the table is an optimisation

`AT+CGDCONT=1,"IPV4V6",""` (null APN) requests the **subscription default**, which 3GPP
guarantees exists:

- TS 27.007 §10.1.1 — *"If the value is null or omitted, then the subscription value will be
  requested."*
- TS 29.272 — the HSS `APN-Configuration-Profile` *"shall contain at least the default APN
  Configuration … the default APN shall always contain an explicit APN."*

So a blank APN is **self-correcting across every carrier, MVNO and travel eSIM**, whereas a
guessed APN yields ESM cause **#27** ("missing or unknown APN") or attaches to the wrong PGW
and black-holes traffic. **Never fall back to a guessed "common default" like `internet`** —
it is a real APN on some networks and rejected on others, converting a working blank attach
into a failure.

**Ladder:** blank → IMSI-table match → provider chain (eSIM) → manual override.
Advance the chain on **ESM #27**. Always read back **`AT+CGCONTRDP=1`** to learn what the
network actually granted.

> **Set the ATTACH APN, not just CID 1.** On LTE/5G the APN that governs attach is the
> **initial EPS bearer**, so `AT+CGDCONT=1` alone may not influence it. On Fibocom that is
> **`AT+EIAAPN`** — which is also the *only* way to supply PAP/CHAP here, since **the FM350
> has no `+CGAUTH`** (absent from the AT manual; QModem's mediatek branch has no auth block,
> unlike its qualcomm/lte/unisoc/huawei branches). Set both and confirm on hardware which
> takes effect.

> **An eSIM profile does NOT carry an APN.** The GSMA/TCA SAIP profile ASN.1 has no
> `ef-apn`/PDP-context element; the only APN-related file is the optional **`EF_ACL`**, which
> is a *restriction allow-list* (TS 31.102 §4.2.48), not a default-APN source. Phones "just
> work" because of a **device-side carrier database** (Android `apns-conf.xml`, iOS carrier
> bundles) that a router does not have. Travel eSIMs work with a blank APN because they are
> home-routed and the issuer's HSS supplies the default.

> **PDP type: always request `IPV4V6`.** If the subscription allows only one family the
> network **overrides inside an ACCEPT** with ESM cause #50/#51/#52 — never a reject
> (TS 24.301 §6.2.2). 94% of AOSP entries use IPV4V6. **Do not build PDP-type retry logic**,
> and **treat a single-family grant as SUCCESS** — the documented real-world failure is
> host-side (ModemManager tore down a working bearer on "activated with NwError=50" and
> retried, causing churn).

---

## 1. China — MCC 460

| MCC-MNC | Carrier | APN | PDP | Auth | Confidence | Notes |
|---|---|---|---|---|---|---|
| 46000 / 46002 / 46004 / 46007 / 46008 | China Mobile 中国移动 | `cmnet` | IPV4V6 | none | **High** | 46002/46007 retired TD-SCDMA; keep as aliases |
| 46001 / 46006 / 46009 | China Unicom 中国联通 | `3gnet` | IPV4V6 | none | **High** | 46006 GSM/UMTS shut down Dec 2023 |
| 46003 / 46005 / 46011 | China Telecom 中国电信 | `ctnet` | IPV4V6 | none | **High** | 46003/46005 ex-CDMA; ITU still mislabels 46003 as Unicom |
| **46015** | **China Broadnet 中国广电** | **`cbnet`** | IPV4V6 | none | **High** | Live 4th operator — was missing from our original list |
| 46013 / 46060 | China Mobile / Broadnet | `cmnet` | IPV4V6 | none | **Low** | AOSP only; absent from ITU and Wikipedia. Harmless as aliases |
| ~~46012~~ | — | — | — | — | — | **NOT AN ALLOCATED MNC — removed.** Absent from ITU E.212B (2023), Wikipedia MCC-460 and AOSP; it propagates through copied APN lists online |
| 46020 | China Tietong | — | — | — | — | GSM-R railway — **exclude, not consumer** |

**Auth is `none` on every Chinese row.** ⚠️ The GNOME `mobile-broadband-provider-info`
database is **wrong** here: it still lists CDMA/EVDO-era credentials (`guest`/`guest`,
`uninet`, `ctnet@mycdma.cn`). CDMA2000 shut down Dec 2023. Do not copy them.

### IoT APNs — never use on a consumer SIM
`cmiot` (Mobile) · `cuiot`, **`scuiot`**, `unim2m.*` (Unicom, province-specific) · `ctiot`
(Telecom) · `ctlte` (real, but not the consumer default).

> ⚠️ **Structural limit:** Chinese IoT SIMs broadcast the **same MCC-MNC as consumer SIMs**,
> so an IMSI-prefix table *cannot* distinguish them. It will confidently apply
> `cmnet`/`3gnet`/`ctnet` and the SIM will register but pass no traffic. This is another
> argument for blank-APN-first.
>
> Note `scuiot` is a China **Unicom** (Sichuan) IoT APN — our earlier docs called it China
> Mobile, which was wrong.

## 2. United States

| MCC-MNC | Carrier | APN | PDP | Confidence | Notes |
|---|---|---|---|---|---|
| 310410 + 310016/038/070/080/090/150/170/280/380/560/670/680/950, 311070/090/180/190, 312090 | AT&T | **`broadband`** | IPV4V6 | **High** | AT&T KM1062162: *"Data device: set to Broadband."* `nxtgenphone` is the phone-line fallback |
| 310260 + 310160/200/210/220/230/240/250/270/300/310/490/580/660/800; ex-Sprint 310120, 311882, 312530 | T-Mobile US | **`fast.t-mobile.com`** | IPV4V6 | **High** | **IPv6-only in practice** — see 464XLAT below |
| 311480 + 310004/010/012, 311270–311289, 310890, 310910, 311110 | Verizon | **`vzwinternet`** | IPV4V6 | **High** | IPv4v6 is contractually mandated by Verizon Open Development |
| 310260 / 310240 | Google Fi | `h2g2` | IPV4V6 | **High** | AOSP `user="none" password="none"` is a sentinel, not a credential |
| 310150 / 310410 | Cricket | `endo` | IPV4V6 | **High** | verified in AOSP; `ndo` is **not** |
| 310260 / 311660 | Metro by T-Mobile | `fast.metropcs.com` | IPV4V6 | **High** | AOSP says IPV6 — override to IPV4V6 |
| 310260 | US Mobile Light Speed / Consumer Cellular | `wholesale` | IPV4V6 | Medium | sub-brand mapping unverified |
| 310410 / 310280 | US Mobile Dark Star / Consumer Cellular / Boost / TracFone-ATT | `ereseller` | IPV4V6 | Medium | |
| 311960 | Lycamobile | `data.lycamobile.com` | IPV4V6 | **High** | |
| 310300 / 310690 | Truphone / 1GLOBAL | `truphone.com` | IPV4V6 | **High** | GID `547275554B3030656E` = `TruUK00en` |
| 310380 | GigSky | `gigsky` | IPV4V6 | **High** | |
| 310260 | TracFone (legacy T-Mo) | `wap.tracfone` | **IP** | Medium | AOSP marks IPv4-only |
| — | T-Mobile Home Internet | `fbb.home` | IPV4V6 | **Low** | 0 hits in AOSP; plan-bound, not device-bound |

**Use the host APN (no entry needed):** Mint → `fast.t-mobile.com`; Visible / Straight Talk /
Xfinity / Spectrum / US Mobile Warp → `vzwinternet`.

**Never embed:** `VSBLINTERNET`, `att.mvno`, `tfdata`, `pwg`, `gigsky-02`, `gigsky.global`,
`fast.metrobyt-mobile.com`, `ndo`, `ccdata`, or `we01.vzwstatic` as a default (static-IP APN;
wrong region prefix = total failure).

> ⚠️ **IMSI cannot disambiguate US MVNOs.** `310260` alone covers T-Mobile, Mint, Metro,
> Google Fi, TracFone, Consumer Cellular, US Mobile Light Speed and Simple Mobile. AOSP
> disambiguates by **GID1 / SPN / full-IMSI prefix**, never MCC-MNC — the modern AT&T,
> T-Mobile and Verizon entries carry *no* `mcc`/`mnc` at all. Doing this properly needs
> `AT+CRSM` (EF_GID1) and `AT+CSPN?`. Blank-APN sidesteps it entirely.

> ⚠️ **T-Mobile US requires router-side 464XLAT.** Their core is IPv6-only; IPv4 comes from
> CLAT. The FM350's Intel XMM **does not run CLAT itself**, so without `464xlat` +
> `kmod-nat46` on the router, IPv4 silently fails and looks exactly like a wrong APN.
> Requesting `IPV4V6` is the *recommended* setting there — it is what lets CLAT surface IPv4.

## 3. Travel eSIM — provider-keyed, NOT MCC-MNC-keyed

Multi-IMSI applets (Airalo, Jetpac, Firsty, Roamless) **swap the IMSI per country**, and some
backends have no PLMN at all — verified: `<apn carrier="Webbing" carrier_id="2631"
apn="wbdata" protocol="IPV4V6"/>` has **no `mcc`/`mnc` attribute whatsoever**, and Webbing is
the backend behind Saily and several Airalo packages. **Key off ICCID / SM-DP+ / profile
nickname via `lpac`** — the ICCID is stable when the IMSI is not.

| Provider | APN chain | Confidence | Notes |
|---|---|---|---|
| Ubigi | `""` → `mbb` → `mobiledata` | Medium-High | `mbb` from Ubigi docs (0 AOSP hits); `mobiledata` from AOSP 901/37. `netgprs.com` is Transatel's old MVNO — **excluded** |
| Airalo | `""` → `globaldata` → `wbdata` → `singleall` | Low | APN is per-package; many packages have none |
| 1GLOBAL / Truphone | `truphone.com` | **High** | `iot.truphone.com` is IoT SKUs only |
| GigSky | `gigsky` | **High** | |
| Saily | `wbdata` → `truphone.com` | Medium | backend migrated ~late 2025 — ship both |
| Holafly | `Global` | Low | capitalisation unverified |
| Nomad | `""` → `internet`/`globaldata`/`truphone.com`/`bicsapn`/… | Low | keyed by backend "colour" the user must read from the app — firmware cannot derive it |
| aloSIM / Maya / Roamless | `alosim`→`globaldata` / `globaldata` / `roamless`→`bicsapn` | Low | 0 AOSP hits |
| **Firsty** | `bicsapn` → `e-ideas` | Low | ⛔ **Firsty-on-Singtel needs PAP/CHAP (`65ideas`)** — impossible via `AT+CGDCONT` here (no `+CGAUTH`), and TS 24.301 §6.5.1.2 says PAP/CHAP is exactly the case where an explicit APN is mandatory, so blank cannot work either. Only `AT+EIAAPN` could configure it |
| **Jetpac** | `globaldata` \| `tn1` \| `kroly` \| … | Low | ⛔ **Unsuitable for a headless router** — needs an IMSI slot (2/7/25/26) chosen via SIM Toolkit; no APN value compensates if it lands wrong. Document as unsupported |
| Yesim / Instabridge | `""` | Medium | no APN documented; blank is correct |

## 4. What is NOT verified

**No PLMN in the travel-eSIM section was read off real hardware.** These were unverifiable
before the research session's search budget was exhausted: `fbb.home`; the Boost/EchoStar
shutdown and `313340`; UScellular PLMNs; Spectrum Mobile; Xfinity's enterprise APN; US Mobile
sub-brand mapping; Holafly's capitalisation; the entire Jetpac country table. `singleall`,
`alosim`, `roamless`, `kroly`, `tn1` and `mbb` all have **0 hits in AOSP** and are
provider-documentation-only.

Treat every **Low** row as a hint to try, never as fact — which is precisely why the ladder
starts blank.
