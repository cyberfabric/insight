using Insight.Jobs.Domain.Models;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public interface IBootstrapInputRepository
{
    Task<IReadOnlyList<BootstrapInput>> GetUnprocessedAsync(DateTime watermark, int batchSize);
}
