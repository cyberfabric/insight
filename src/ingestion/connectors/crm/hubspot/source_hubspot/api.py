"""HubSpot REST client and property-discovery helpers.

The ``Hubspot`` class is a thin wrapper around ``requests.Session`` used at
source-construction time for:
- property discovery (``/properties/v2/{entity}/properties``)
- scope validation during ``check_connection``

Streams do their own HTTP via the CDK ``HttpClient`` with
:class:`HubspotErrorHandler`. This keeps a single source of truth for retry
policy across describe-time and sync-time traffic.
"""

import logging
from typing import Any, Dict, Mapping, Optional, Tuple

import requests
from requests import adapters as request_adapters

from airbyte_cdk.models import FailureType
from airbyte_cdk.sources.streams.http import HttpClient
from airbyte_cdk.utils import AirbyteTracedException

from source_hubspot.constants import (
    BASE_URL,
    HUBSPOT_TYPE_TO_JSON_SCHEMA,
)
from source_hubspot.rate_limiting import HubspotErrorHandler


logger = logging.getLogger("airbyte")


class Hubspot:
    """HubSpot REST client used at source-construction time.

    Streams do NOT inherit this — they construct their own HttpClient with
    the appropriate stream name for error handler attribution.
    """

    # HTTP connection pool size. Parallel describes + parallel slice fetches.
    POOL_SIZE = 50

    def __init__(self, access_token: str) -> None:
        if not access_token:
            raise ValueError("access_token is required")
        self.access_token = access_token

        self.session = requests.Session()
        adapter = request_adapters.HTTPAdapter(
            pool_connections=self.POOL_SIZE,
            pool_maxsize=self.POOL_SIZE,
        )
        self.session.mount("https://", adapter)
        self.session.headers.update({"Authorization": f"Bearer {self.access_token}"})

        self._http_client = HttpClient(
            "hubspot_api",
            logger,
            session=self.session,
            error_handler=HubspotErrorHandler("hubspot_api"),
        )

        # Per-entity describe cache: {object_type: (property dict, ...)}.
        # Populated by ``properties_for()`` so ``custom_property_names()`` and
        # schema generation share a single describe call per object.
        self._properties_cache: Dict[str, Tuple[Mapping[str, Any], ...]] = {}

    # ------- Check connection (scope validation) -----------------------------

    def check_connection(self) -> Optional[str]:
        """Verify the token works. Returns None on success, reason string on failure.

        Uses ``/crm/v3/owners/`` with ``limit=1`` because it's cheap, tests a
        CRM scope, and doesn't require any specific object permission. The
        CDK error handler converts 401/403/530 into AirbyteTracedException;
        catch it here so the caller doesn't have to.
        """
        url = f"{BASE_URL}/crm/v3/owners/"
        try:
            _, resp = self._http_client.send_request(
                "GET", url, headers={}, params={"limit": 1}, request_kwargs={}
            )
        except AirbyteTracedException as exc:
            return exc.message or str(exc)
        except Exception as exc:  # noqa: BLE001 — surface any transport error cleanly
            return f"HubSpot connectivity check failed: {exc!r}"
        if resp.ok:
            return None
        return f"HubSpot connectivity check failed: HTTP {resp.status_code} {resp.text[:500]}"

    # ------- Property discovery ---------------------------------------------

    def properties_for(self, object_type: str) -> Tuple[Mapping[str, Any], ...]:
        """Return the list of property descriptors for ``object_type``.

        Cached per-instance in ``self._properties_cache`` so each object is
        described exactly once per sync. Per-instance (not ``@lru_cache`` on
        the method) to avoid retaining ``self`` in a global cache and
        cross-polluting between connector instances.
        """
        cached = self._properties_cache.get(object_type)
        if cached is not None:
            return cached

        # HubSpot v3 properties endpoint — v2 still works but is deprecated.
        url = f"{BASE_URL}/crm/v3/properties/{object_type}"
        _, resp = self._http_client.send_request(
            "GET", url, headers={}, request_kwargs={}
        )
        if not resp.ok:
            raise AirbyteTracedException(
                message=(
                    f"Could not list properties for HubSpot object '{object_type}'. "
                    "The Private App token may be missing the corresponding "
                    "crm.objects.* or crm.schemas.* read scope."
                ),
                internal_message=f"HTTP {resp.status_code}: {resp.text[:500]}",
                failure_type=FailureType.config_error,
            )
        try:
            body = resp.json()
        except ValueError as exc:
            raise AirbyteTracedException(
                message=f"HubSpot properties call for '{object_type}' returned non-JSON response.",
                internal_message=f"body={resp.text[:500]!r}",
                failure_type=FailureType.system_error,
            ) from exc
        # v3 wraps properties in ``{"results": [...]}``; v2 returned a bare
        # list. Handle both so a future endpoint swap is transparent.
        if isinstance(body, Mapping):
            payload = tuple(body.get("results") or ())
        elif isinstance(body, list):
            payload = tuple(body)
        else:
            raise AirbyteTracedException(
                message=f"Unexpected HubSpot properties payload shape for '{object_type}'.",
                internal_message=f"type={type(body).__name__}",
                failure_type=FailureType.system_error,
            )
        self._properties_cache[object_type] = payload
        return payload

    def custom_property_names(self, object_type: str) -> frozenset:
        """Names of properties where ``hubspotDefined`` is False.

        These get routed into the ``custom_fields`` JSON blob by the envelope,
        keeping Bronze schema stable across portals with different customizations.
        """
        props = self.properties_for(object_type)
        return frozenset(
            p["name"]
            for p in props
            if p.get("name") and not p.get("hubspotDefined")
        )

    def property_names(self, object_type: str) -> Tuple[str, ...]:
        """All property names (standard + custom) for ``object_type``.

        Used to build the ``properties`` request body on Search calls so we
        retrieve every field in one round-trip.
        """
        props = self.properties_for(object_type)
        return tuple(p["name"] for p in props if p.get("name"))

    def generate_schema(self, object_type: str) -> Mapping[str, Any]:
        """Build a JSON schema from the property descriptors.

        Standard properties land as ``properties_{name}`` top-level fields.
        Custom properties are NOT advertised per-column — they're packed into
        the ``custom_fields`` JSON blob by the envelope.
        """
        props = self.properties_for(object_type)
        schema: Dict[str, Any] = {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "id": {"type": ["string", "null"]},
                "createdAt": {"type": ["string", "null"], "format": "date-time"},
                "updatedAt": {"type": ["string", "null"], "format": "date-time"},
                "archived": {"type": ["boolean", "null"]},
            },
        }
        warned_unknown: set = set()
        for prop in props:
            name = prop.get("name")
            if not name or not prop.get("hubspotDefined"):
                continue
            schema["properties"][f"properties_{name}"] = _prop_to_json_schema(
                prop, warned_unknown
            )
        return schema


def _prop_to_json_schema(
    prop: Mapping[str, Any], warned_unknown: set
) -> Mapping[str, Any]:
    """Map a HubSpot property descriptor to a JSON-schema property."""
    hs_type = (prop.get("type") or "string").lower()
    mapped = HUBSPOT_TYPE_TO_JSON_SCHEMA.get(hs_type)
    if not mapped:
        if hs_type not in warned_unknown:
            logger.warning(
                "Unknown HubSpot property type %r on %r; falling back to string",
                hs_type,
                prop.get("name"),
            )
            warned_unknown.add(hs_type)
        mapped = ("string", None)
    json_type, fmt = mapped
    out: Dict[str, Any] = {"type": [json_type, "null"]}
    if fmt:
        out["format"] = fmt
    return out
