-- Denver Airbnb | Curated SQL EDA
-- Source: exported DataLab notebook; original SQL preserved verbatim.
-- IMPORTANT: Queries reference original DataLab CSV/CTE sources and may require
-- adapting to local DuckDB cleaned_* views before execution.
-- This is an archive of selected final analyses, not a ready-to-run SQL script.


-- =================================================================
-- Notebook cell 107 | Which Denver neighborhoods contain the most Airbnb listings, and what percentage of Denver's total Airbnb inventory does each neighborhood represent?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- Which Denver neighborhoods contain the most Airbnb listings, and what percentage of Denver's total Airbnb inventory does each neighborhood represent?

neighbourhood_listings AS (
	SELECT 
		n.neighbourhood,
		COUNT(l.id) AS listings
	FROM 'neighbourhoods.csv' AS n
	LEFT JOIN cleaned_listings AS l
		ON n.neighbourhood = l.neighbourhood_cleansed
	GROUP BY n.neighbourhood
),

total AS (
	SELECT 
		COUNT(*) AS total_listings
	FROM cleaned_listings
)

SELECT 
	nl.neighbourhood AS "Neighbourhood",
	nl.listings AS "Listings",
	ROUND(nl.listings * 100.0 / t.total_listings, 2) AS "Percent of All Listings",
	ROUND(
		SUM(nl.listings) OVER (ORDER BY nl.listings DESC) * 100.0 
		/ t.total_listings, 
	2) AS "Cumulative Percentage"
FROM neighbourhood_listings AS nl
CROSS JOIN total AS t
ORDER BY nl.listings DESC;


-- =================================================================
-- Notebook cell 109 | How many listings and what percentage of Denver's listings belong to each room_type?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- How many listings and what percentage of Denver's listings belong to each room_type? 
	
room_type_listings AS (
	SELECT 
		room_type,
		COUNT(*) AS listings
	FROM cleaned_listings
	GROUP BY room_type
),
	
total AS (
	SELECT 
		COUNT(*) AS total_listings
	FROM cleaned_listings
)

SELECT 
	r.room_type AS "Room Type",
	r.listings AS "Listings",
	ROUND(r.listings * 100.0 / t.total_listings, 2) AS "Percent of All Listings",
	ROUND(SUM(r.listings) OVER (ORDER BY r.listings DESC) * 100.0 / SUM(r.listings) OVER (), 2) AS "Cumulative Percentage"
FROM room_type_listings AS r
CROSS JOIN total AS t
ORDER BY "Listings" DESC;


-- =================================================================
-- Notebook cell 97 | What does the overall distribution of nightly listing prices look like in Denver, and how strongly is it affected by extreme values?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- What does the overall distribution of nightly listing prices look like in Denver, and how strongly is it affected by extreme values?

SELECT 
	id, name, neighbourhood_cleansed, property_type, room_type, accommodates, bedrooms, bathrooms, minimum_nights, cleaned_price, estimated_occupancy_l365d, estimated_revenue_l365d
FROM cleaned_listings
WHERE cleaned_price > 2000
ORDER BY cleaned_price DESC;


-- =================================================================
-- Notebook cell 92 | How do nightly prices differ by room type?
-- How sensitive are room-type price estimates to high-price outliers?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- How do nightly prices differ by room type?
-- How sensitive are room-type price estimates to high-price outliers?

SELECT 
	room_type,
	ROUND(AVG(cleaned_price), 2) AS full_data_mean,
	ROUND(AVG(CASE WHEN price_status != 'High price outlier' THEN cleaned_price END), 2) AS typical_range_mean,
	ROUND(AVG(cleaned_price) - AVG(CASE WHEN price_status != 'High price outlier' THEN cleaned_price END), 2) AS change_in_mean,
	ROUND(
		(
		AVG(cleaned_price) 
		- AVG(CASE WHEN price_status != 'High price outlier' THEN cleaned_price END) 
		)
		* 100.0 / AVG(cleaned_price), 
		2) AS pct_change_in_mean,
	MEDIAN(cleaned_price) AS full_data_median,
	MEDIAN(CASE WHEN price_status != 'High price outlier' THEN cleaned_price END) AS typical_range_median
