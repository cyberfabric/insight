"""Authentication header builders for Bitbucket Cloud API."""

import base64


def rest_headers(username: str | None, token: str) -> dict:
    """Build request headers for Bitbucket Cloud REST API v2.0."""
    headers = {
        "Accept": "application/json",
        "User-Agent": "insight-bitbucket-cloud-connector/1.0",
    }
    if username:
        # App Password: Basic Auth
        creds = base64.b64encode(f"{username}:{token}".encode()).decode()
        headers["Authorization"] = f"Basic {creds}"
    else:
        # OAuth Bearer
        headers["Authorization"] = f"Bearer {token}"
    return headers
