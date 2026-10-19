# ==========================================
# 1. SETUP
# ==========================================

library(dplyr)
library(ggplot2)
library(readr)

# ==========================================
# 2. IMPORT DATA
# ==========================================

listings <- read_csv("outputs/tables/cleaned_listings.csv")

# ==========================================
# 3. INITIAL DATA EXPLORATION
# ==========================================

head(listings)
dim(listings)
glimpse(listings)
summary(listings)

# ==========================================
# 4. FILTERING AND SELECTING
# ==========================================

comparable_listings <- listings %>%
  filter(
    room_type == "Entire home/apt",
    stay_policy == "Short stay",
    between(bedrooms, 1, 3),
    price_status == "Typical range"
  )

comparable_listings %>%
  select(
    id,
    neighbourhood_cleansed,
    bedrooms,
    amenity_count,
    cleaned_price,
    host_scale
  ) %>%
  head()

nrow(comparable_listings) 

# ==========================================
# 5. Grouping and Summarizing
# ==========================================

bedroom_summary <- comparable_listings %>% 
   group_by(bedrooms) %>%
   summarise(
    listing_count = n(),
    mean_price = mean(cleaned_price, na.rm = TRUE),
    median_price = median(cleaned_price, na.rm = TRUE),
    min_price = min(cleaned_price, na.rm = TRUE),
    max_price = max(cleaned_price, na.rm = TRUE),
    std_price = sd(cleaned_price, na.rm = TRUE)
   ) %>%
   mutate(
    cv_pct = std_price / mean_price * 100,
    price_range = max_price - min_price
   ) %>%
    arrange(desc(median_price))

print(bedroom_summary, width = Inf)

# ==========================================
# 6. Joining Listing and Review Data in R
# ==========================================

reviews <- read_csv("outputs/tables/cleaned_reviews.csv")

review_summary <- reviews %>%
    group_by(listing_id) %>%
    summarise(review_count = n()) 

listings_reviews <- comparable_listings %>%
    left_join(
        review_summary,
        by = c("id" = "listing_id")
    ) %>%
    mutate(
        review_count = coalesce(review_count, 0L)
    )

nrow(listings_reviews)

listings_reviews %>%
    select(id, bedrooms, cleaned_price, review_count) %>%
    head()

n_distinct(listings_reviews$id) == nrow(listings_reviews)

# ==========================================
# 7. Data Visualization with ggplot2
# ==========================================

bedroom_count_median_prices <- ggplot(
    bedroom_summary,
    aes(
        x = factor(bedrooms),
        y = median_price
    )
) + 
    geom_col() + 
    labs(
        title = "Median Nightly Price by Bedroom Count",
        subtitle = "Comparable Denver Airbnbs",
        x = "Bedrooms",
        y = "Median Nightly Price ($)"
    ) + 
    theme_minimal()

ggsave(
  filename = "outputs/charts/r_bedroom_count_median_prices.png",
  plot = bedroom_count_median_prices,
  width = 10,
  height = 6,
  dpi = 300
)

# ==========================================
# 8. Scatter Plot
# ==========================================

amenity_price_scatter_plot <- ggplot(
    comparable_listings,
    aes(
        x = amenity_count,
        y = cleaned_price,
        color = factor(bedrooms)
    )
) + 
    geom_point(alpha = 0.4) +
    labs(
        title = "Relationship Between Number of Amenities and Nightly Price",
        subtitle = "Comparable Denver Airbnbs",
        x = "Number of Amenities",
        y = "Nightly Price ($)",
        color = "Bedrooms"
    ) +
    theme_minimal()

ggsave(
  filename = "outputs/charts/r_amenity_count_price_relationship.png",
  plot = amenity_price_scatter_plot,
  width = 10,
  height = 6,
  dpi = 300
)

# ==========================================
# 9. Violin Plot of Nightly Prices by Host Scale
# ==========================================

host_scale_violin_plot <- ggplot(
  comparable_listings,
  aes(
    x = reorder(host_scale, cleaned_price, FUN = median),
    y = cleaned_price
  )
) +
  geom_violin(fill = "skyblue", alpha = 0.5) +
  geom_boxplot(width = 0.10, fill = "white") +
  coord_flip() +
  labs(
    title = "Nightly Price Distribution by Host Scale",
    subtitle = "Comparable Denver Airbnbs",
    x = "Host Scale",
    y = "Nightly Price ($)"
  ) +
  theme_minimal()

