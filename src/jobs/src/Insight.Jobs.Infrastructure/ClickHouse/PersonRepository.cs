using ClickHouse.Client.ADO;
using ClickHouse.Client.Utility;
using Insight.Jobs.Domain.Models;
using Microsoft.Extensions.Logging;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public sealed class PersonRepository : IPersonRepository
{
    private readonly ClickHouseConnectionFactory _factory;
    private readonly ILogger<PersonRepository> _logger;

    public PersonRepository(ClickHouseConnectionFactory factory, ILogger<PersonRepository> logger)
    {
        _factory = factory;
        _logger = logger;
    }

    public async Task<Person?> FindByEmailAsync(Guid tenantId, string email)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT id, insight_tenant_id, display_name, email, status
            FROM person.persons FINAL
            WHERE insight_tenant_id = {tenant:UUID}
              AND lower(email) = {email:String}
              AND is_deleted = 0
            LIMIT 1
            """;
        cmd.AddParameter("tenant", tenantId);
        cmd.AddParameter("email", email);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            return null;

        return new Person
        {
            Id = reader.GetGuid(0),
            InsightTenantId = reader.GetGuid(1),
            DisplayName = reader.GetString(2),
            Email = reader.GetString(3),
            Status = reader.GetString(4),
        };
    }

    public async Task<Guid> InsertAsync(Guid tenantId, string displayName, string email, string source)
    {
        await using var conn = _factory.Create();
        await conn.OpenAsync();

        // Generate ID client-side so we can return it
        var personId = Guid.NewGuid(); // UUIDv7 not available in .NET; ClickHouse will use this

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO person.persons (
                id, insight_tenant_id, display_name, display_name_source,
                status, email, email_source, completeness_score,
                conflict_status, created_at, updated_at, is_deleted
            ) VALUES (
                {id:UUID}, {tenant:UUID}, {name:String}, {source:String},
                'active', {email:String}, {source:String},
                {score:Float32}, 'clean', now64(3), now64(3), 0
            )
            """;
        cmd.AddParameter("id", personId);
        cmd.AddParameter("tenant", tenantId);
        cmd.AddParameter("name", displayName);
        cmd.AddParameter("email", email);
        cmd.AddParameter("source", source);
        var score = ((!string.IsNullOrEmpty(displayName) ? 1 : 0) + (!string.IsNullOrEmpty(email) ? 1 : 0)) / 7.0f;
        cmd.AddParameter("score", score);

        await cmd.ExecuteNonQueryAsync();
        _logger.LogInformation("Created person {PersonId} for email {Email}", personId, email);
        return personId;
    }
}
