#!/usr/bin/env python3
"""Loopback-only OCI IAM signing proxy for Hermes' OpenAI-compatible client."""

from __future__ import annotations

import os
from typing import Iterator

import httpx
from flask import Flask, Response, request
from oci_genai_auth import OciInstancePrincipalAuth

HOST = os.environ.get("OCI_GENAI_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("OCI_GENAI_PROXY_PORT", "8181"))
REGION = os.environ["OCI_GENAI_REGION"]
PROJECT = os.environ["OCI_GENAI_PROJECT_OCID"]
COMPARTMENT = os.environ["OCI_GENAI_COMPARTMENT_OCID"]
UPSTREAM = f"https://inference.generativeai.{REGION}.oci.oraclecloud.com/openai/v1"

app = Flask(__name__)


def _headers() -> dict[str, str]:
    """Forward only request metadata safe for a fixed local upstream."""
    selected = {"accept", "content-type", "openai-beta", "user-agent"}
    result = {k: v for k, v in request.headers.items() if k.lower() in selected}
    # OCI's OpenAI SDK uses the standard OpenAI project header.  The inference
    # service also requires the owning compartment for request routing.
    # Signing happens after both headers are attached by the IAM transport.
    result["OpenAI-Project"] = PROJECT
    result["opc-compartment-id"] = COMPARTMENT
    # The proxy streams raw bytes. Request an uncompressed response so Flask
    # can safely relay it without having to transform response content.
    result["Accept-Encoding"] = "identity"
    return result


@app.route("/healthz", methods=["GET"])
def healthz() -> tuple[dict[str, str], int]:
    return {"status": "ok"}, 200


@app.route("/v1/<path:path>", methods=["GET", "POST", "DELETE"])
def proxy(path: str) -> Response:
    url = f"{UPSTREAM}/{path}"
    client = httpx.Client(auth=OciInstancePrincipalAuth(), timeout=httpx.Timeout(300.0, connect=20.0))
    upstream = client.build_request(
        request.method, url, params=request.args, headers=_headers(), content=request.get_data()
    )
    response = client.send(upstream, stream=True)

    def body() -> Iterator[bytes]:
        try:
            yield from response.iter_raw()
        finally:
            response.close()
            client.close()

    excluded = {"content-encoding", "content-length", "transfer-encoding", "connection"}
    headers = [(k, v) for k, v in response.headers.items() if k.lower() not in excluded]
    return Response(body(), status=response.status_code, headers=headers)


if __name__ == "__main__":
    app.run(host=HOST, port=PORT, threaded=True, debug=False)
