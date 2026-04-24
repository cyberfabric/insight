"""HubSpot source entry point.

Wires Private App auth, stream construction from the curated registry, and
ConcurrentCursor-based time slicing. Config keys are prefixed ``hubspot_*`` /
``insight_*`` so a shared K8s Secret can carry multiple connectors without
collision — same convention as the Salesforce connector.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator, List, Mapping, MutableMapping, Optional, Tuple, Union

import isodate
import pendulum
from dateutil.relativedelta import relativedelta

from airbyte_cdk.logger import AirbyteLogFormatter
from airbyte_cdk.models import (
    AirbyteMessage,
    AirbyteStateMessage,
    ConfiguredAirbyteCatalog,
    ConfiguredAirbyteStream,
    ConnectorSpecification,
    FailureType,
    Level,
    SyncMode,
)
from airbyte_cdk.sources.concurrent_source.concurrent_source import ConcurrentSource
from airbyte_cdk.sources.concurrent_source.concurrent_source_adapter import ConcurrentSourceAdapter
from airbyte_cdk.sources.connector_state_manager import ConnectorStateManager
from airbyte_cdk.sources.message import InMemoryMessageRepository
from airbyte_cdk.sources.source import TState
from airbyte_cdk.sources.streams import Stream
from airbyte_cdk.sources.streams.concurrent.adapters import StreamFacade
from airbyte_cdk.sources.streams.concurrent.cursor import (
    ConcurrentCursor,
    CursorField,
    FinalStateCursor,
)
from airbyte_cdk.sources.utils.schema_helpers import InternalConfig
from airbyte_cdk.utils.traced_exception import AirbyteTracedException

from source_hubspot.api import Hubspot
from source_hubspot.constants import (
    CURATED_STREAMS,
    STREAM_REGISTRY,
)
from source_hubspot.streams import CrmSearchStream, HubspotStream, OwnersStream


logger = logging.getLogger("airbyte")

_DEFAULT_CONCURRENCY = 20
_MAX_CONCURRENCY = 50
_DEFAULT_LOOKBACK = timedelta(minutes=10)
_DEFAULT_SLICE_STEP = timedelta(days=30)
_START_DATE_FALLBACK_YEARS = 2


class SourceHubspot(ConcurrentSourceAdapter):
    DATETIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
    stop_sync_on_stream_failure = True
    message_repository = InMemoryMessageRepository(
        Level(AirbyteLogFormatter.level_mapping[logger.level])
    )

    def __init__(
        self,
        catalog: Optional[ConfiguredAirbyteCatalog],
        config: Optional[Mapping[str, Any]],
        state: Optional[TState],
        **kwargs,
    ):
        concurrency_level = _DEFAULT_CONCURRENCY
        if config:
            raw = config.get("hubspot_num_workers", _DEFAULT_CONCURRENCY)
            try:
                parsed = int(raw)
            except (TypeError, ValueError):
                parsed = _DEFAULT_CONCURRENCY
            concurrency_level = max(1, min(parsed, _MAX_CONCURRENCY))
        logger.info(f"Using concurrent cdk with concurrency level {concurrency_level}")
        concurrent_source = ConcurrentSource.create(
            concurrency_level,
            max(1, concurrency_level // 2),
            logger,
            self._slice_logger,
            self.message_repository,
        )
        super().__init__(concurrent_source)
        self.catalog = catalog
        self.state = state

    # ------- Spec / check ---------------------------------------------------

    def spec(self, logger_: logging.Logger) -> ConnectorSpecification:
        spec_path = Path(__file__).parent / "spec.json"
        return ConnectorSpecification(**json.loads(spec_path.read_text()))

    def check_connection(
        self, logger: logging.Logger, config: Mapping[str, Any]
    ) -> Tuple[bool, Optional[str]]:
        self._validate_iso_duration(config.get("hubspot_stream_slice_step"), "hubspot_stream_slice_step")
        self._validate_iso_duration(config.get("hubspot_lookback_window"), "hubspot_lookback_window")
        hubspot = Hubspot(access_token=config["hubspot_access_token"])
        ok, reason = hubspot.check_connection()
        if not ok:
            return False, reason
        # Probe property discovery on a stream the operator actually enabled
        # — hard-coding "contacts" would false-fail tokens scoped to, say,
        # deals-only portals. Owners skipped because it has no properties
        # endpoint. Falls through to "contacts" only if the override list
        # is exclusively owners or unknown names.
        probe_object = self._pick_properties_probe_object(config)
        if probe_object is not None:
            try:
                hubspot.properties_for(probe_object)
            except AirbyteTracedException as exc:
                return False, exc.message
        return True, None

    def _pick_properties_probe_object(
        self, config: Mapping[str, Any]
    ) -> Optional[str]:
        """First requested stream that has a CRM properties endpoint."""
        for name in self._resolve_stream_list(config):
            entry = STREAM_REGISTRY.get(name)
            if entry is None:
                continue
            obj = entry.get("object_type")
            if obj and obj != "owners":
                return obj
        return None

    # ------- Stream discovery ----------------------------------------------

    def streams(self, config: Mapping[str, Any]) -> List[Stream]:
        start_date = self._resolve_start_date(config)
        hubspot = Hubspot(access_token=config["hubspot_access_token"])
        requested = self._resolve_stream_list(config)
        state_manager = ConnectorStateManager(state=self.state)

        streams: List[Stream] = []
        for stream_name in requested:
            if stream_name not in STREAM_REGISTRY:
                logger.warning(
                    "Unknown HubSpot stream '%s' in hubspot_streams override; skipping",
                    stream_name,
                )
                continue
            stream = self._build_stream(stream_name, config, hubspot, start_date)
            streams.append(self._wrap_for_concurrency(config, stream, state_manager))
        return streams

    def _build_stream(
        self,
        stream_name: str,
        config: Mapping[str, Any],
        hubspot: Hubspot,
        start_date: pendulum.DateTime,
    ) -> HubspotStream:
        kwargs = dict(
            stream_name=stream_name,
            hubspot_api=hubspot,
            access_token=config["hubspot_access_token"],
            tenant_id=config["insight_tenant_id"],
            source_id=config["insight_source_id"],
            start_date=start_date,
            include_archived=bool(config.get("hubspot_include_archived", True)),
        )
        if stream_name == "owners":
            return OwnersStream(**kwargs)
        return CrmSearchStream(**kwargs)

    def _wrap_for_concurrency(
        self,
        config: Mapping[str, Any],
        stream: HubspotStream,
        state_manager: ConnectorStateManager,
    ) -> Stream:
        is_full_refresh = self._get_sync_mode_from_catalog(stream) == SyncMode.full_refresh
        if is_full_refresh or not stream.cursor_field:
            cursor = FinalStateCursor(
                stream_name=stream.name,
                stream_namespace=stream.namespace,
                message_repository=self.message_repository,
            )
            return StreamFacade.create_from_stream(stream, self, logger, None, cursor)

        slicer_cursor = self._create_stream_slicer_cursor(config, state_manager, stream)
        stream.set_cursor(slicer_cursor)
        return StreamFacade.create_from_stream(
            stream, self, logger, slicer_cursor.state, slicer_cursor
        )

    # ------- Concurrency / cursor helpers ----------------------------------

    def _create_stream_slicer_cursor(
        self,
        config: Mapping[str, Any],
        state_manager: ConnectorStateManager,
        stream: HubspotStream,
    ) -> ConcurrentCursor:
        cursor_field_key = stream.cursor_field
        cursor_field = CursorField(cursor_field_key)
        stream_state = state_manager.get_stream_state(stream.name, stream.namespace)
        lookback = _parse_duration(
            config.get("hubspot_lookback_window"), _DEFAULT_LOOKBACK
        )
        slice_step = _parse_duration(
            config.get("hubspot_stream_slice_step"), _DEFAULT_SLICE_STEP
        )
        start = self._resolve_start_date(config)
        return ConcurrentCursor(
            stream.name,
            stream.namespace,
            stream_state,
            self.message_repository,
            state_manager,
            stream.state_converter,
            cursor_field,
            ("start_date", "end_date"),
            datetime.fromtimestamp(start.timestamp(), timezone.utc),
            stream.state_converter.get_end_provider(),
            lookback,
            slice_step,
        )

    def _get_sync_mode_from_catalog(self, stream: Stream) -> Optional[SyncMode]:
        if self.catalog:
            for catalog_stream in self.catalog.streams:
                if stream.name == catalog_stream.stream.name:
                    return catalog_stream.sync_mode
        return None

    # ------- Config helpers ------------------------------------------------

    def _resolve_start_date(self, config: Mapping[str, Any]) -> pendulum.DateTime:
        raw = config.get("hubspot_start_date")
        if raw:
            try:
                parsed = pendulum.parse(raw)
            except Exception as exc:
                raise AirbyteTracedException(
                    message=(
                        f"Invalid hubspot_start_date {raw!r}. "
                        "Expected YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ."
                    ),
                    internal_message=str(exc),
                    failure_type=FailureType.config_error,
                ) from exc
            # pendulum.parse can return Date or Time for partial inputs; the
            # ConcurrentCursor requires a DateTime to compute slice bounds.
            # Always normalize to UTC so slice math doesn't inherit a
            # locale-dependent offset from the input string.
            if isinstance(parsed, pendulum.DateTime):
                return parsed.in_timezone("UTC")
            if isinstance(parsed, pendulum.Date):
                return pendulum.datetime(
                    parsed.year, parsed.month, parsed.day, tz="UTC"
                )
            raise AirbyteTracedException(
                message=(
                    f"hubspot_start_date {raw!r} parsed as {type(parsed).__name__}; "
                    "expected a date or datetime."
                ),
                internal_message=f"type={type(parsed).__name__}",
                failure_type=FailureType.config_error,
            )
        fallback = datetime.now(timezone.utc) - relativedelta(years=_START_DATE_FALLBACK_YEARS)
        return pendulum.instance(fallback)

    def _resolve_stream_list(self, config: Mapping[str, Any]) -> List[str]:
        override = list(config.get("hubspot_streams") or [])
        if override:
            return override
        return list(CURATED_STREAMS)

    @staticmethod
    def _validate_iso_duration(value: Any, key: str) -> None:
        if not value:
            return
        try:
            duration = isodate.parse_duration(value)
        except (isodate.ISO8601Error, ValueError, TypeError, AttributeError) as e:
            raise AirbyteTracedException(
                failure_type=FailureType.config_error,
                internal_message=str(e),
                message=(
                    f"{key} must be an ISO-8601 duration (e.g. 'PT10M', 'P30D'). "
                    f"Got: {value!r}"
                ),
            ) from e
        td = duration if isinstance(duration, timedelta) else None
        if td is None and hasattr(duration, "totimedelta"):
            try:
                td = duration.totimedelta(start=datetime.now(timezone.utc))
            except Exception:
                td = None
        if td is None or td < timedelta(seconds=0):
            raise AirbyteTracedException(
                failure_type=FailureType.config_error,
                internal_message=f"{key} must be a non-negative duration",
                message=f"{key} must be a non-negative ISO-8601 duration. Got: {value!r}",
            )
        # Zero is legal for lookback_window (no lookback) but would make the
        # cursor never advance a slice for slice_step — reject it.
        if key == "hubspot_stream_slice_step" and td == timedelta(seconds=0):
            raise AirbyteTracedException(
                failure_type=FailureType.config_error,
                internal_message="stream_slice_step must be > 0",
                message=(
                    f"{key} must be a positive duration (zero would hang the "
                    f"cursor). Got: {value!r}"
                ),
            )

    # ------- Read override (logging) ---------------------------------------

    def read(
        self,
        logger: logging.Logger,
        config: Mapping[str, Any],
        catalog: ConfiguredAirbyteCatalog,
        state: Optional[Union[List[AirbyteStateMessage], MutableMapping[str, Any]]] = None,
    ) -> Iterator[AirbyteMessage]:
        self.catalog = catalog
        yield from super().read(logger, config, catalog, state)


def _parse_duration(value: Any, fallback: timedelta) -> timedelta:
    if not value:
        return fallback
    try:
        parsed = isodate.parse_duration(value)
    except Exception:
        return fallback
    if isinstance(parsed, timedelta):
        return parsed
    if hasattr(parsed, "totimedelta"):
        try:
            return parsed.totimedelta(start=datetime.now(timezone.utc))
        except Exception:
            return fallback
    return fallback


def main() -> None:
    """CLI entry-point used by the Docker ENTRYPOINT and pyproject console script."""
    import sys
    from airbyte_cdk.entrypoint import AirbyteEntrypoint, launch

    args = sys.argv[1:]
    catalog_path = AirbyteEntrypoint.extract_catalog(args)
    config_path = AirbyteEntrypoint.extract_config(args)
    state_path = AirbyteEntrypoint.extract_state(args)
    source = SourceHubspot(
        SourceHubspot.read_catalog(catalog_path) if catalog_path else None,
        SourceHubspot.read_config(config_path) if config_path else None,
        SourceHubspot.read_state(state_path) if state_path else None,
    )
    launch(source, args)


if __name__ == "__main__":
    main()
