# ADR-003: Analytics Database Selection - ClickHouse

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/backend/PRD.md`  
**Related ADR**: `ADR-001-backend-framework-django.md`

## Context

The Git Stats Backend requires an analytics database to store and query:
- Git commit data (millions of commits)
- Pull request metrics
- AI tool usage statistics
- User activity and productivity metrics
- Repository and organizational metadata
- Time-series data for trend analysis

Requirements:
- Handle millions of rows efficiently
- Sub-second query response times for complex aggregations
- Support for time-series analysis
- Efficient filtering across multiple dimensions (date, user, repo, language)
- Horizontal scalability for growing datasets
- Integration with existing data pipeline
- Support for analytical queries (GROUP BY, aggregations, window functions)

Query patterns:
- Time-series aggregations (daily/weekly/monthly trends)
- Multi-dimensional filtering (date + user + repo + language)
- Top-N queries (top contributors, most active repos)
- Percentile calculations (p50, p95, p99)
- Complex joins across commits, PRs, and users

## Decision

We will use **ClickHouse 21.0+** as the analytics database for storing and querying git statistics and metrics data.

## Rationale

### Why ClickHouse

1. **Columnar Storage**: Optimized for analytical queries:
   - Stores data by column, not row
   - Reads only required columns (10-100x faster than row-based)
   - Excellent compression ratios (5-10x)
   - Perfect for aggregations and analytics

2. **Query Performance**: Sub-second queries on billions of rows:
   - Vectorized query execution
   - Parallel query processing across cores
   - Query cache for repeated queries
   - Materialized views for pre-aggregation

3. **Time-Series Optimization**: Built for time-series data:
   - Efficient date range filtering
   - Time-based partitioning
   - Window functions for trend analysis
   - Date/time functions optimized

4. **Scalability**: Horizontal scaling for growing datasets:
   - Distributed tables across multiple nodes
   - Replication for high availability
   - Handles petabytes of data
   - Linear scaling with hardware

5. **SQL Compatibility**: Standard SQL with extensions:
   - Familiar query syntax
   - Rich function library
   - Complex aggregations and window functions
   - Easy integration with BI tools

6. **Compression**: Excellent compression ratios:
   - 5-10x compression typical
   - Reduces storage costs
   - Faster I/O due to less data transfer
   - Multiple compression algorithms (LZ4, ZSTD)

7. **HTTP Interface**: Simple integration:
   - HTTP API for queries (no special drivers needed)
   - JSON/CSV/TabSeparated output formats
   - Parameterized queries for security
   - Easy to proxy from Django backend

8. **Real-World Validation**: Proven at scale:
   - Used by Cloudflare, Uber, eBay, Spotify
   - Handles trillions of rows in production
   - Active development and community
   - Extensive documentation

### Alternatives Considered

#### PostgreSQL
- **Pros**: Mature, ACID compliant, full SQL support, Django ORM compatible
- **Cons**: Row-based storage slow for analytics, poor compression, limited scalability for billions of rows
- **Verdict**: Rejected due to poor analytical query performance at scale

#### TimescaleDB (PostgreSQL extension)
- **Pros**: Time-series optimized, PostgreSQL compatibility, ACID compliant
- **Cons**: Still row-based, slower than columnar databases, limited compression
- **Verdict**: Rejected due to performance limitations compared to columnar databases

#### Apache Druid
- **Pros**: Real-time analytics, columnar storage, sub-second queries
- **Cons**: Complex setup, limited SQL support, steeper learning curve, overkill for batch analytics
- **Verdict**: Rejected due to complexity and real-time requirements not needed

#### Google BigQuery
- **Pros**: Serverless, scalable, SQL support, managed service
- **Cons**: Cloud vendor lock-in, cost unpredictable, data egress fees, latency for on-premise integration
- **Verdict**: Rejected due to vendor lock-in and cost concerns

#### Amazon Redshift
- **Pros**: Columnar storage, SQL support, AWS integration
- **Cons**: Cloud vendor lock-in, expensive, slower than ClickHouse, complex pricing
- **Verdict**: Rejected due to vendor lock-in and cost

#### Apache Pinot
- **Pros**: Real-time analytics, columnar storage, LinkedIn-backed
- **Cons**: Complex setup, limited SQL support, smaller community, overkill for batch analytics
- **Verdict**: Rejected due to complexity and real-time requirements not needed

#### Elasticsearch
- **Pros**: Full-text search, aggregations, distributed
- **Cons**: Not optimized for structured analytics, higher resource usage, complex query DSL
- **Verdict**: Rejected as designed for search, not structured analytics

## Consequences

### Positive

- **Performance**: Sub-second queries on millions of rows
- **Scalability**: Handles growing dataset (millions → billions of rows)
- **Cost Efficiency**: 5-10x compression reduces storage costs
- **Query Flexibility**: Standard SQL with rich analytical functions
- **Integration**: Simple HTTP API for Django backend proxy
- **Time-Series**: Optimized for date-based queries and trends

### Negative

- **Learning Curve**: Team needs to learn ClickHouse-specific optimizations
- **No Transactions**: Eventually consistent, not ACID (acceptable for analytics)
- **Updates/Deletes**: Expensive operations (mitigated by append-only data model)
- **Operational Complexity**: Requires separate server and monitoring

### Neutral

- **Separate Database**: Analytics data separate from user data (good separation of concerns)
- **ETL Pipeline**: Requires data ingestion pipeline (already exists)
- **Backup Strategy**: Different from SQLite (requires ClickHouse-specific tools)

## Implementation Notes

### Table Schema Example

```sql
-- Commits table
CREATE TABLE commits (
    sha String,
    author String,
    author_email String,
    commit_date DateTime,
    message String,
    lines_added UInt32,
    lines_deleted UInt32,
    lines_modified UInt32,
    ai_assisted UInt8,  -- Boolean as 0/1
    ai_tool String,
    repository String,
    organization String,
    language String,
    ingestion_date Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(commit_date)
ORDER BY (organization, repository, commit_date, author)
SETTINGS index_granularity = 8192;
```

### Django Integration

```python
# apps/data_proxy/clickhouse_client.py
import requests
from django.conf import settings

class ClickHouseClient:
    def __init__(self):
        self.base_url = settings.CLICKHOUSE_URL
        self.database = settings.CLICKHOUSE_DATABASE
    
    def query(self, sql, params=None):
        """Execute parameterized query"""
        url = f"{self.base_url}/"
        
        # Use parameterized queries for security
        if params:
            for key, value in params.items():
                sql = sql.replace(f":{key}", self._escape(value))
        
        response = requests.post(
            url,
            params={'database': self.database},
            data=sql,
            headers={'Content-Type': 'text/plain'}
        )
        
        if response.status_code != 200:
            raise Exception(f"ClickHouse error: {response.text}")
        
        return response.json()
    
    def _escape(self, value):
        """Escape value for SQL injection prevention"""
        if isinstance(value, str):
            return f"'{value.replace("'", "''")}'"
        return str(value)

# Usage in views
client = ClickHouseClient()
results = client.query("""
    SELECT 
        author,
        count() as commit_count,
        sum(lines_added + lines_deleted) as total_loc
    FROM commits
    WHERE commit_date >= :start_date
      AND commit_date <= :end_date
      AND organization = :org
    GROUP BY author
    ORDER BY commit_count DESC
    LIMIT 100
""", {
    'start_date': '2024-01-01',
    'end_date': '2024-12-31',
    'org': 'Engineering'
})
```

### Query Optimization Patterns

```sql
-- Use PREWHERE for filtering (faster than WHERE)
SELECT author, count()
FROM commits
PREWHERE commit_date >= '2024-01-01'
WHERE organization = 'Engineering'
GROUP BY author;

-- Use materialized views for common aggregations
CREATE MATERIALIZED VIEW daily_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, author)
AS SELECT
    toDate(commit_date) as date,
    author,
    count() as commit_count,
    sum(lines_added) as lines_added,
    sum(lines_deleted) as lines_deleted
