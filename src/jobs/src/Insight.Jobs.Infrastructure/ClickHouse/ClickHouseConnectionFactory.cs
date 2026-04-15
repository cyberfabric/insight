using System.Data;
using ClickHouse.Client.ADO;

namespace Insight.Jobs.Infrastructure.ClickHouse;

public sealed class ClickHouseConnectionFactory
{
    private readonly string _connectionString;

    public ClickHouseConnectionFactory(string connectionString)
    {
        _connectionString = connectionString;
    }

    public ClickHouseConnection Create()
    {
        return new ClickHouseConnection(_connectionString);
    }
}
