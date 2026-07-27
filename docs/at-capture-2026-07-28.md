# FM350-GL AT capture — 2026-07-28

Captured on the live unit (`r35567-83369ca112`, firmware `81600.0000.00.29.21.24`) via
`atq -b`. This is the evidence base for the band-lock, cell-view and TTL features.

> **Privacy note.** The serving cell's `<cellid>` and `<tac>` are redacted below. Together with
> MCC/MNC they geolocate the device to a specific cell tower through public databases such as
> OpenCellID. Field *positions* are preserved so the parsers can still be written against this
> file. The neighbour rows report `FFFF`/`00FFFFFFF` from the modem itself and are unredacted.

---

## `AT+CLAC` — 37 commands

**This is not exhaustive.** `+CGACT`, `+CGDCONT`, `+EAPNACT`, `+GTACT`, `+GTCCINFO` and
`+GTCAINFO` are all absent from this list and all demonstrably work (see below). CLAC listing a
command proves it exists; **CLAC omitting one proves nothing.**

```
AT+CMEE     AT+ESUO      AT+ELCE      AT+EFD       AT+ESSTQ     AT+ESIMAPP   AT+CTZR
AT+ECSG     AT+EFCELL    AT+ECELL     AT+EONS      AT+EOPS      AT+COPS      AT+ECAL
AT+EDRAT    AT+EMODCFG   AT+ECREG     AT+ECGREG    AT+CIREG     AT+ECEREG    AT+EREGINFO
AT+EIPRL    AT+EDEFROAM  AT+EPBSE     AT+ENBR      AT+CPOL      AT$ROAM      AT+EFSS
AT+ERFTX    AT+ESRVSTATE AT+EAPC      AT+EROAMBAR  AT+CAPL      AT+ERAT      AT+EGMSS
AT+ERPRAT   AT+E5GOPT
```

### What this settles

- **No TTL command exists.** Nothing in the 37, and nothing in the 237-page manual. TTL must be
  done router-side — which is also what the vendor firmware did (`luci-app-qmodem-ttlfw4`, an
  fw4/nftables app).
- **Three undocumented cell-related commands exist**: `AT+EFCELL`, `AT+ECELL`, `AT+ENBR`. They are
  in CLAC but in neither the Fibocom manual nor any public source. Their set-command syntax is
  **unknown**, and guessing it is what wedged this modem before — see the probe results below.

> ⛔ **This list is NOT the set of cell-related commands.** `AT+EMMCHLCK` — which actually does
> cell locking, and works — is **absent from CLAC entirely**. That is the third time on this
> firmware that CLAC has omitted a working command (`+CGACT`, `+CGDCONT` and `+EAPNACT` were the
> others). The pattern matters more than any single command: **CLAC is a lower bound, never an
> inventory.** Reasoning from its absence has now produced two wrong conclusions in this project.

## `AT+EMMCHLCK` — cell locking (added 2026-07-28)

```
AT+EMMCHLCK=?  ->  +EMMCHLCK: (0-1),(0,2,7),(0,1),(0-46589),(0-511)
AT+EMMCHLCK?   ->  +EMMCHLCK: 0
                   +EMMCHLCK: 1,7,0,1650,187,0      <- locked; SIX fields, set form takes five
```

| Field | Range | Meaning |
|---|---|---|
| 1 | `0-1` | 0 unlock / 1 lock |
| 2 | `0,2,7` | RAT — GSM / UTRAN / E-UTRAN. **No NR** |
| 3 | `0,1` | unknown; `0` verified working |
| 4 | `0-46589` | EARFCN |
| 5 | `0-511` | PCI |

Full behavioural notes — the `CFUN`-for-reselection distinction, that a cell lock does not stop
NR, and that the circulating six-parameter NR example is rejected here — are in
`FM350-GL-SETUP.md` under "Cell locking works".

---

## `AT+GTACT=?` — authoritative capability list

```
+GTACT: (1,2,4,10,14,16,17,20),(2,3,6),(2,3,6),(),(1,2,4,5,8),
        (101,102,103,104,105,107,108,112,113,114,117,118,119,120,125,126,128,129,130,
         132,134,138,139,140,141,142,143,146,148,166,171),(),(),
        (501,502,503,505,507,508,5020,5025,5028,5030,5038,5040,5041,5048,5066,5071,
         5077,5078,5079)
```

Field order is `(rat),(pref1),(pref2),(gsm),(umts),(lte),(cdma),(evdo),(nr)`. GSM, CDMA and
EV-DO are empty — this radio has none.

| group | values | meaning |
|---|---|---|
| RAT | 1,2,4,10,14,16,17,20 | UMTS / LTE / LTE+UMTS / auto / NR / NR+WCDMA / NR+LTE / NR+WCDMA+LTE |
| UMTS | 1,2,4,5,8 | B I, II, IV, V, VIII |
| LTE | 101…171 | **B1,2,3,4,5,7,8,12,13,14,17,18,19,20,25,26,28,29,30,32,34,38,39,40,41,42,43,46,48,66,71** |
| NR | 501…5079 | **n1,2,3,5,7,8,20,25,28,30,38,40,41,48,66,71,77,78,79** |