ggsave(
  filename = "outputs/charts/r_host_scale_price_distribution.png",
  plot = host_scale_violin_plot,
  width = 10,
  height = 6,
  dpi = 300
)

# ==========================================
# 10. Faceted Historgrams
# ==========================================

bedroom_price_distribution <- ggplot(
  comparable_listings,
  aes(x = cleaned_price)
) +
  geom_histogram(
    binwidth = 25,
    fill = "steelblue",
    color = "white"
  ) +
  facet_wrap(~ bedrooms, nrow = 1) +
  labs(
    title = "Nightly Price Distributions by Bedroom Count",
    subtitle = "Comparable Denver Airbnbs",
    x = "Nightly Price ($)",
    y = "Number of Listings"
  ) +
  theme_minimal()

ggsave(
  filename = "outputs/charts/r_bedroom_count_price_distributions.png",
  plot = bedroom_price_distribution,
  width = 10,
  height = 6,
  dpi = 300
)

# ==========================================
# 10. Neighborhood Price Variability
# ========================================== 

neighborhood_summary <- comparable_listings %>%
  filter(!is.na(cleaned_price)) %>%
  group_by(neighbourhood_cleansed) %>%
  summarise(
    listing_count = n(),
    median_price = median(cleaned_price, na.rm = TRUE),
    q1 = quantile(cleaned_price, 0.25, na.rm = TRUE),
    q3 = quantile(cleaned_price, 0.75, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(listing_count)) %>%
  slice_head(n = 10)

print(neighborhood_summary, width = Inf)

neighborhood_plot <- ggplot(
  neighborhood_summary,
  aes(
    y = reorder(neighbourhood_cleansed, median_price)
  )
) +
  geom_segment(
    aes(
      x = q1,
      xend = q3,
      yend = reorder(neighbourhood_cleansed, median_price)
    ),
    linewidth = 3,
    color = "skyblue"
  ) +
  geom_point(
    aes(x = median_price),
    size = 3,
    color = "navy"
  ) +
  labs(
    title = "Nightly Price Ranges by Denver Neighborhood",
    subtitle = "Top 10 Neighborhoods by Comparable Listing Count",
    x = "Nightly Price ($)",
    y = "Neighborhood"
  ) +
  theme_minimal()

# Saving Neighborhood Price Ranges Plot
ggsave(
  filename = "outputs/charts/r_neighborhood_price_ranges.png",
  plot = neighborhood_plot,
  width = 10,
  height = 6,
  dpi = 300
)

# Exporting bedroom_summary and neighborhood_summary as a csv
write_csv(
  bedroom_summary,
  "outputs/tables/r_bedroom_summary.csv"
)

write_csv(
  neighborhood_summary,
  "outputs/tables/r_neighborhood_summary.csv"
)

# Verify Exported Files
files <- c(
  "outputs/charts/r_neighborhood_price_ranges.png",
  "outputs/tables/r_bedroom_summary.csv",
  "outputs/tables/r_neighborhood_summary.csv"
)

file.exists(files)

# Host-scale pricing summary
host_summary <- comparable_listings %>%
  group_by(host_scale) %>%
  summarise(
    listing_count = n(),
    mean_price = mean(cleaned_price, na.rm = TRUE),
    median_price = median(cleaned_price, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(median_price))

# Review activity by host scale and bedrooms
host_review_summary <- listings_reviews %>%
  group_by(host_scale, bedrooms) %>%
  summarise(
    listing_count = n(),
    mean_review_count = mean(review_count),
    median_review_count = median(review_count),
    .groups = "drop"
  )

# Export both summaries
write_csv(
  host_summary,
  "outputs/tables/r_host_summary.csv"
)

write_csv(
  host_review_summary,
  "outputs/tables/r_host_review_summary.csv"
)

file.exists(c(
  "outputs/tables/r_host_summary.csv",
  "outputs/tables/r_host_review_summary.csv"
))