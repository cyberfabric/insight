"""HubSpot stream classes.

Two stream shapes:
- ``CrmSearchStream`` — incremental via /crm/v3/objects/{type}/search; covers
  contacts, companies, deals, engagements, leads, tickets. Implements the
  10k search-result cap workaround (inner keyset pagination on ``hs_object_id``
  once ``after`` hits the cap inside a time slice). A per-slice
  ``archived=true`` complement is fetched via the v3 list endpoint because
  search does not return archived records.
- ``OwnersStream`` — /crm/v3/owners/ page-cursor listing; no property
  discovery, no search endpoint, no associations.

All streams apply the Insight envelope via :func:`envelope.envelope` before
yielding to Bronze.
"""

from __future__ import annotations

import copy
import logging
from abc import ABC, abstractmethod
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import pendulum
import requests

from airbyte_cdk.models import SyncMode
from airbyte_cdk.sources.streams.concurrent.cursor import ConcurrentCursor
from airbyte_cdk.sources.streams.concurrent.state_converters.datetime_stream_state_converter import (
    IsoMillisConcurrentStreamStateConverter,
)
from airbyte_cdk.sources.streams.core import Stream, StreamData
from airbyte_cdk.sources.streams.http import HttpClient

from source_hubspot.api import Hubspot
from source_hubspot.associations import AssociationFetcher
from source_hubspot.constants import (
    BASE_URL,
    LIST_PAGE_LIMIT,
    SEARCH_AFTER_HARD_CAP,
    SEARCH_PAGE_LIMIT,
    STREAM_REGISTRY,
)
from source_hubspot.envelope import envelope, inject_envelope_properties
from source_hubspot.rate_limiting import HubspotErrorHandler


logger = logging.getLogger("airbyte")