FROM cleaned_listings
WHERE cleaned_price IS NOT NULL 
GROUP BY room_type
ORDER BY room_type;


-- =================================================================
-- Notebook cell 89 | Which Denver neighborhoods are the most and least expensive based on median nightly price?  
-- How many neighborhoods and priced listings would remain if we required at least 5, 10, 20, 30, and 50 priced listings per neighborhood?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- Which Denver neighborhoods are the most and least expensive based on median nightly price?

neighbourhood_pricing AS (
	SELECT
		neighbourhood_cleansed,
		COUNT(*) AS priced_listings,
		MEDIAN(cleaned_price) AS median_price,
		ROUND(AVG(cleaned_price), 2) AS avg_price,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1_price,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3_price
	FROM cleaned_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY neighbourhood_cleansed
),
	
-- How many neighborhoods and priced listings would remain if we required at least 5, 10, 20, 30, and 50 priced listings per neighborhood?

thresholds AS (
	SELECT *
	FROM (VALUES
		(5),
		(10),
		(20),
		(30),
		(50)
	) AS t(minimum_priced_listings)
),

neighbourhood_pricing_thresholds AS (
	SELECT 
		t.minimum_priced_listings,
		COUNT(n.neighbourhood_cleansed) AS neighbourhoods_retained,
		SUM(n.priced_listings) AS priced_listings_retained
	FROM neighbourhood_pricing AS n
	INNER JOIN thresholds as t 
		ON n.priced_listings >= t.minimum_priced_listings
	GROUP BY t.minimum_priced_listings
),

total_priced_listings AS (
	SELECT 
		COUNT(*) AS total_priced_listings
	FROM cleaned_listings
	WHERE cleaned_price IS NOT NULL
)

SELECT n.*,
	ROUND(n.priced_listings_retained * 100.0 / t.total_priced_listings, 2) AS percent_of_priced_listings_retained
FROM neighbourhood_pricing_thresholds AS n
CROSS JOIN total_priced_listings AS t
ORDER BY n.minimum_priced_listings;


-- =================================================================
-- Notebook cell 86 | Do neighborhood price differences persist when we compare the same room type? 
-- Among neighborhoods with sufficient Entire home/apt inventory, which neighborhoods have the highest and lowest median nightly prices for Entire homes/apartments?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- Do neighborhood price differences persist when we compare the same room type?
-- Among neighborhoods with sufficient Entire home/apt inventory, which neighborhoods have the highest and lowest median nightly prices for Entire homes/apartments?

neighbourhood_pricing_entirehomeapt AS (
	SELECT 
		neighbourhood_cleansed,
		COUNT(*) AS priced_listings,
		MEDIAN(cleaned_price) AS median_price
	FROM cleaned_listings 
	WHERE cleaned_price IS NOT NULL AND room_type = 'Entire home/apt'
	GROUP BY neighbourhood_cleansed
),

threshold AS (
	SELECT *
	FROM (VALUES
		(5), (10), (15), (20), (25), (30), (50)
	) AS t(minimum_priced_listings)
),

neighbourhood_pricing_entirehomeapt_thresholds AS (
	SELECT 
		t.minimum_priced_listings,
		COUNT(neighbourhood_cleansed) AS neighbourhoods_retained,
		SUM(priced_listings) AS priced_listings_retained
	FROM neighbourhood_pricing_entirehomeapt AS n
	INNER JOIN threshold AS t ON n.priced_listings >= t.minimum_priced_listings
	GROUP BY t.minimum_priced_listings
),

total_entirehomeapt_listings AS (
	SELECT 
		COUNT(*) AS total_entirehomeapt_listings
	FROM cleaned_listings 
	WHERE cleaned_price IS NOT NULL AND room_type = 'Entire home/apt'
)

SELECT n.*,
	ROUND(n.priced_listings_retained * 100.0 / t.total_entirehomeapt_listings, 2) AS percent_of_listings_retained
FROM neighbourhood_pricing_entirehomeapt_thresholds AS n
CROSS JOIN total_entirehomeapt_listings AS t
ORDER BY n.minimum_priced_listings;


