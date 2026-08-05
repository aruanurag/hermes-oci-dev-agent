#!/usr/bin/env python3
"""Fail fast unless the configured OCI model accepts streaming tool calls."""

from __future__ import annotations

import os

import httpx
from openai import OpenAI
from oci_genai_auth import OciInstancePrincipalAuth

region = os.environ["OCI_GENAI_REGION"]
project = os.environ["OCI_GENAI_PROJECT_OCID"]
model = os.environ["OCI_GENAI_MODEL_ID"]
client = OpenAI(
    base_url=f"https://inference.generativeai.{region}.oci.oraclecloud.com/openai/v1",
    api_key="not-used",
    project=project,
    http_client=httpx.Client(auth=OciInstancePrincipalAuth()),
)

stream = client.chat.completions.create(
    model=model,
    stream=True,
    messages=[{"role": "user", "content": "Call the ping tool exactly once."}],
    tools=[{
        "type": "function",
        "function": {
            "name": "ping",
            "description": "Returns a heartbeat.",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        },
    }],
)

chunks = list(stream)
if not chunks:
    raise RuntimeError("OCI Generative AI returned an empty stream")
print(f"OCI GenAI streaming tool-call smoke test passed for {model}")