class HubspotStream(Stream, ABC):
    """Base class: envelope injection, shared HttpClient wiring, schema.

    Concrete subclasses implement :meth:`_generate_records` to yield raw
    HubSpot dicts; :meth:`read_records` handles envelope + association enrichment.
    """

    state_converter = IsoMillisConcurrentStreamStateConverter(is_sequential_state=False)

    def __init__(
        self,
        *,
        stream_name: str,
        hubspot_api: Hubspot,
        access_token: str,
        tenant_id: str,
        source_id: str,
        start_date: pendulum.DateTime,
        include_archived: bool = True,
    ) -> None:
        self._stream_name = stream_name
        self._hubspot = hubspot_api
        self._registry = STREAM_REGISTRY[stream_name]
        self._object_type = self._registry["object_type"]
        self._tenant_id = tenant_id
        self._source_id = source_id
        self._start_date = start_date
        self._include_archived = include_archived
        self._cursor: Optional[ConcurrentCursor] = None
        self._envelope_collisions_seen: set = set()
        # Archived records are fetched once per sync, not once per slice —
        # archived=true endpoints don't filter by updatedAt, so re-reading
        # them per slice would blow up API call count as O(slices × archives).
        self._archived_emitted: bool = False

        # Every stream gets its own HttpClient so the error handler can
        # attribute failures to the right stream name. Mount a pooled
        # adapter so parallel association + page-fetch traffic from the
        # same stream shares one connection pool instead of opening a new
        # socket per request.
        session = requests.Session()
        session.headers.update({"Authorization": f"Bearer {access_token}"})
        pool_size = 50
        adapter = requests.adapters.HTTPAdapter(
            pool_connections=pool_size, pool_maxsize=pool_size
        )
        session.mount("https://", adapter)
        self._http_client = HttpClient(
            name=f"hubspot_{stream_name}",
            logger=logger,
            session=session,
            error_handler=HubspotErrorHandler(stream_name),
        )

        # Association fetcher is wired only when the registry declares any.
        assoc_targets = list(self._registry.get("associations") or [])
        self._associations: Optional[AssociationFetcher] = (
            AssociationFetcher(
                from_object_type=self._object_type,
                to_object_types=assoc_targets,
                http_client=self._http_client,
            )
            if assoc_targets
            else None
        )

    # ------- Stream identity ------------------------------------------------

    @property
    def name(self) -> str:
        return self._stream_name

    @property
    def primary_key(self) -> Optional[str]:
        return "id"

    @property
    def cursor_field(self) -> Optional[str]:
        # None for owners (forces full-refresh) — see STREAM_REGISTRY.
        return self._registry["cursor_field"]

    def set_cursor(self, cursor: ConcurrentCursor) -> None:
        self._cursor = cursor

    def get_json_schema(self) -> Mapping[str, Any]:
        """Advertise per-stream schema to the destination.

        - Start from describe-generated schema (standard properties only).
        - Add the envelope fields so ClickHouse creates columns for them.
        - Add ``associations_{to_object_type}`` arrays when applicable.
        - Add the ``custom_fields`` JSON blob.
        """
        # Deep copy so inject_envelope_properties and the association-props
        # loop below don't mutate the describe cache shared across streams.
        schema = copy.deepcopy(self._hubspot.generate_schema(self._object_type))
        schema = inject_envelope_properties(schema)
        props = schema.setdefault("properties", {})
        for to_type in self._registry.get("associations") or []:
            props[f"associations_{to_type}"] = {
                "type": ["array", "null"],
                "items": {"type": "string"},
            }
        return schema

    # ------- Read pipeline --------------------------------------------------

    def read_records(
        self,
        sync_mode: SyncMode,
        cursor_field: Optional[List[str]] = None,
        stream_slice: Optional[Mapping[str, Any]] = None,
        stream_state: Optional[Mapping[str, Any]] = None,
    ) -> Iterable[StreamData]:
        """Fetch a slice, batch-enrich associations, envelope, and yield."""
        custom_names = self._hubspot.custom_property_names(self._object_type)

        batch: List[MutableMapping[str, Any]] = []
        for record in self._generate_records(sync_mode, stream_slice, stream_state):
            batch.append(dict(record))
            if len(batch) >= SEARCH_PAGE_LIMIT:
                yield from self._finalize_batch(batch, custom_names)
                batch = []
        if batch:
            yield from self._finalize_batch(batch, custom_names)

    def _finalize_batch(
        self,
        batch: List[MutableMapping[str, Any]],
        custom_names: frozenset,
    ) -> Iterable[MutableMapping[str, Any]]:
        if self._associations is not None:
            self._associations.enrich(batch)
        for record in batch:
            yield envelope(
                record,
                tenant_id=self._tenant_id,
                source_id=self._source_id,
                custom_property_names=custom_names,
                collision_seen=self._envelope_collisions_seen,
            )

    # ------- Subclass contract ----------------------------------------------

    @abstractmethod
    def _generate_records(
        self,
        sync_mode: SyncMode,
        stream_slice: Optional[Mapping[str, Any]],
        stream_state: Optional[Mapping[str, Any]],
    ) -> Iterable[Mapping[str, Any]]:
        """Yield raw (pre-envelope) HubSpot records for this slice."""
        ...


# =============================================================================
# CRM Search stream
# =============================================================================


