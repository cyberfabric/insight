using Insight.Jobs.Domain.Models;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public interface IAliasRepository
{
    Task<Alias?> LookupAsync(Guid tenantId, string aliasType, string aliasValue);
    Task InsertAsync(Alias alias);
    Task UpdateLastObservedAsync(Guid tenantId, string aliasType, string aliasValue, Guid sourceId);
    Task SoftDeleteAsync(Guid tenantId, string aliasType, string aliasValue, string sourceType);
}
