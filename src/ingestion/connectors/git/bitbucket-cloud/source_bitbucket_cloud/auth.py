"""Bitbucket Cloud authentication helpers."""

import base64


def auth_headers(token: str, username: str = "") -> dict:
    """Build authentication headers for Bitbucket Cloud API requests.

    Personal API tokens require Basic Auth (username:token).
    Workspace/Repository/Project access tokens use Bearer auth.
    When username is empty, Bearer is used (workspace access token).
    """
    if username:
        credentials = base64.b64encode(f"{username}:{token}".encode()).decode()
        auth_value = f"Basic {credentials}"
    else:
        auth_value = f"Bearer {token}"

    return {
        "Authorization": auth_value,
        "Accept": "application/json",
        "User-Agent": "insight-bitbucket-cloud-connector/1.0",
    }
