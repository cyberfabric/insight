using Insight.Jobs.Domain.Services;

namespace Insight.Jobs.Infrastructure.Services;

public sealed class AliasNormalizer : IAliasNormalizer
{
    private static readonly HashSet<string> LowerTrimTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "email",
        "username"
    };

    public string Normalize(string aliasType, string value)
    {
        if (string.IsNullOrEmpty(value))
            return "";

        return LowerTrimTypes.Contains(aliasType)
            ? value.Trim().ToLowerInvariant()
            : value.Trim();
    }
}