FROM commits
GROUP BY date, author;

-- Use sampling for approximate queries
SELECT author, count()
FROM commits SAMPLE 0.1  -- 10% sample
WHERE commit_date >= '2024-01-01'
GROUP BY author;
```

### Performance Monitoring

```python
# apps/monitoring/clickhouse_monitor.py
def log_slow_query(query, duration_ms):
    """Log queries exceeding threshold"""
    if duration_ms > 1000:  # 1 second threshold
        logger.warning(
            f"Slow ClickHouse query: {duration_ms}ms",
            extra={
                'query': query,
                'duration_ms': duration_ms,
            }
        )
```

### Backup Strategy

```bash
#!/bin/bash
# ClickHouse backup script

# Backup using clickhouse-backup tool
clickhouse-backup create backup_$(date +%Y%m%d_%H%M%S)

# Upload to S3 (optional)
clickhouse-backup upload backup_$(date +%Y%m%d_%H%M%S)

# Keep only last 7 days of backups
clickhouse-backup delete old 7
```

## Compliance

- **Performance**: Sub-second queries support <500ms API response requirement
- **Scalability**: Handles millions of commits with room for billions
- **Query Flexibility**: Standard SQL supports all analytical requirements
- **Integration**: HTTP API enables simple Django proxy integration
- **Cost**: Compression reduces storage costs by 5-10x

## Migration Considerations

ClickHouse is append-only optimized. For updates/deletes:
- Use `ReplacingMergeTree` engine for updates
- Use `CollapsingMergeTree` for deletes
- Or design data model to be append-only (preferred)

## References

- [ClickHouse Documentation](https://clickhouse.com/docs/)
- [ClickHouse Performance](https://clickhouse.com/docs/en/operations/performance/)
- [ClickHouse HTTP Interface](https://clickhouse.com/docs/en/interfaces/http/)
- [ClickHouse Best Practices](https://clickhouse.com/docs/en/operations/tips/)
- Backend PRD: `docs/backend/PRD.md`
- Related ADR: `ADR-001-backend-framework-django.md`
