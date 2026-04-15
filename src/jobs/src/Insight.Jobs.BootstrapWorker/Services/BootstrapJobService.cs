using Insight.Jobs.Domain.Models;
using Insight.Jobs.Domain.Services;
using Insight.Jobs.Infrastructure.ClickHouse;
using Microsoft.Extensions.Logging;

namespace Insight.Jobs.BootstrapWorker.Services;

public sealed class BootstrapJobService
{
    private const string JobName = "bootstrap_job";

    private readonly IBootstrapInputRepository _inputs;
    private readonly IAliasRepository _aliases;
    private readonly IPersonRepository _persons;
    private readonly IJobRunRepository _jobRuns;
    private readonly IAliasNormalizer _normalizer;
    private readonly ILogger<BootstrapJobService> _logger;
    private readonly int _batchSize;

    public BootstrapJobService(
        IBootstrapInputRepository inputs,
        IAliasRepository aliases,
        IPersonRepository persons,
        IJobRunRepository jobRuns,
        IAliasNormalizer normalizer,
        ILogger<BootstrapJobService> logger,
        int batchSize = 10_000)
    {
        _inputs = inputs;
        _aliases = aliases;
        _persons = persons;
        _jobRuns = jobRuns;
        _normalizer = normalizer;
        _logger = logger;
        _batchSize = batchSize;
    }

    public async Task ExecuteAsync()
    {
        var watermark = await _jobRuns.GetLastWatermarkAsync(JobName);
        _logger.LogInformation("BootstrapJob starting. Last watermark: {Watermark}", watermark);

        var runId = await _jobRuns.StartRunAsync(JobName);
        var stats = new JobRun
        {
            Id = runId,
            JobName = JobName,
            StartedAt = DateTime.UtcNow,
        };

        try
        {
            var maxSyncedAt = watermark;

            while (true)
            {
                var batch = await _inputs.GetUnprocessedAsync(maxSyncedAt, _batchSize);
                if (batch.Count == 0)
                    break;

                foreach (var input in batch)
                {
                    await ProcessInputAsync(input, stats);
                    if (input.SyncedAt > maxSyncedAt)
                        maxSyncedAt = input.SyncedAt;
                }

                stats.RowsProcessed += (ulong)batch.Count;
                _logger.LogInformation("Processed batch of {Count} inputs. Total: {Total}", batch.Count, stats.RowsProcessed);

                if (batch.Count < _batchSize)
                    break;
            }

            stats.Watermark = maxSyncedAt;
            await _jobRuns.CompleteRunAsync(runId, JobName, stats);
            _logger.LogInformation("BootstrapJob completed. Processed={Processed}, AliasesCreated={Created}, AliasesUpdated={Updated}, PersonsCreated={Persons}",
                stats.RowsProcessed, stats.RowsAliasesCreated, stats.RowsAliasesUpdated, stats.RowsPersonsCreated);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "BootstrapJob failed after processing {Processed} rows", stats.RowsProcessed);
            await _jobRuns.FailRunAsync(runId, JobName, ex.Message);
            throw;
        }
    }

    private async Task ProcessInputAsync(BootstrapInput input, JobRun stats)
    {
        var normalizedValue = _normalizer.Normalize(input.AliasType, input.AliasValue);
        if (string.IsNullOrEmpty(normalizedValue))
            return;

        if (input.OperationType == "DELETE")
        {
            await _aliases.SoftDeleteAsync(input.InsightTenantId, input.AliasType, normalizedValue, input.InsightSourceType);
            return;
        }

        // UPSERT path
        var existing = await _aliases.LookupAsync(input.InsightTenantId, input.AliasType, normalizedValue);

        if (existing is not null)
        {
            // Alias exists — update last_observed_at
            await _aliases.UpdateLastObservedAsync(input.InsightTenantId, input.AliasType, normalizedValue, input.InsightSourceId);
            stats.RowsAliasesUpdated++;
            return;
        }

        // No alias exists — try to find or create person
        var personId = await ResolvePersonIdAsync(input, normalizedValue, stats);
        if (personId is null)
            return; // Cannot resolve person for non-email alias types without existing person

        await _aliases.InsertAsync(new Alias
        {
            InsightTenantId = input.InsightTenantId,
            PersonId = personId.Value,
            AliasType = input.AliasType,
            AliasValue = normalizedValue,
            AliasFieldName = input.AliasFieldName,
            InsightSourceId = input.InsightSourceId,
            InsightSourceType = input.InsightSourceType,
            SourceAccountId = input.SourceAccountId,
            Confidence = 1.0f,
        });
        stats.RowsAliasesCreated++;
    }

    private async Task<Guid?> ResolvePersonIdAsync(BootstrapInput input, string normalizedValue, JobRun stats)
    {
        // Strategy 1: Look up person by email alias that already exists
        var emailAlias = await _aliases.LookupAsync(input.InsightTenantId, "email", normalizedValue);
        if (emailAlias is not null)
            return emailAlias.PersonId;

        // Strategy 2: For email type — look up person by email field directly
        if (input.AliasType == "email")
        {
            var person = await _persons.FindByEmailAsync(input.InsightTenantId, normalizedValue);
            if (person is not null)
                return person.Id;

            // No person found for this email — create one
            var newPersonId = await _persons.InsertAsync(
                input.InsightTenantId,
                displayName: "",
                email: normalizedValue,
                source: input.InsightSourceType);
            stats.RowsPersonsCreated++;
            return newPersonId;
        }

        // Strategy 3: For non-email types — try to find person via source_account_id
        // Look for any existing alias from same source + account that has a person
        var sourceAlias = await LookupBySourceAccountAsync(input);
        if (sourceAlias is not null)
            return sourceAlias.PersonId;

        // Cannot resolve — skip (MVP: no unmapped table yet)
        _logger.LogDebug("Cannot resolve person for {AliasType}:{AliasValue} from {Source} — skipping",
            input.AliasType, normalizedValue, input.InsightSourceType);
        return null;
    }

    private async Task<Alias?> LookupBySourceAccountAsync(BootstrapInput input)
    {
        // Find any existing alias from the same source+account that already has a person_id
        // This handles: platform_id and display_name aliases linking to person via same source_account_id
        var emailAlias = await _aliases.LookupAsync(input.InsightTenantId, "email",
            _normalizer.Normalize("email", input.AliasValue));

        // Fallback: not implemented in MVP (would need a query by source_account_id)
        return null;
    }
}
