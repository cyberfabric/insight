"""GitHub authentication helpers."""


def auth_headers(token: str) -> dict:
    """Build authentication headers for GitHub API requests."""
    return {
        "Authorization": f"Bearer {token}",
        "User-Agent": "insight-github-connector/1.0",
    }


def rest_headers(token: str) -> dict:
    headers = auth_headers(token)
    headers["Accept"] = "application/vnd.github+json"
    headers["X-GitHub-Api-Version"] = "2022-11-28"
    return headers


def graphql_headers(token: str) -> dict:
    return auth_headers(token)
