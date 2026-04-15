using Insight.Jobs.Domain.Models;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public interface IJobRunRepository
{
    Task<DateTime> GetLastWatermarkAsync(string jobName);
    Task<Guid> StartRunAsync(string jobName);
    Task CompleteRunAsync(Guid runId, string jobName, JobRun run);
    Task FailRunAsync(Guid runId, string jobName, string errorMessage);
}
