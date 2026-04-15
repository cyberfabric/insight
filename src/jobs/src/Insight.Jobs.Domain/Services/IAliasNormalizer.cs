namespace Insight.Jobs.Domain.Services;

public interface IAliasNormalizer
{
    string Normalize(string aliasType, string value);
}
