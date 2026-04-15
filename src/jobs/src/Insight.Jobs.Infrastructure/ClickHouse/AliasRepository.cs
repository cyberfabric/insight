using ClickHouse.Client.ADO;
using ClickHouse.Client.Utility;
using Insight.Jobs.Domain.Models;
using Microsoft.Extensions.Logging;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public sealed class AliasRepository : IAliasRepository
{
    private readonly ClickHouseConnectionFactory _factory;
    private readonly ILogger<AliasRepository> _logger;

    public AliasRepository(ClickHouseConnectionFactory factory, ILogger<AliasRepository> logger)
    {
        _factory = factory;
        _logger = logger;
    }

    public async Task<Alias?> LookupAsync(Guid tenantId, string aliasType, string aliasValue)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT id, insight_tenant_id, person_id, alias_type, alias_value,
                   alias_field_name, insight_source_id, insight_source_type,
                   source_account_id, confidence, is_active, is_deleted
            FROM identity.aliases FINAL
            WHERE insight_tenant_id = {tenant:UUID}
              AND alias_type = {type:String}
              AND alias_value = {value:String}
              AND is_deleted = 0
            LIMIT 1
            """;
        cmd.AddParameter("tenant", tenantId);
        cmd.AddParameter("type", aliasType);
        cmd.AddParameter("value", aliasValue);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            return null;

        return new Alias
        {
            Id = reader.GetGuid(0),
            InsightTenantId = reader.GetGuid(1),
            PersonId = reader.GetGuid(2),
            AliasType = reader.GetString(3),
            AliasValue = reader.GetString(4),
            AliasFieldName = reader.GetString(5),
            InsightSourceId = reader.GetGuid(6),
            InsightSourceType = reader.GetString(7),
            SourceAccountId = reader.GetString(8),
            Confidence = reader.GetFloat(9),
            IsActive = reader.GetByte(10),
            IsDeleted = reader.GetByte(11),
        };
    }

    public async Task InsertAsync(Alias alias)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO identity.aliases (
                id, insight_tenant_id, person_id, alias_type, alias_value,
                alias_field_name, insight_source_id, insight_source_type,
                source_account_id, confidence, is_active,
                effective_from, effective_to, first_observed_at, last_observed_at,
                created_at, updated_at, is_deleted
            ) VALUES (
                generateUUIDv7(),
                {tenant:UUID}, {person:UUID}, {type:String}, {value:String},
                {field:String}, {srcId:UUID}, {srcType:String},
                {srcAccount:String}, {confidence:Float32}, 1,
                now64(3), toDateTime64('1970-01-01 00:00:00.000', 3, 'UTC'),
                now64(3), now64(3), now64(3), now64(3), 0
            )
            """;
        cmd.AddParameter("tenant", alias.InsightTenantId);
        cmd.AddParameter("person", alias.PersonId);
        cmd.AddParameter("type", alias.AliasType);
        cmd.AddParameter("value", alias.AliasValue);
        cmd.AddParameter("field", alias.AliasFieldName);
        cmd.AddParameter("srcId", alias.InsightSourceId);
        cmd.AddParameter("srcType", alias.InsightSourceType);
        cmd.AddParameter("srcAccount", alias.SourceAccountId);
        cmd.AddParameter("confidence", alias.Confidence);

        await cmd.ExecuteNonQueryAsync();
    }

    public async Task UpdateLastObservedAsync(Guid tenantId, string aliasType, string aliasValue, Guid sourceId)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        // ReplacingMergeTree: insert a new version with updated last_observed_at + updated_at
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO identity.aliases (
                id, insight_tenant_id, person_id, alias_type, alias_value,
                alias_field_name, insight_source_id, insight_source_type,
                source_account_id, confidence, is_active,
                effective_from, effective_to, first_observed_at, last_observed_at,
                created_at, updated_at, is_deleted
            )
            SELECT
                id, insight_tenant_id, person_id, alias_type, alias_value,
                alias_field_name, insight_source_id, insight_source_type,
                source_account_id, confidence, is_active,
                effective_from, effective_to, first_observed_at, now64(3),
                created_at, now64(3), is_deleted
            FROM identity.aliases FINAL
            WHERE insight_tenant_id = {tenant:UUID}
              AND alias_type = {type:String}
              AND alias_value = {value:String}
              AND is_deleted = 0
            LIMIT 1
            """;
        cmd.AddParameter("tenant", tenantId);
        cmd.AddParameter("type", aliasType);
        cmd.AddParameter("value", aliasValue);

        await cmd.ExecuteNonQueryAsync();
    }

    public async Task SoftDeleteAsync(Guid tenantId, string aliasType, string aliasValue, string sourceType)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        // ReplacingMergeTree: insert a new version with is_deleted=1, is_active=0
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO identity.aliases (
                id, insight_tenant_id, person_id, alias_type, alias_value,
                alias_field_name, insight_source_id, insight_source_type,
                source_account_id, confidence, is_active,
                effective_from, effective_to, first_observed_at, last_observed_at,
                created_at, updated_at, is_deleted
            )
            SELECT
                id, insight_tenant_id, person_id, alias_type, alias_value,
                alias_field_name, insight_source_id, insight_source_type,
                source_account_id, confidence, 0,
                effective_from, now64(3), first_observed_at, now64(3),
                created_at, now64(3), 1
            FROM identity.aliases FINAL
            WHERE insight_tenant_id = {tenant:UUID}
              AND alias_type = {type:String}
              AND alias_value = {value:String}
              AND insight_source_type = {srcType:String}
              AND is_deleted = 0
            LIMIT 1
            """;
        cmd.AddParameter("tenant", tenantId);
        cmd.AddParameter("type", aliasType);
        cmd.AddParameter("value", aliasValue);
        cmd.AddParameter("srcType", sourceType);

        await cmd.ExecuteNonQueryAsync();
    }
}