class CrmSearchStream(HubspotStream):
    """Incremental stream via ``/crm/v3/objects/{type}/search``.

    Slicing strategy — two axes to beat the 10k search-result cap:

    1. **Primary: time slice.** A ConcurrentCursor hands us
       ``(start_date, end_date)`` windows. We filter on
       ``hs_lastmodifieddate`` within the window.

    2. **Inner keyset fallback.** HubSpot Search returns HTTP 400 once
       ``after >= 10_000``. If a slice looks like it'll exceed the cap we
       restart the query inside the same window filtering on
       ``hs_object_id > last_seen_id`` (sorted ascending), repeating until
       a short page arrives.

    Plus an optional archived=true pass when ``hubspot_include_archived``
    is set — archives aren't returned by search, so we page the v3 list
    endpoint with ``archived=true``. That pass runs **once per sync**
    (guarded by ``self._archived_emitted``) regardless of how many time
    slices the cursor produces, because the archived endpoint doesn't
    filter on ``updatedAt`` and re-reading it per slice would amount to
    O(slices × archive_count) API calls.
    """

    @property
    def _search_cursor_property(self) -> str:
        return self._registry["search_cursor_property"]

    def _search_url(self) -> str:
        return f"{BASE_URL}/crm/v3/objects/{self._object_type}/search"

    def _list_url(self) -> str:
        return f"{BASE_URL}/crm/v3/objects/{self._object_type}"

    def _generate_records(
        self,
        sync_mode: SyncMode,
        stream_slice: Optional[Mapping[str, Any]],
        stream_state: Optional[Mapping[str, Any]],
    ) -> Iterable[Mapping[str, Any]]:
        slice_start, slice_end = self._slice_bounds(stream_slice)
        yield from self._read_slice_with_keyset_fallback(slice_start, slice_end)
        # Archived records aren't filtered server-side by updatedAt, so we
        # only page them once per sync (on the first slice). Subsequent
        # slices skip — prevents O(slices × archives) API calls.
        if self._include_archived and not self._archived_emitted:
            self._archived_emitted = True
            yield from self._read_all_archived()

    # ---- Active (non-archived) records via search ---------------------------

    def _read_slice_with_keyset_fallback(
        self, slice_start: str, slice_end: str
    ) -> Iterable[Mapping[str, Any]]:
        """Paginate a slice; on 10k cap, restart with keyset on hs_object_id."""
        property_names = list(self._hubspot.property_names(self._object_type))
        after: Optional[str] = None
        min_object_id: Optional[str] = None
        total_emitted = 0

        while True:
            payload = self._search_body(
                slice_start=slice_start,
                slice_end=slice_end,
                property_names=property_names,
                after=after,
                min_object_id=min_object_id,
            )
            results, next_after = self._post_search(payload)
            if not results:
                return
            for rec in results:
                yield rec
                total_emitted += 1

            # HubSpot 10k cap: once cumulative 'after' would cross the hard
            # cap, switch to keyset pagination on hs_object_id within the
            # same time window. We detect this by inspecting the cap against
            # the integer paging cursor.
            if next_after is None:
                return
            if _after_exceeds_cap(next_after):
                last = results[-1]
                last_id = last.get("id")
                if not last_id:
                    # Can't pivot to keyset without a stable anchor — log and
                    # stop this slice rather than submit an invalid filter.
                    # Orchestration surfaces the warning; shrink slice_step.
                    logger.warning(
                        "Stream '%s' hit %s records in slice [%s..%s] but the "
                        "last record has no id; stopping slice to avoid an "
                        "invalid keyset filter. Shrink hubspot_stream_slice_step.",
                        self._stream_name,
                        SEARCH_AFTER_HARD_CAP,
                        slice_start,
                        slice_end,
                    )
                    return
                min_object_id = str(last_id)
                logger.info(
                    "Stream '%s' hit %s records in slice [%s..%s]; switching "
                    "to keyset pagination from id>%s",
                    self._stream_name,
                    SEARCH_AFTER_HARD_CAP,
                    slice_start,
                    slice_end,
                    min_object_id,
                )
                after = None
                continue
            after = next_after

    def _post_search(self, body: Mapping[str, Any]) -> tuple[List[Mapping[str, Any]], Optional[str]]:
        _, resp = self._http_client.send_request(
            "POST",
            self._search_url(),
            headers={"Content-Type": "application/json"},
            json=body,
            request_kwargs={},
        )
        if not resp.ok:
            # Reaching here means the error handler let the response through
            # as non-retryable but also non-FAIL (shouldn't happen). Surface
            # a clear error rather than silently yielding nothing.
            raise RuntimeError(
                f"HubSpot search returned HTTP {resp.status_code} on "
                f"'{self._stream_name}': {resp.text[:500]}"
            )
        data = resp.json()
        results = list(data.get("results") or [])
        next_after = None
        paging = data.get("paging") or {}
        if isinstance(paging, Mapping):
            nxt = paging.get("next") or {}
            if isinstance(nxt, Mapping):
                next_after = nxt.get("after")
        return results, next_after

    def _search_body(
        self,
        *,
        slice_start: str,
        slice_end: str,
        property_names: List[str],
        after: Optional[str],
        min_object_id: Optional[str],
    ) -> Mapping[str, Any]:
        cursor_prop = self._search_cursor_property
        filters: List[Mapping[str, Any]] = [
            {"propertyName": cursor_prop, "operator": "GTE", "value": slice_start},
            {"propertyName": cursor_prop, "operator": "LT", "value": slice_end},
        ]
        sort_prop = cursor_prop
        if min_object_id is not None:
            # Keyset pagination branch — same time window, but start from the
            # last-seen id. Order by hs_object_id ASC so the cursor advances
            # monotonically regardless of how many records share the same
            # ``hs_lastmodifieddate`` value.
            filters.append(
                {"propertyName": "hs_object_id", "operator": "GT", "value": min_object_id}
            )
            sort_prop = "hs_object_id"
        body: MutableMapping[str, Any] = {
            "filterGroups": [{"filters": filters}],
            "properties": property_names,
            "sorts": [{"propertyName": sort_prop, "direction": "ASCENDING"}],
            "limit": SEARCH_PAGE_LIMIT,
        }
        if after is not None:
            body["after"] = after
        return body

    # ---- Archived records (full sweep, once per sync) ----------------------

    def _read_all_archived(self) -> Iterable[Mapping[str, Any]]:
        """Page the archived list endpoint once per sync.

        Archives aren't returned by the Search API and the list endpoint
        doesn't accept an ``updatedAt`` filter — so splitting this across
        time slices just re-pages the same archive set N times. We stream
        the whole archived set once instead, gated by ``_archived_emitted``
        in :meth:`_generate_records`.
        """
        url = self._list_url()
        properties_param = ",".join(self._hubspot.property_names(self._object_type))
        after: Optional[str] = None
        while True:
            params: MutableMapping[str, Any] = {
                "limit": LIST_PAGE_LIMIT,
                "archived": "true",
            }
            if properties_param:
                params["properties"] = properties_param
            if after:
                params["after"] = after
            _, resp = self._http_client.send_request(
                "GET", url, headers={}, params=params, request_kwargs={}
            )
            if not resp.ok:
                raise RuntimeError(
                    f"HubSpot archived list returned HTTP {resp.status_code} on "
                    f"'{self._stream_name}': {resp.text[:500]}"
                )
            data = resp.json()
            for rec in data.get("results") or []:
                yield rec
            paging = data.get("paging") or {}
            nxt = (paging.get("next") or {}) if isinstance(paging, Mapping) else {}
            after = nxt.get("after") if isinstance(nxt, Mapping) else None
            if not after:
                return

    # ---- Helpers -----------------------------------------------------------

    def _slice_bounds(
        self, stream_slice: Optional[Mapping[str, Any]]
    ) -> tuple[str, str]:
        """Extract ISO-8601 slice bounds from the ConcurrentCursor slice.

        ConcurrentCursor passes naive ``start_date`` / ``end_date`` timestamps.
        HubSpot search needs milliseconds-precision ISO strings or epoch
        millis; ISO works and stays readable in logs.
        """
        if not stream_slice:
            start = self._start_date
            end = pendulum.now("UTC")
        else:
            start = _parse_slice_bound(stream_slice.get("start_date")) or self._start_date
            end = _parse_slice_bound(stream_slice.get("end_date")) or pendulum.now("UTC")
        return start.to_iso8601_string(), end.to_iso8601_string()