-- =================================================================
-- Notebook cell 79 | Within Entire home/apt listings, how does capacity/property size affect price? 
-- Among similarly sized Entire homes/apartments, which Denver neighborhoods command higher or lower nightly prices?
-- For 1-, 2-, and 3-bedroom Entire home/apts, how far above or below the Denver-wide median for the same bedroom count is each qualifying neighborhood's median price?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- Within Entire home/apt listings, how does capacity/property size affect price? 
-- Among similarly sized Entire homes/apartments, which Denver neighborhoods command higher or lower nightly prices?
-- For 1-, 2-, and 3-bedroom Entire home/apts, how far above or below the Denver-wide median for the same bedroom count is each qualifying neighborhood's median price?

neighbourhood_bedroom_prices AS (
	SELECT 
		neighbourhood_cleansed,
		bedrooms,
		COUNT(*) AS priced_listings,
		MEDIAN(cleaned_price) AS median_price
	FROM cleaned_listings
	WHERE room_type = 'Entire home/apt' AND cleaned_price IS NOT NULL AND bedrooms IS NOT NULL AND bedrooms <= 3
	GROUP BY neighbourhood_cleansed, bedrooms
	HAVING COUNT(*) >= 5
),

median_prices AS (
	SELECT 
		bedrooms,
		MEDIAN(cleaned_price) AS entirehomeapt_bedrooms_median_price
	FROM cleaned_listings
	WHERE room_type = 'Entire home/apt' AND cleaned_price IS NOT NULL AND bedrooms IS NOT NULL AND bedrooms <= 3
	GROUP BY bedrooms
),
	
neighbourhood_bedroom_prices_rank AS (
	SELECT n.*, 
		m.entirehomeapt_bedrooms_median_price,
		ROUND((n.median_price - m.entirehomeapt_bedrooms_median_price) * 100.0 / m.entirehomeapt_bedrooms_median_price, 2) AS median_percent_change,
		ROW_NUMBER() OVER (
			PARTITION BY n.bedrooms
			ORDER BY n.median_price DESC
		) AS bedroom_median_price_high_rank,
		ROW_NUMBER() OVER (
			PARTITION BY n.bedrooms
			ORDER BY n.median_price
		) AS bedroom_median_price_low_rank
	FROM neighbourhood_bedroom_prices AS n
	INNER JOIN median_prices AS m
		ON n.bedrooms = m.bedrooms
)

SELECT *,
	CASE 
		WHEN bedroom_median_price_high_rank <= 5 THEN 'Top 5 Premium'
		WHEN bedroom_median_price_low_rank <= 5 THEN 'Top 5 Discount'
		WHEN median_percent_change > 0 THEN 'Premium'
		WHEN median_percent_change < 0 THEN 'Discount'
	END AS price_position
FROM neighbourhood_bedroom_prices_rank 
WHERE bedroom_median_price_high_rank <= 5 OR bedroom_median_price_low_rank <= 5
ORDER BY bedrooms DESC, median_price DESC;


-- =================================================================
-- Notebook cell 77 | How does host scale relate to nightly price? Do large/professional operators charge systematically different prices than single-listing and smaller hosts?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- How does host scale relate to nightly price? Do large/professional operators charge systematically different prices than single-listing and smaller hosts?

host_scale_prices AS (
	SELECT
		host_scale,
		COUNT(DISTINCT host_id) AS distinct_hosts,
		COUNT(*) AS listings,
		MEDIAN(cleaned_price) AS median_price
	FROM cleaned_listings
	WHERE cleaned_price IS NOT NULL 
	GROUP BY host_scale
),

overall_median AS (
	SELECT 
		MEDIAN(cleaned_price) AS overall_median
	FROM cleaned_listings
	WHERE cleaned_price IS NOT NULL 
)

SELECT *,
	ROUND((h.median_price - m.overall_median) * 100.0 / m.overall_median, 2) AS median_percent_change
FROM host_scale_prices AS h
CROSS JOIN overall_median AS m
ORDER BY listings DESC;


