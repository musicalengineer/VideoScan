# VideoScan Storage and RAID Recommendations

*Decision note — 2026-08-04. Prices are estimates and should be rechecked before purchase.*

## Short recommendation

- **Recommended:** OWC ThunderBay 4, **24TB raw enterprise HDD**, configured as RAID 5: about **18TB usable before formatting**, approximately **$2,200**.
- **Best value if the current price holds:** OWC ThunderBay 4, **32TB raw enterprise HDD**, RAID 5: about **24TB usable before formatting**, approximately **$2,380**.
- Retain the current LaCie as an **independent verified backup**. RAID is availability, not backup.
- Use the existing Crucial X10 as the explicit high-speed analysis tier and the X9 for staging/proxies. This is more predictable for VideoScan than a general-purpose SSD cache.
- Add a UPS if the array will use write caching. Allow roughly **$200–$350**, keeping the 32TB configuration near or under the $3,000 ceiling before tax.

OWC currently lists the 16TB, 24TB, and 32TB enterprise configurations at approximately $1,780, $2,200, and $2,380 respectively. Verify pricing, availability, installed drive models, warranty, and post-RAID capacity before ordering. [OWC ThunderBay 4](https://www.owc.com/solutions/thunderbay-4-thunderbolt-3)

## Good, better, best

| Level | Configuration | Approximate cost | RAID 5 usable capacity | Verdict |
|---|---|---:|---:|---|
| Good | ThunderBay 4, 16TB enterprise | $1,780 | 12TB | Enough today, but limited growth headroom |
| Better | ThunderBay 4, 24TB enterprise | $2,200 | 18TB | Recommended balance of cost, growth, and safety |
| Best under $3K | ThunderBay 4, 32TB enterprise | $2,380 | 24TB | Best current value; add UPS and remain near the cap |
| No new purchase | LaCie archive + X10 hot tier + X9 staging | $0 | Existing capacity | Useful interim arrangement, but not the durable destination |

Advertised capacity is **raw decimal capacity**, not formatted usable capacity. RAID 5 reserves one drive's capacity for parity; RAID 10 reserves half of the raw capacity.

## RAID choice

### RAID 5 — recommended for this purchase

- Approximately 75% capacity efficiency with four equal drives.
- Survives one drive failure.
- Strong sequential-read performance; OWC quotes up to roughly **770MB/s** for four-HDD RAID 5.
- Appropriate because a separate, verified backup will still exist.
- Performance falls and risk rises while rebuilding; replace a failed drive promptly.

### RAID 10 — robustness alternative

- Approximately 50% capacity efficiency.
- Faster and simpler rebuild behavior than RAID 5.
- Better write performance and potentially survives two failures, but only when the failures occur in different mirror pairs.
- A 24TB raw array becomes only about 12TB usable; a 32TB raw array becomes about 16TB usable.
- Choose RAID 10 only if rebuild behavior and write performance matter more than capacity.

### Avoid RAID 0 for masters

- Fast and capacity-efficient, but one failed drive loses the entire array.
- Acceptable only for reproducible scratch/cache data.

## Drive types to prefer

Preference order:

1. **Enterprise CMR HDD** — preferred when the premium is reasonable.
2. **NAS-rated CMR HDD** — good alternative for a four-bay enclosure.
3. **Desktop CMR HDD** — acceptable for backup or light use, not preferred for the primary working array.
4. **SMR or unspecified recording technology** — avoid in RAID.

The current 16TB enterprise ThunderBay listing specifies four Toshiba MG10-D 4TB 7,200-rpm CMR drives with 512MB cache and a five-year system warranty. The MG10-D family is designed for 24x7 operation, rated for 550TB/year, and specifies a two-million-hour MTBF. [OWC configuration](https://eshop.macsales.com/item/OWC/TB3SRE16.0S/) · [Toshiba MG10-D specifications](https://toshiba.semicon-storage.com/content/toshiba-ss-v3/emea/en_gb/top/storage/product/data-center-enterprise/enterprise-capacity/articles/mg10-d-series.html)

Enterprise drives are principally about sustained duty, vibration tolerance, RAID error behavior, workload rating, and warranty. They may be louder, warmer, and only modestly faster than regular 7,200-rpm drives.

## SSD cache and tiering

### Recommended: explicit SSD analysis tier

Use the Crucial X10 for:

- Catalog database and indexes
- Face embeddings and person attributes
- Frame timestamps and analysis results
- Thumbnails and preview images
- Frequently revised recipe results

Use the X9 for:

- Ingest staging
- Proxies and extracted clips
- Temporary read-ahead data
- Reproducible benchmark/test data

This gives SSD performance to the small, repeatedly accessed data while leaving large original videos on protected HDD storage. A persistent analysis store is particularly valuable because recipes can be rerun without decoding every video again.

### Automatic SSD-cached NAS option

Products such as the **QNAP TVS-h474** provide four HDD bays, two M.2 NVMe slots for SSD caching or an SSD pool, optional 10/25GbE, and Qtier automatic tiering under QTS. A complete system needs the enclosure, HDDs, two SSDs for a safe mirrored write tier, and preferably 10GbE; it is likely to approach or exceed **$3,000** depending on capacity. [QNAP TVS-h474](https://www.qnap.com/en-us/product/tvs-h474)

This is worth reconsidering if VideoScan becomes a multi-Mac service or the family portal is hosted at home. It is not the first purchase for accelerating the present scanner because:

- A cold, first sequential read still comes from HDD.
- Cache helps repeated random access much more than one-pass video scanning.
- Network, NAS administration, security, and cache policy add complexity.
- A write-back cache should be mirrored, use suitable SSDs, and be protected by a UPS.

Do not build a single-SSD write-back cache in front of irreplaceable media. A read-only cache is safer, but its acceleration will be workload-dependent.

## Purchase checklist

- Confirm whether the displayed capacity is raw capacity.
- Confirm the exact installed drive models; OWC reserves the right to substitute equivalent drives.
- Require CMR drives.
- Confirm the enclosure-plus-drive warranty and replacement process.
- Buy or verify a compatible UPS.
- Configure health monitoring and alerts in SoftRAID.
- Copy and checksum-verify the archive before changing any existing drive.
- Keep the LaCie intact until the new array has passed burn-in and verification.
- Maintain at least one backup on a different physical device; eventually add off-site or cloud archival protection for designated masters.

## Portal implication

Keep full-quality masters on the local protected array. The future family portal should hold metadata, thumbnails, previews, and explicitly published compressed derivatives—not the entire master archive. Portal storage and delivery can therefore scale independently from the local RAID.

## Current decision

The default purchase choice is **ThunderBay 4 24TB enterprise, RAID 5**. Before ordering, compare its final price with the **32TB enterprise** model: at the prices checked above, the 32TB unit offers substantially more headroom for only about $180 more and is the stronger value.
