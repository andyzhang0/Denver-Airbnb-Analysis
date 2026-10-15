CREATE OR REPLACE VIEW cleaned_listings AS 

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
	
		host_is_superhost, host_listings_count, calculated_host_listings_count, host_identity_verified, hosts_time_as_host_years,
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
FROM raw_listings
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
) -- final cleaned_listings CTE

SELECT *
FROM cleaned_listings;

CREATE OR REPLACE VIEW cleaned_calendar AS 

-- cleaned_calendar
	
SELECT 
    c.listing_id,	
    CAST(c.date AS DATE) AS date,
    c.available,
    c.minimum_nights,
    c.maximum_nights,
    YEAR(c.date) AS year,
    MONTH(c.date) AS month,
    CAST(DATE_TRUNC('month', c.date) AS DATE) AS year_month
FROM raw_calendar AS c
INNER JOIN cleaned_listings AS l
    ON c.listing_id = l.id;


CREATE OR REPLACE VIEW cleaned_reviews AS 

-- cleaned_reviews 

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
FROM raw_reviews AS r
INNER JOIN cleaned_listings AS l
    ON r.listing_id = l.id;