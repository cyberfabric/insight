"""HubSpot stream registry, property-type mapping, and API limits."""

from typing import Mapping

# ------- API -----------------------------------------------------------------

BASE_URL = "https://api.hubapi.com"

# ------- Search endpoint caps ------------------------------------------------

# HubSpot Search returns HTTP 400 once `after >= SEARCH_AFTER_HARD_CAP`.
# Hit this, switch to keyset pagination within the same time slice.
SEARCH_AFTER_HARD_CAP = 10_000

# Search endpoint: 100 records per page is the maximum the API accepts.
SEARCH_PAGE_LIMIT = 100

# v3 list endpoints: 100 records per page (same cap as search).
LIST_PAGE_LIMIT = 100

# v4 associations batch_read accepts up to 1000 ids per call, but 100 keeps
# request bodies small enough that a 429 retry doesn't replay a big payload.
ASSOCIATIONS_BATCH_SIZE = 100

# ------- Property-type mapping (describe -> JSON schema) ---------------------

# HubSpot property type -> (json-schema type, optional format).
# Any type not listed falls back to string with a one-time warning.
HUBSPOT_TYPE_TO_JSON_SCHEMA: Mapping[str, tuple] = {
    "string": ("string", None),
    "bool": ("boolean", None),
    "boolean": ("boolean", None),
    "enumeration": ("string", None),
    "date": ("string", "date"),
    "datetime": ("string", "date-time"),
    "date-time": ("string", "date-time"),
    "number": ("number", None),
    "json": ("string", None),
    "object_coordinates": ("string", None),
    "phone_number": ("string", None),
}

# ------- Cloudflare oddity ---------------------------------------------------

# HubSpot fronts the API via Cloudflare; an invalid token format (e.g. wrong
# prefix) bubbles up as a 530, not a proper 401. Map it to a config error with
# a token-format hint.
CLOUDFLARE_ORIGIN_DNS_ERROR = 530

# ------- Curated stream registry ---------------------------------------------

# ``object_type`` is the path segment used with /crm/v3/objects/{object_type}
# and /crm/v3/objects/{object_type}/search. ``primary_key`` is always "id".
# ``associations`` lists object types to co-fetch via v4 batch_read.
#
# Operator can override the active set via config.hubspot_streams.
STREAM_REGISTRY: Mapping[str, Mapping] = {
    "contacts": {
        "object_type": "contacts",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["companies", "deals"],
        "silver_tag": "silver:class_crm_contacts",
    },
    "companies": {
        "object_type": "companies",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": [],
        "silver_tag": "silver:class_crm_accounts",
    },
    "deals": {
        "object_type": "deals",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["companies", "contacts"],
        "silver_tag": "silver:class_crm_deals",
    },
    "engagements_calls": {
        "object_type": "calls",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["contacts", "companies", "deals"],
        "silver_tag": "silver:class_crm_activities",
    },
    "engagements_emails": {
        "object_type": "emails",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["contacts", "companies", "deals"],
        "silver_tag": "silver:class_crm_activities",
    },
    "engagements_meetings": {
        "object_type": "meetings",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["contacts", "companies", "deals"],
        "silver_tag": "silver:class_crm_activities",
    },
    "engagements_tasks": {
        "object_type": "tasks",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["contacts", "companies", "deals"],
        "silver_tag": "silver:class_crm_activities",
    },
    "leads": {
        "object_type": "leads",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["contacts", "companies"],
        "silver_tag": None,  # bronze-only in v1
    },
    "tickets": {
        "object_type": "tickets",
        "cursor_field": "updatedAt",
        "search_cursor_property": "hs_lastmodifieddate",
        "associations": ["contacts", "companies", "deals"],
        "silver_tag": None,  # bronze-only in v1
    },
    # owners is NOT a CRM object — different endpoint shape (/crm/v3/owners).
    # Handled by a dedicated stream class; no search endpoint, no properties.
    # cursor_field=None forces FinalStateCursor (full-refresh). The owners
    # list endpoint doesn't accept an updatedAt filter, so time-slicing via
    # ConcurrentCursor would just re-read the full owner set per slice.
    "owners": {
        "object_type": "owners",
        "cursor_field": None,
        "search_cursor_property": None,
        "associations": [],
        "silver_tag": "silver:class_crm_users",
    },
}

# Curated default list — matches the streams listed in the plan.
CURATED_STREAMS = list(STREAM_REGISTRY.keys())