**Encoding confirmed:** LTE band *N* → `100+N`. NR band *N* → the literal digits `50` followed by
*N* (so n1→`501`, n20→`5020`, n79→`5079`). Populate the picker from this call, not from a
hard-coded B1–B71 range.

## `AT+GTACT?` — current setting

```
+GTACT: 20,6,3,1,2,4,5,8,101,...,5079
```

RAT 20 (NR+WCDMA+LTE), pref1 6 (NR preferred), pref2 3 (LTE preferred), then every enabled band.
Note this is a **subset** of the capability list — `171`, `5040`, `5048`, `5071` are supported but
not currently enabled.

---

## `AT+GTCAINFO?` — carrier aggregation / MIMO

```
+GTCAINFO:
PCC:103,187,1650,100,100,2,1,2,1,-97
```

⚠️ **The real output has 10 fields; the manual documents 8 for PCC.** The manual omits
`<ul_bandwidth>` and the trailing RSRP from its PCC form. Observed layout:

| # | value | meaning |
|---|---|---|
| 1 | 103 | band → LTE **B3** |
| 2 | 187 | physical cell id (PCI) |
| 3 | 1650 | EARFCN |
| 4 | 100 | DL bandwidth → 20 MHz |
| 5 | 100 | UL bandwidth → 20 MHz |
| 6 | **2** | **`dl_mimo`** → 2×2 |
| 7 | **1** | **`ul_mimo`** |
| 8 | 2 | dl modulation |
| 9 | 1 | ul modulation |
| 10 | −97 | RSRP dBm |

No `SCC1:`/`SCC2:` line was present — no carrier aggregation active at capture time. Parsers must
treat SCC lines as optional and must not assume the manual's field count.

---

## `AT+GTCCINFO?` — serving + neighbour cells (feature 7, working)

```
+GTCCINFO:
1,4,460,1,<TAC>,<CELLID>,1650,187,103,100,8,44,44,19
2,4,,,FFFF,00FFFFFFF,1650,188,,42,42,15
2,4,,,FFFF,00FFFFFFF,1850,41,,26,26,9
2,4,,,FFFF,00FFFFFFF,1850,40,,21,21,9
```

First field is `<IsServiceCell>` (1 = serving, 2 = neighbour); second is `<rat>` (4 = LTE).
**The two rows have different field counts and different meanings** — the serving row carries
`<band>` and `<bandwidth>`, the neighbour row leaves them empty:

- serving: `1,4,<mcc>,<mnc>,<tac>,<cellid>,<earfcn>,<pci>,<band>,<bw>,<rssnr>,<rxlev>,<rsrp>,<rsrq>`
- neighbour: `2,4,,,<tac>,<cellid>,<earfcn>,<pci>,,<rxlev>,<rsrp>,<rsrq>`

Serving cell: EARFCN 1650, PCI 187, B3, 20 MHz, rsrp 44, rsrq 19.
Neighbours: PCI 188 on EARFCN 1650 (intra-frequency), PCI 41 and 40 on EARFCN 1850.

Conversion is the `rxlev` scale from manual §11.1.15, **not** the `+CESQ` scale:
`RSRP dBm = value − 140` (44 → −96, consistent with GTCAINFO's −97) and
`RSRQ dB = (value/2) − 19.5` (19 → −10.0).

---

## `AT+GTDUALSIM?` / `AT+SIMTYPE?`

```
+GTDUALSIM : 0, "SUB1", "L"
+SIMTYPE: 0
```

Slot 0 (physical SIM), SUB1, LTE service; SIMTYPE 0 = USIM.

⚠️ **Parser trap: there is a space before the colon** in `+GTDUALSIM :`, and spaces after each
comma. A regex anchored on `+GTDUALSIM:` will not match. `+SIMTYPE:` has no such space.

---

## Probe results for the undocumented commands

| probe | result | what it means |
|---|---|---|
| `AT+EFCELL=?` | `+CME ERROR: unknown` | **Not evidence of absence** — it is in CLAC. Same trap as `AT+EAPNACT=?`, which errors while the set form works |
| `AT+ECELL=?` | `OK`, no output | Exists; test form yields no parameter hints |
| `AT+ENBR=?` | `OK`, no output | Exists; test form yields no parameter hints |
| `AT+EPBSE=?` | `+EPBSE: 154,155,3138336991,42978,66,0,0,0,0,0` | Returns data rather than a value list. The large integers look like band **bitmasks** (cf. documented `+EPBSEH`, §11.1.12) |

**No set-command syntax was guessed and none should be.** `+GTACT` is documented, returns a clean
value list rather than a bitmask, and is already proven here — it is the band-lock mechanism.
`+ECELL`/`+ENBR`/`+EFCELL` are recorded as candidates for a future evidence-led investigation
into per-cell locking; they are *not* a basis for shipping a feature today.
