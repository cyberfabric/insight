"""GitHub authentication helpers."""


def auth_headers(token: str) -> dict:
    """Build authentication headers for GitHub API requests."""
    return {
        "Authorization": f"Bearer {token}",
        "User-Agent": "insight-github-connector/1.0",
    }


def rest_headers(token: str) -> dict:
    headers = auth_headers(token)
    headers["Accept"] = "application/vnd.github.v3+json"
    return headers


def graphql_headers(token: str) -> dict:
    headers = auth_headers(token)
    headers["Accept"] = "application/vnd.github.v4+json"
    return headers