-- =================================================================
-- Notebook cell 74 | -- How does host scale relate to nightly price? Do large/professional operators charge systematically different prices than single-listing and smaller hosts?
-- Among Entire home/apt listings with the same bedroom count, how does median price vary by host scale? 
-- Within the same neighborhood and bedroom count, do single-listing hosts generally have higher median prices than multi-listing hosts?
-- After controlling for neighborhood and bedroom count, do Single-listing hosts price differently from Large/professional operators?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- How does host scale relate to nightly price? Do large/professional operators charge systematically different prices than single-listing and smaller hosts?
-- Among Entire home/apt listings with the same bedroom count, how does median price vary by host scale?
-- Within the same neighborhood and bedroom count, do single-listing hosts generally have higher median prices than multi-listing hosts?
-- After controlling for neighborhood and bedroom count, do Single-listing hosts price differently from Large/professional operators?

host_scale_prices AS (
	SELECT
		neighbourhood_cleansed,
		bedrooms,
		host_scale,
		COUNT(DISTINCT host_id) AS distinct_hosts,
		COUNT(*) AS listings,
		MEDIAN(cleaned_price) AS median_price
	FROM cleaned_listings
	WHERE cleaned_price IS NOT NULL 
		AND room_type = 'Entire home/apt'
		AND bedrooms IS NOT NULL AND bedrooms <= 3 
		AND host_scale IN ('Single-listing host', 'Large/professional operator')
	GROUP BY neighbourhood_cleansed, bedrooms, host_scale
),

host_scale_comparison AS (
	SELECT 
		neighbourhood_cleansed,
		bedrooms,
		SUM(CASE WHEN host_scale = 'Single-listing host' THEN listings ELSE 0 END) AS single_listings,
		SUM(CASE WHEN host_scale = 'Large/professional operator' THEN listings ELSE 0 END) AS professional_listings
	FROM host_scale_prices
	GROUP BY neighbourhood_cleansed, bedrooms
),

thresholds AS (
	SELECT *
	FROM (VALUES
		(1),
		(2),
		(3),
		(5),
		(10),
		(15)
	) AS t(minimum_priced_listings)
),

total_listings AS (
	SELECT 
		COUNT(*) AS total_listings
	FROM cleaned_listings
	WHERE cleaned_price IS NOT NULL 
		AND room_type = 'Entire home/apt'
		AND bedrooms IS NOT NULL AND bedrooms <= 3 
		AND host_scale IN ('Single-listing host', 'Large/professional operator')
)

SELECT 
	t.minimum_priced_listings,
	COUNT(*) AS groups_retained,
	SUM(h.single_listings + h.professional_listings) AS listings_retained,
	ROUND(SUM(h.single_listings + h.professional_listings) * 100.0 / l.total_listings, 2) AS percent_of_listings_retained
FROM host_scale_comparison AS h
INNER JOIN thresholds AS t 
	ON h.single_listings >= t.minimum_priced_listings
	AND h.professional_listings >= t.minimum_priced_listings
CROSS JOIN total_listings AS l
GROUP BY t.minimum_priced_listings, l.total_listings, 
ORDER BY t.minimum_priced_listings;


-- =================================================================
-- Notebook cell 63 | Are amenity-rich listings associated with higher prices, and are there particular amenities associated with price premiums?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
),

-- Are amenity-rich listings associated with higher prices, and are there particular amenities associated with price premiums?

amenity_unnest AS (
    SELECT
        id,
        UNNEST(
            FROM_JSON(amenities, '["VARCHAR"]')
        ) AS amenity
    FROM cleaned_listings
),

has_amenity AS (
	SELECT 
		id,
		MAX(CASE 
			WHEN LOWER(amenity) LIKE '%pool%' AND LOWER(amenity) NOT LIKE '%pool table%' AND LOWER(amenity) NOT LIKE '%pool view%' AND LOWER(amenity) NOT LIKE '%whirlpool%' THEN 1
			ELSE 0
		END) AS has_pool
	FROM amenity_unnest
	GROUP BY id
),

has_amenity_pivot AS (
SELECT 
	l.bedrooms,
	SUM(CASE WHEN a.has_pool = 1 THEN 1 ELSE 0 END) AS pool_listings,
	MEDIAN(CASE WHEN a.has_pool = 1 THEN l.cleaned_price END) AS pool_median_price,
	SUM(CASE WHEN a.has_pool = 0 THEN 1 ELSE 0 END) AS no_pool_listings,
	MEDIAN(CASE WHEN a.has_pool = 0 THEN l.cleaned_price END) AS no_pool_median_price
FROM cleaned_listings AS l
INNER JOIN has_amenity AS a
	ON l.id = a.id
WHERE l.bedrooms <= 3 AND l.room_type = 'Entire home/apt' AND l.cleaned_price IS NOT NULL
GROUP BY l.bedrooms
)

