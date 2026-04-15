using ClickHouse.Client.ADO;
using ClickHouse.Client.Utility;
using Insight.Jobs.Domain.Models;
using Microsoft.Extensions.Logging;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public sealed class BootstrapInputRepository : IBootstrapInputRepository
{
    private readonly ClickHouseConnectionFactory _factory;
    private readonly ILogger<BootstrapInputRepository> _logger;

    public BootstrapInputRepository(ClickHouseConnectionFactory factory, ILogger<BootstrapInputRepository> logger)
    {
        _factory = factory;
        _logger = logger;
    }

    public async Task<IReadOnlyList<BootstrapInput>> GetUnprocessedAsync(DateTime watermark, int batchSize)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT insight_tenant_id, insight_source_id, insight_source_type,
                   source_account_id, alias_type, alias_value, alias_field_name,
                   operation_type, _synced_at
            FROM identity.bootstrap_inputs
            WHERE _synced_at > {watermark:DateTime64(3, 'UTC')}
            ORDER BY _synced_at
            LIMIT {limit:UInt32}
            """;
        cmd.AddParameter("watermark", watermark);
        cmd.AddParameter("limit", (uint)batchSize);

        var results = new List<BootstrapInput>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            results.Add(new BootstrapInput
            {
                InsightTenantId = reader.GetGuid(0),
                InsightSourceId = reader.GetGuid(1),
                InsightSourceType = reader.GetString(2),
                SourceAccountId = reader.GetString(3),
                AliasType = reader.GetString(4),
                AliasValue = reader.GetString(5),
                AliasFieldName = reader.GetString(6),
                OperationType = reader.GetString(7),
                SyncedAt = reader.GetDateTime(8),
            });
        }

        _logger.LogInformation("Fetched {Count} bootstrap_inputs after watermark {Watermark}", results.Count, watermark);
        return results;
    }
}
