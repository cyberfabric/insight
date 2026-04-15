using Insight.Jobs.Domain.Models;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public interface IPersonRepository
{
    Task<Person?> FindByEmailAsync(Guid tenantId, string email);
    Task<Guid> InsertAsync(Guid tenantId, string displayName, string email, string source);
}
