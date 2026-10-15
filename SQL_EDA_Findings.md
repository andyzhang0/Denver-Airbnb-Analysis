# Denver Airbnb — SQL EDA Findings

**Source:** `Denver Airbnb Analysis SQL EDA.ipynb`, including its EDA and profiling notes. Figures below are transcribed from the notebook; this document does not represent a fresh query execution.

## Scope and methodology
- Snapshot contains **4,939 listings**; **4,251** have usable nightly prices and **688** lack a source price. There were **zero failed price conversions**.
- Listing, calendar and review grains differ. Calendar availability is **not confirmed occupancy**; estimated occupancy/revenue metrics are modeled estimates, not observed transactions.
- The original notebook's analysis-ready CTEs were frozen on **October 1, 2026**. Preserve the notebook as the comprehensive audit trail.

## Selected findings

1. **Entire homes dominate supply.** Entire-home/apartment listings account for **4,233 / 4,939 (85.71%)**. Segment comparisons by room type rather than treating the market as homogeneous.
2. **Supply is distributed, with meaningful geographic concentration.** The top five neighborhoods hold **26.67%** of listings and the top ten **42.01%**. Neighborhood share should be interpreted alongside listing counts.
3. **Prices are strongly right-skewed.** Mean nightly price is **$276.04** versus median **$176.45**. Use the median as the main 'typical price' measure; flag unusual prices without automatically discarding legitimate luxury listings.
4. **Room type materially affects prices.** The notebook reports median prices of about **$378** for hotel rooms, **$191** for entire homes/apartments, **$106** for private rooms, and **$35** for shared rooms. Compare like with like.
5. **Outliers change means much more than medians.** For entire homes/apartments, excluding IQR-defined high-price outliers reduces mean price from **$297.35 to $217.78** (~26.8%), versus median from **$190.59 to $180.62** (~5.2%). This supports robust reporting with medians and sensitivity checks.
6. **Neighborhood pricing requires sample-size safeguards.** The SQL notes use **at least 20 priced listings** for general neighborhood comparisons, and **at least 15 priced entire-home/apartment listings** for within-room-type neighborhood comparisons. Cherry Creek and Jefferson Park remain relatively expensive within the entire-home segment; avoid asserting location alone causes price differences.
7. **Amenity richness is associated with price, not a causal premium.** The notebook notes a positive relationship even within property-size segments, stronger among two- and three-bedroom entire homes. Amenity quality and property context still matter.
8. **Calendar availability varies by booking horizon.** The notes report **31.26% available listing-days in July 2026**, versus roughly **62–67% in November–December 2026**. These figures reflect calendar status, not confirmed booking or occupancy rates.

## Data integrity and limitations
- Calendar source: **1,806,385 listing-date rows** across **4,949 listing IDs**, each with 365 dates; **10** calendar IDs are absent from the listings snapshot. Calendar windows differ across scrape batches.
- Reviews source: **354,741 review records**; **95** reviews relate to **8** listing IDs outside the current listings snapshot. **638** current listings have no review rows, consistent with zero lifetime reviews.
- The notebook documents **one** listing whose listing-level availability and stay restrictions disagree with calendar records. It was retained and flagged, not silently overwritten.
- One unusually extreme source nightly price (**$110,616.60**) illustrates why robust price segmentation and contextual review are necessary.

## Business interpretation
Pricing benchmarks should prioritize comparable **room type, bedroom count, neighborhood, stay policy and property attributes**. Host scale, review history, amenities and calendar availability can add context, but observed associations do not prove causal effects. The Sheets and Tableau stages should emphasize clear segment-level comparisons and explicitly label estimates and availability limitations.

## Provenance
This is a curated summary of the original notebook's notes, **not** a replacement for its full query history. The companion `02_eda_analysis.sql` preserves selected query bodies but still uses DataLab-specific source references; it should be adapted and tested against the local DuckDB `cleaned_*` views before being described as executable there.