SELECT *,
	ROUND((pool_median_price - no_pool_median_price) * 100.0 / no_pool_median_price, 2) AS pct_pool_premium
FROM has_amenity_pivot
ORDER BY bedrooms;


-- =================================================================
-- Notebook cell 56 | Among comparable short-stay entire homes/apartments, which Denver neighborhoods have the highest and lowest estimated occupancy?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- Among comparable short-stay entire homes/apartments, which Denver neighborhoods have the highest and lowest estimated occupancy?

SELECT 
	neighbourhood_cleansed,
	bedrooms,
	COUNT(*) AS listings,
	SUM(COUNT(*)) OVER (PARTITION BY neighbourhood_cleansed) AS total_comparable_neighbourhood_listings,
 	MEDIAN(estimated_occupancy_l365d) AS median_estimated_occupancy,
	ROUND(AVG(estimated_occupancy_l365d), 2) AS avg_estimated_occupancy,
	SUM(CASE WHEN estimated_occupancy_l365d = 0 THEN 1 ELSE 0 END) AS zero_estimated_occupancy_listings,
	ROUND(SUM(CASE WHEN estimated_occupancy_l365d = 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS pct_zero_occupancy
FROM cleaned_listings 
WHERE room_type = 'Entire home/apt'
  AND stay_policy = 'Short stay'
  AND bedrooms BETWEEN 1 AND 3
GROUP BY neighbourhood_cleansed, bedrooms
HAVING COUNT(*) >= 20
ORDER BY bedrooms, avg_estimated_occ;


-- =================================================================
-- Notebook cell 54 | How does nightly price relate to estimated occupancy?
-- Within comparable short-stay entire homes/apartments of the same bedroom size, how does nightly price vary across estimated occupancy levels?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- How does nightly price relate to estimated occupancy?
-- Within comparable short-stay entire homes/apartments of the same bedroom size, how does nightly price vary across estimated occupancy levels?

SELECT 
	CASE 
		WHEN estimated_occupancy_l365d = 0 THEN '0 Days'
		WHEN estimated_occupancy_l365d <= 50 THEN '1-50 Days'
		WHEN estimated_occupancy_l365d <= 100 THEN '51-100 Days'
		WHEN estimated_occupancy_l365d <= 150 THEN '101-150 Days'
		WHEN estimated_occupancy_l365d <= 200 THEN '151-200 Days'
		ELSE 'Over 200 Days'
	END AS estimated_occupancy_category,
	bedrooms,
	COUNT(*) AS listings,
	MEDIAN(cleaned_price) AS median_price
FROM cleaned_listings
WHERE cleaned_price IS NOT NULL AND room_type = 'Entire home/apt' AND stay_policy = 'Short stay' AND bedrooms BETWEEN 1 AND 3
GROUP by estimated_occupancy_category, bedrooms
ORDER BY estimated_occupancy_category, bedrooms;


-- =================================================================
-- Notebook cell 52 | Do Superhosts achieve higher estimated occupancy than non-Superhosts for comparable listings?
-- Within comparable 1–3 bedroom short-stay entire homes/apartments, how does estimated occupancy differ between Superhosts and non-Superhosts?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- Do Superhosts achieve higher estimated occupancy than non-Superhosts for comparable listings?
-- Within comparable 1–3 bedroom short-stay entire homes/apartments, how does estimated occupancy differ between Superhosts and non-Superhosts?

SELECT 
	host_is_superhost,
	bedrooms,
	COUNT(*) AS listings,
	MEDIAN(estimated_occupancy_l365d) AS median_estimated_occupancy,
	ROUND(AVG(estimated_occupancy_l365d), 2) AS avg_estimated_occupancy,
	SUM(CASE WHEN estimated_occupancy_l365d = 0 THEN 1 ELSE 0 END) AS zero_occupancy_listings,
	ROUND(SUM(CASE WHEN estimated_occupancy_l365d = 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS zero_occupancy_percentage
FROM cleaned_listings
WHERE room_type = 'Entire home/apt' AND stay_policy = 'Short stay' AND bedrooms BETWEEN 1 AND 3
GROUP BY host_is_superhost, bedrooms
ORDER BY host_is_superhost, bedrooms;


-- =================================================================
-- Notebook cell 48 | How does host scale relate to estimated occupancy among comparable short-stay entire homes/apartments?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- How does host scale relate to estimated occupancy among comparable short-stay entire homes/apartments?

SELECT 
	host_scale,
	COUNT(*) AS listings,
	MEDIAN(estimated_occupancy_l365d) AS median_estimated_occupancy,
	ROUND(AVG(estimated_occupancy_l365d), 2) AS avg_estimated_occupancy,
	SUM(CASE
    WHEN estimated_occupancy_l365d = 0 THEN 1
    ELSE 0
	END) AS zero_occupancy_listings,
	ROUND(
    	SUM(CASE
       		WHEN estimated_occupancy_l365d = 0 THEN 1
        	ELSE 0
    	END) * 100.0 / COUNT(*),
    2) AS pct_zero_occupancy
FROM cleaned_listings
WHERE room_type = 'Entire home/apt' AND stay_policy = 'Short stay' AND bedrooms BETWEEN 1 AND 3
GROUP BY host_scale
ORDER BY median_estimated_occupancy DESC;


-- =================================================================
-- Notebook cell 31 
-- Which combinations of neighborhood/bedroom count appear to offer the strongest balance of median estimated revenue and median estimated occupancy among comparable short-stay entire homes/apartments?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Speciality/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- Which combinations of neighborhood/bedroom count appear to offer the strongest balance of median estimated revenue and median estimated occupancy among comparable short-stay entire homes/apartments?

SELECT 
	neighbourhood_cleansed,
	bedrooms,
	COUNT(*) AS listings,
	MEDIAN(cleaned_price) AS median_price,
	MEDIAN(estimated_occupancy_l365d) AS median_estimated_occupancy,
	MEDIAN(estimated_revenue_l365d) AS median_estimated_revenue
FROM cleaned_listings
WHERE estimated_revenue_l365d IS NOT NULL AND cleaned_price IS NOT NULL 
	AND room_type = 'Entire home/apt' AND stay_policy = 'Short stay' AND bedrooms BETWEEN 1 AND 3
GROUP BY neighbourhood_cleansed, bedrooms
HAVING COUNT(*) >= 20
ORDER BY bedrooms, median_estimated_revenue DESC;


-- =================================================================
-- Notebook cell 20 | How does the percentage of available Airbnb listing-days vary by month in Denver?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Specialty/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- How does the percentage of available Airbnb listing-days vary by month in Denver?

SELECT 
	year_month,
	COUNT(*) AS listing_days,
	SUM(CASE WHEN available IS TRUE THEN 1 ELSE 0 END) AS available_listing_days,
	SUM(CASE WHEN available IS FALSE THEN 1 ELSE 0 END) AS unavailable_listing_days,
	ROUND(SUM(CASE WHEN available IS TRUE THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS pct_of_listing_days_available
FROM cleaned_calendar
WHERE available IS NOT NULL AND date IS NOT NULL
GROUP BY year_month
ORDER BY year_month;


-- =================================================================
-- Notebook cell 16 | Which Denver neighborhoods have the highest and lowest future calendar availability among comparable short-stay entire homes/apartments?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Specialty/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month,
		l.neighbourhood_cleansed,
		l.room_type,
		l.bedrooms,
		l.stay_policy
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- Which Denver neighborhoods have the highest and lowest future calendar availability among comparable short-stay entire homes/apartments?

SELECT 
	neighbourhood_cleansed,
	COUNT(DISTINCT listing_id) AS listings,
	COUNT(*) AS listing_days,
	SUM(CASE WHEN available IS TRUE THEN 1 ELSE 0 END) AS available_listing_days,
	SUM(CASE WHEN available IS FALSE THEN 1 ELSE 0 END) AS unavailable_listing_days,
	ROUND(SUM(CASE WHEN available IS TRUE THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS pct_of_listing_days_available
FROM cleaned_calendar
WHERE year_month >= DATE '2026-07-01'
	AND year_month < DATE '2027-07-01'
	AND available IS NOT NULL
	AND date IS NOT NULL 
	AND room_type = 'Entire home/apt' AND stay_policy = 'Short stay' AND bedrooms BETWEEN 1 AND 3
GROUP BY neighbourhood_cleansed
HAVING COUNT(DISTINCT listing_id) >= 20
ORDER BY pct_of_listing_days_available DESC;


-- =================================================================
-- Notebook cell 14 | How does monthly review activity change over time in Denver, and are there noticeable seasonal patterns?
-- =================================================================
WITH base_listings AS (
	SELECT 
		id, last_scraped, source, name,
	
		host_id, host_name, host_location, 
		CASE 
			WHEN host_location IS NULL THEN 'No Location'
			WHEN LOWER(host_location) LIKE '%denver%' THEN 'Denver'
			WHEN TRIM(LOWER(host_location)) LIKE '%, co' OR LOWER(host_location) LIKE '%colorado%' THEN 'Other Colorado'
			WHEN TRIM(LOWER(host_location)) LIKE '%, __' OR LOWER(host_location) LIKE '%united states%' THEN 'Other US State'
			ELSE 'Other Country'
		END AS host_location_category, -- broader category for host_location 
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified,
		CASE
			WHEN calculated_host_listings_count = 1 THEN 'Single-listing host'
			WHEN calculated_host_listings_count BETWEEN 2 AND 4 THEN 'Small multi-listing host'
			WHEN calculated_host_listings_count BETWEEN 5 AND 9 THEN 'Medium operator'
			WHEN calculated_host_listings_count >= 10 THEN 'Large/professional operator'
		END AS host_scale, -- category column for calculated_host_listings_count ranges
	
		neighbourhood_cleansed, latitude, longitude,
	
		property_type, 
		CASE 
			WHEN property_type = 'Tiny home' THEN 'Specialty/Other'
			WHEN LOWER(property_type) LIKE '%home%' OR LOWER(property_type) LIKE '%bungalow%' OR LOWER(property_type) LIKE '%cottage%' THEN 'House/Home'
			WHEN LOWER(property_type) LIKE '%apartment%' OR LOWER(property_type) LIKE '%rental unit%' OR LOWER(property_type) LIKE '%loft%' THEN 'Apartment/Rental Unit'
			WHEN LOWER(property_type) LIKE '%condo%' THEN 'Condo'
			WHEN LOWER(property_type) LIKE '%townhouse%' THEN 'Townhouse'
			WHEN LOWER(property_type) LIKE '%guest%' THEN 'Guesthouse'
			WHEN LOWER(property_type) LIKE '%hotel%' OR LOWER(property_type) LIKE '%hostel%' OR LOWER(property_type) LIKE '%bed and breakfast%' THEN 'Hotel/Hospitality'
			WHEN LOWER(property_type) LIKE '%villa%' THEN 'Villa'
			ELSE 'Specialty/Other'
		END AS property_category, -- broader category for property_type
	
		room_type, accommodates, bedrooms, beds, amenities,
		 LEN(
			FROM_JSON(amenities, '["VARCHAR"]')
    	) AS amenity_count, -- converting amenities column to a list of VARCHAR values and counting amenities in the list for each listing

		bathrooms, bathrooms_text, 
		CASE 
			WHEN LOWER(bathrooms_text) LIKE '%private%' THEN 'Private'
			WHEN LOWER(bathrooms_text) LIKE '%shared%' THEN 'Shared'
			WHEN bathrooms_text IS NOT NULL THEN 'Standard'
			ELSE NULL
		END AS bathroom_type, -- categorizing the type of bathroom from bathrooms_text
	
		price,
		TRY_CAST(
            REPLACE(
                REPLACE(price, '$', ''),
                ',', ''
            ) AS DECIMAL(10,2)
        ) AS cleaned_price, -- converting VARCHAR price values to a usable numeric data type for calculations 
	
		minimum_nights, maximum_nights, has_availability, availability_30, availability_60, availability_90, availability_365, availability_eoy, estimated_occupancy_l365d,  estimated_revenue_l365d,
		CASE 
			WHEN minimum_nights <= 6 THEN 'Short stay'
			WHEN minimum_nights <= 27 THEN 'Medium Stay'
			WHEN minimum_nights <= 45 THEN 'Monthly stay'
			WHEN minimum_nights >= 46 THEN 'Extended stay'
		ELSE NULL
		END AS stay_policy, -- category column for minimum_nights ranges 
	
		first_review, last_review, number_of_reviews, number_of_reviews_ltm, number_of_reviews_l30d, number_of_reviews_ly,
		CASE 
			WHEN number_of_reviews_l30d >= 1 THEN 'Recently Reviewed'
			WHEN number_of_reviews_ltm >= 1 THEN 'Reviewed in Last Year'
			WHEN number_of_reviews >= 1 THEN 'Historically Reviewed'
			WHEN number_of_reviews = 0 THEN 'Never Reviewed'
		END AS listing_activity_status, -- category column for number_of_reviews_... fields
	
		review_scores_rating, review_scores_accuracy, review_scores_communication, review_scores_location, review_scores_value, reviews_per_month
FROM 'detailed_listings.csv'
),
	
room_type_price_quartiles AS (
	SELECT 
		room_type,
		QUANTILE_CONT(cleaned_price, 0.25) AS q1,
		QUANTILE_CONT(cleaned_price, 0.75) AS q3,
		QUANTILE_CONT(cleaned_price, 0.75) - QUANTILE_CONT(cleaned_price, 0.25) AS iqr
	FROM base_listings
	WHERE cleaned_price IS NOT NULL
	GROUP BY room_type
), -- intermediate CTE to calculate respective q1, q3, and iqr for each room_type

room_type_price_stats AS (
	SELECT 
		room_type,
		q1,
		q3,
		iqr,
		q1 - (1.5 * iqr) AS lower_bound,
		q3 + (1.5 * iqr) AS upper_bound
	FROM room_type_price_quartiles
), -- intermediate CTE to consolidate quartile values and calculated lower and upper bounds for each room_type

cleaned_listings AS (
	SELECT 
		b.*,
		CASE 
			WHEN b.cleaned_price IS NULL THEN 'Missing price'
			WHEN b.cleaned_price < p.lower_bound THEN 'Low price outlier'
			WHEN b.cleaned_price > p.upper_bound THEN 'High price outlier'
			ELSE 'Typical range' 
		END AS price_status -- category column for price, based on respective calculations for each room_type
	FROM base_listings AS b
	LEFT JOIN room_type_price_stats AS p
		ON b.room_type = p.room_type
), -- final cleaned_listings CTE

-- cleaned_calendar
	
cleaned_calendar AS (
	SELECT 
		c.listing_id,	
		CAST(c.date AS DATE) AS date,
		c.available,
		c.minimum_nights,
		c.maximum_nights,
		YEAR(c.date) AS year,
		MONTH(c.date) AS month,
		CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
	FROM 'detailed_calendar.csv' AS c
	INNER JOIN cleaned_listings AS l
		ON c.listing_id = l.id
),

-- cleaned_reviews 

cleaned_reviews AS (
	SELECT 
		r.listing_id,
		r.id AS review_id,
		CAST(r.date AS DATE) AS date,
		r.reviewer_id,
		r.reviewer_name,
		r.comments,
		YEAR(r.date) AS year,
		MONTH(r.date) AS month,
		CAST(DATE_TRUNC('month', r.date) AS DATE) AS year_month
	FROM 'detailed_reviews.csv' AS r
	INNER JOIN cleaned_listings AS l
		ON r.listing_id = l.id
)

-- How does monthly review activity change over time in Denver, and are there noticeable seasonal patterns?

SELECT 
	year_month,
	year,
	month,
	COUNT(*) AS reviews,
	COUNT(DISTINCT listing_id) AS reviewed_listings,
	ROUND(COUNT(*) * 1.0 / COUNT(DISTINCT listing_id), 2) AS avg_reviews_per_reviewed_listing
FROM cleaned_reviews
WHERE review_id IS NOT NULL AND listing_id IS NOT NULL AND year_month IS NOT NULL AND year BETWEEN 2023 AND 2025
GROUP BY year_month, year, month
ORDER BY month, year;
