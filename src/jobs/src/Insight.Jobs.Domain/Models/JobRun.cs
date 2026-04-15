namespace Insight.Jobs.Domain.Models;

public sealed class JobRun
{
    public Guid Id { get; set; }
    public string JobName { get; set; } = "";
    public Guid InsightTenantId { get; set; }
    public string State { get; set; } = "running";
    public DateTime StartedAt { get; set; }
    public DateTime FinishedAt { get; set; }
    public DateTime Watermark { get; set; }
    public ulong RowsProcessed { get; set; }
    public ulong RowsAliasesCreated { get; set; }
    public ulong RowsAliasesUpdated { get; set; }
    public ulong RowsPersonsCreated { get; set; }
    public string ErrorMessage { get; set; } = "";
}
