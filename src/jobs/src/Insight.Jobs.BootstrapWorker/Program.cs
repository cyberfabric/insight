using Insight.Jobs.BootstrapWorker.Services;
using Insight.Jobs.Domain.Services;
using Insight.Jobs.Infrastructure.ClickHouse;
using Insight.Jobs.Infrastructure.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Serilog;

var configuration = new ConfigurationBuilder()
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: false)
    .AddEnvironmentVariables()
    .Build();

Log.Logger = new LoggerConfiguration()
    .ReadFrom.Configuration(configuration)
    .WriteTo.Console()
    .CreateLogger();

try
{
    Log.Information("BootstrapWorker starting");

    var services = new ServiceCollection();

    services.AddLogging(builder => builder.AddSerilog(dispose: true));

    var connectionString = configuration.GetConnectionString("ClickHouse")
        ?? throw new InvalidOperationException("ConnectionStrings:ClickHouse is required");

    var batchSize = configuration.GetValue("BootstrapJob:BatchSize", 10_000);

    services.AddSingleton(new ClickHouseConnectionFactory(connectionString));

    services.AddSingleton<IAliasNormalizer, AliasNormalizer>();
    services.AddSingleton<IBootstrapInputRepository, BootstrapInputRepository>();
    services.AddSingleton<IAliasRepository, AliasRepository>();
    services.AddSingleton<IPersonRepository, PersonRepository>();
    services.AddSingleton<IJobRunRepository, JobRunRepository>();

    services.AddSingleton(sp => new BootstrapJobService(
        sp.GetRequiredService<IBootstrapInputRepository>(),
        sp.GetRequiredService<IAliasRepository>(),
        sp.GetRequiredService<IPersonRepository>(),
        sp.GetRequiredService<IJobRunRepository>(),
        sp.GetRequiredService<IAliasNormalizer>(),
        sp.GetRequiredService<ILogger<BootstrapJobService>>(),
        batchSize));

    await using var provider = services.BuildServiceProvider();
    var job = provider.GetRequiredService<BootstrapJobService>();
    await job.ExecuteAsync();

    Log.Information("BootstrapWorker finished successfully");
    return 0;
}
catch (Exception ex)
{
    Log.Fatal(ex, "BootstrapWorker terminated with error");
    return 1;
}
finally
{
    await Log.CloseAndFlushAsync();
}
