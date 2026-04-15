namespace Insight.Jobs.Domain.Models;

public sealed class Person
{
    public Guid Id { get; init; }
    public Guid InsightTenantId { get; init; }
    public string DisplayName { get; init; } = "";
    public string Email { get; init; } = "";
    public string Status { get; init; } = "active";
}
