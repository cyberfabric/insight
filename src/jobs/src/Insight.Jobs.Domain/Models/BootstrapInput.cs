namespace Insight.Jobs.Domain.Models;

public sealed class BootstrapInput
{
    public Guid Id { get; init; }
    public Guid InsightTenantId { get; init; }
    public Guid InsightSourceId { get; init; }
    public string InsightSourceType { get; init; } = "";
    public string SourceAccountId { get; init; } = "";
    public string AliasType { get; init; } = "";
    public string AliasValue { get; init; } = "";
    public string AliasFieldName { get; init; } = "";
    public string OperationType { get; init; } = "UPSERT";
    public DateTime SyncedAt { get; init; }
}
