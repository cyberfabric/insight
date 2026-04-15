using ClickHouse.Client.ADO;
using ClickHouse.Client.Utility;
using Insight.Jobs.Domain.Models;
using Microsoft.Extensions.Logging;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public sealed class JobRunRepository : IJobRunRepository
{
    private static readonly DateTime Epoch = new(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    private readonly ClickHouseConnectionFactory _factory;
    private readonly ILogger<JobRunRepository> _logger;

    public JobRunRepository(ClickHouseConnectionFactory factory, ILogger<JobRunRepository> logger)
    {
        _factory = factory;
        _logger = logger;
    }

    public async Task<DateTime> GetLastWatermarkAsync(string jobName)
    {
        _logger.LogDebug("GetLastWatermarkAsync: creating connection...");
        ClickHouseConnection? conn = null;
        try
        {
            conn = _factory.Create();
            _logger.LogDebug("GetLastWatermarkAsync: connection created, ServerUri={Uri}. Opening...", conn.ConnectionString);
            await conn.OpenAsync();
            _logger.LogDebug("GetLastWatermarkAsync: connection opened.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetLastWatermarkAsync: failed to open ClickHouse connection.");
            throw;
        }

        try
        {
            await using var cmd = conn.CreateCommand();
            cmd.CommandText = """
                SELECT max(watermark)
                FROM identity.job_runs
                WHERE job_name = {name:String}
                  AND state = 'succeeded'
                """;
            cmd.AddParameter("name", jobName);

            var result = await cmd.ExecuteScalarAsync();
            _logger.LogDebug("GetLastWatermarkAsync: result type={Type}, value={Value}", result?.GetType().Name, result);
            if (result is DateTime dt && dt > Epoch)
                return dt;

            return Epoch;
        }
        finally
        {
            await conn.DisposeAsync();
        }
    }

    public async Task<Guid> StartRunAsync(string jobName)
    {
        var runId = Guid.NewGuid();

        await using var conn = _factory.Create();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO identity.job_runs (id, job_name, state, started_at)
            VALUES ({id:UUID}, {name:String}, 'running', now64(3))
            """;
        cmd.AddParameter("id", runId);
        cmd.AddParameter("name", jobName);

        await cmd.ExecuteNonQueryAsync();
        _logger.LogInformation("Started job run {RunId} for {JobName}", runId, jobName);
        return runId;
    }

    public async Task CompleteRunAsync(Guid runId, string jobName, JobRun run)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        // MergeTree: append a completion record (same id, but MergeTree keeps both;
        // queries use ORDER BY started_at so latest state wins)
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO identity.job_runs (
                id, job_name, insight_tenant_id, state, started_at, finished_at,
                watermark, rows_processed, rows_aliases_created,
                rows_aliases_updated, rows_persons_created, error_message
            ) VALUES (
                {id:UUID}, {name:String}, {tenant:UUID}, 'succeeded',
                {started:DateTime64(3, 'UTC')}, now64(3),
                {watermark:DateTime64(3, 'UTC')}, {processed:UInt64}, {created:UInt64},
                {updated:UInt64}, {persons:UInt64}, ''
            )
            """;
        cmd.AddParameter("id", runId);
        cmd.AddParameter("name", jobName);
        cmd.AddParameter("tenant", run.InsightTenantId);
        cmd.AddParameter("started", run.StartedAt);
        cmd.AddParameter("watermark", run.Watermark);
        cmd.AddParameter("processed", run.RowsProcessed);
        cmd.AddParameter("created", run.RowsAliasesCreated);
        cmd.AddParameter("updated", run.RowsAliasesUpdated);
        cmd.AddParameter("persons", run.RowsPersonsCreated);

        await cmd.ExecuteNonQueryAsync();
        _logger.LogInformation("Completed job run {RunId}: processed={Processed}, aliases_created={Created}, aliases_updated={Updated}, persons_created={Persons}",
            runId, run.RowsProcessed, run.RowsAliasesCreated, run.RowsAliasesUpdated, run.RowsPersonsCreated);
    }

    public async Task FailRunAsync(Guid runId, string jobName, string errorMessage)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO identity.job_runs (
                id, job_name, state, started_at, finished_at, error_message
            ) VALUES (
                {id:UUID}, {name:String}, 'failed', now64(3), now64(3), {error:String}
            )
            """;
        cmd.AddParameter("id", runId);
        cmd.AddParameter("name", jobName);
        cmd.AddParameter("error", errorMessage);

        await cmd.ExecuteNonQueryAsync();
    }
}
