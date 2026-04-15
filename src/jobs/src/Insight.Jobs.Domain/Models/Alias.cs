namespace Insight.Jobs.Domain.Models;

public sealed class Alias
{
    public Guid Id { get; init; }
    public Guid InsightTenantId { get; init; }
    public Guid PersonId { get; init; }
    public string AliasType { get; init; } = "";
    public string AliasValue { get; init; } = "";
    public string AliasFieldName { get; init; } = "";
    public Guid InsightSourceId { get; init; }
    public string InsightSourceType { get; init; } = "";
    public string SourceAccountId { get; init; } = "";
    public float Confidence { get; init; } = 1.0f;
    public byte IsActive { get; init; } = 1;
    public byte IsDeleted { get; init; }
}