# =============================================================================
# Owners stream
# =============================================================================


class OwnersStream(HubspotStream):
    """List /crm/v3/owners/ — no search endpoint, cursor via ``after``.

    Owners schema is stable across portals (no custom properties), so we
    advertise a small hard-coded schema rather than calling properties/v2.
    """

    def get_json_schema(self) -> Mapping[str, Any]:
        schema = {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "id": {"type": ["string", "null"]},
                "email": {"type": ["string", "null"]},
                "firstName": {"type": ["string", "null"]},
                "lastName": {"type": ["string", "null"]},
                "userId": {"type": ["integer", "null"]},
                "createdAt": {"type": ["string", "null"], "format": "date-time"},
                "updatedAt": {"type": ["string", "null"], "format": "date-time"},
                "archived": {"type": ["boolean", "null"]},
            },
        }
        return inject_envelope_properties(schema)

    def _generate_records(
        self,
        sync_mode: SyncMode,
        stream_slice: Optional[Mapping[str, Any]],
        stream_state: Optional[Mapping[str, Any]],
    ) -> Iterable[Mapping[str, Any]]:
        yield from self._paginate_owners(archived=False)
        if self._include_archived:
            yield from self._paginate_owners(archived=True)

    def _paginate_owners(self, *, archived: bool) -> Iterable[Mapping[str, Any]]:
        url = f"{BASE_URL}/crm/v3/owners/"
        after: Optional[str] = None
        while True:
            params: MutableMapping[str, Any] = {
                "limit": LIST_PAGE_LIMIT,
                "archived": "true" if archived else "false",
            }
            if after:
                params["after"] = after
            _, resp = self._http_client.send_request(
                "GET", url, headers={}, params=params, request_kwargs={}
            )
            if not resp.ok:
                raise RuntimeError(
                    f"HubSpot owners list returned HTTP {resp.status_code}: {resp.text[:500]}"
                )
            data = resp.json()
            for rec in data.get("results") or []:
                yield rec
            paging = data.get("paging") or {}
            nxt = (paging.get("next") or {}) if isinstance(paging, Mapping) else {}
            after = nxt.get("after") if isinstance(nxt, Mapping) else None
            if not after:
                return

    def read_records(
        self,
        sync_mode: SyncMode,
        cursor_field: Optional[List[str]] = None,
        stream_slice: Optional[Mapping[str, Any]] = None,
        stream_state: Optional[Mapping[str, Any]] = None,
    ) -> Iterable[StreamData]:
        """Envelope owners without touching the CRM properties endpoint.

        This override is deliberate: owners have no
        ``/crm/v3/properties/owners`` endpoint and no custom-field surface,
        so the base :class:`HubspotStream.read_records` path (which calls
        ``self._hubspot.custom_property_names`` and batches through
        :func:`_finalize_batch`) doesn't apply. We stream directly from
        :meth:`_paginate_owners`, envelope with an empty custom-field set,
        and skip association enrichment (owners have none).
        """
        for record in self._generate_records(sync_mode, stream_slice, stream_state):
            yield envelope(
                record,
                tenant_id=self._tenant_id,
                source_id=self._source_id,
                custom_property_names=frozenset(),
                collision_seen=self._envelope_collisions_seen,
            )


# =============================================================================
# Helpers
# =============================================================================


def _after_exceeds_cap(after: Any) -> bool:
    """True if the ``after`` cursor crosses HubSpot's 10k search-result cap.

    ``after`` is an opaque string from HubSpot but in practice it's numeric
    for search results (row offset). Compare as int; fall back to False on
    non-numeric (shouldn't happen, but guards against API surprise).
    """
    try:
        return int(str(after)) >= SEARCH_AFTER_HARD_CAP
    except (TypeError, ValueError):
        return False


def _parse_slice_bound(value: Any) -> Optional[pendulum.DateTime]:
    if value is None:
        return None
    if isinstance(value, pendulum.DateTime):
        return value
    try:
        return pendulum.parse(str(value))
    except Exception:
        return None
