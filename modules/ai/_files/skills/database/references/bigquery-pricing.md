# BigQuery pricing — cost model and mitigations

> **Disclaimer:** Figures below are May 2026, US/EU multi-region,
> on-demand pricing. Prices change; check the
> [official page](https://cloud.google.com/bigquery/pricing) before
> any large workload.

## On-demand: **$6.25 per TiB scanned**

(TiB = 2⁴⁰ bytes, not decimal terabyte.) First 1 TiB per month per
billing account is free.

| Scanned | Cost (~) | Note |
|---|---|---|
| 1 byte | $5.7 × 10⁻¹² | theoretical |
| 1 KiB | $5.7 × 10⁻⁹ | irrelevant |
| 10 MiB | **$0.0000596** | **per-query minimum** (below) |
| 100 MiB | $0.0006 | ~0.06 ¢ |
| 1 GiB | **$0.0061** | ~half a cent |
| 100 GiB | $0.61 | |
| 1 TiB | **$6.25** | after free tier |
| 10 TiB | $62.50 | |
| 100 TiB | $625 | |
| 1 PiB | $6,400 | |

Rule-of-thumb: **~$0.006/GiB, ~$6/TiB, ~$6 000/PiB scanned.**

Storage on top: ~$0.02/GiB·month active, ~$0.01/GiB·month long-term
(after 90 days unmodified). First 10 GiB free.

## Cost traps

1. **Minimum 10 MiB billed per query.** Even `SELECT 1` costs
   $0.0000596 once the free tier is exhausted. 100k tiny queries/month ≈ $6.
2. **Minimum 10 MiB billed per *referenced* table.** Joins across many
   small tables multiply.
3. **`LIMIT` does not reduce cost.** BigQuery scans columns first, then
   limits. `SELECT * FROM huge LIMIT 10` ≈ `SELECT * FROM huge`.
4. **Cancellation may be fully billed** if the query started executing.
5. **`SELECT *` is the bankruptcy classic.** BigQuery is columnar —
   you pay per scanned column. `SELECT col_a` instead of `SELECT *` can
   drop the bill by orders of magnitude.
6. **Cache hits are free.** Identical query within 24 h against
   unchanged data = $0.

BigQuery Omni (queries vs AWS/Azure data via Omni): **$9.125/TiB**,
plus cross-cloud egress (~$0.09/GiB).

## Storage tiers

| Class | $/GiB·month | When |
|---|---|---|
| Active logical | $0.02 | modified tables |
| Long-term logical | $0.01 | 90+ days unmodified |
| Active physical | ~$0.04 | with physical-storage billing opted in |
| Long-term physical | ~$0.02 | physical + 90+ days |

## Estimating cost programmatically

```bash
# Bytes the query WOULD scan — no execution, no charge:
bq query --use_legacy_sql=false --dry_run --format=json \
   'SELECT col_a FROM `prj.ds.big` WHERE day = "2026-05-01"' \
   | jq '.statistics.totalBytesProcessed'

# Convert to USD ($6.25/TiB = $6.25 / 2^40 bytes)
bytes=$(bq query --use_legacy_sql=false --dry_run --format=json \
        'SELECT ...' | jq -r '.statistics.totalBytesProcessed')
echo "scale=4; $bytes / 1099511627776 * 6.25" | bc
```

The `bq.sh dry-run` subcommand does exactly this, printing bytes + EUR.

## Wrapper defaults

`bq.sh` always sets `--maximum_bytes_billed`. The default cap is
**214 748 364 800 bytes** (~200 GiB ~ 1 EUR at $6.25/TiB × 0.92 USD/EUR).
Override with `--max-bytes-billed N` or `$BQ_MAX_BYTES_BILLED`.

Caps above ~1 TiB (~5 EUR) require `--confirm-cost`. The wrapper warns
to stderr whenever the cap is raised above the default.

## Authoritative price sources

- Pricing page: <https://cloud.google.com/bigquery/pricing>
  (region selector; Frankfurt = europe-west3 has the same on-demand
  rate as US: $6.25/TiB; storage varies slightly).
- Calculator: <https://cloud.google.com/products/calculator>
- Cloud Billing Catalog API (programmatic, most accurate):

  ```bash
  curl -s "https://cloudbilling.googleapis.com/v1/services/24E6-581D-38E5/skus?key=$API_KEY" \
       | jq '.skus[] | select(.description | test("Analysis|On-Demand"))
             | {desc: .description, region: .serviceRegions[0],
                price: .pricingInfo[0].pricingExpression}'
  ```

  Docs: <https://cloud.google.com/billing/docs/reference/catalog/rest>
- SKUs browser: <https://cloud.google.com/skus/?filter=bigquery>
- Price-change feed:
  <https://cloud.google.com/feeds/google-cloud-platform-pricing-release-notes.xml>

## Mitigations (recommended for all agent workloads)

1. **`bq.sh`** (or `--maximum_bytes_billed` always) — hard safety net.
2. **Project-level custom quota** for daily maximum bytes:
   `gcloud alpha services quota` — survives compromised credentials and
   wrapper bypasses.
3. **Partition and cluster tables.** `WHERE day = '…'` on a partitioned
   table scans only that partition.
4. **`SELECT cols` explicitly.** Never `SELECT *` from a wide / large table.
5. **Cache before scaling.** Identical queries within 24 h are free.
