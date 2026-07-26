"""Bounded, isolated Codex CLI calls used by SeaForge walkers."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


MATERIAL_REVISION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["material", "thickness_m", "weld", "seal", "reasoning"],
    "properties": {
        "material": {
            "type": "string",
            "enum": [
                "MildSteelA",
                "MildSteelE",
                "Ah36",
                "Dh36",
                "Eh36",
                "Eh40",
                "Aluminum5083",
            ],
        },
        "thickness_m": {
            "type": "number",
            "minimum": 0.003,
            "maximum": 0.015,
        },
        "weld": {
            "type": "string",
            "enum": ["Economy", "Standard", "Premium"],
        },
        "seal": {
            "type": "string",
            "enum": ["Economy", "Commercial", "Marine"],
        },
        "reasoning": {"type": "string"},
    },
}

ROUTE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["waypoints", "reasoning"],
    "properties": {
        "waypoints": {
            "type": "array",
            "minItems": 0,
            "maxItems": 10,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name", "lat_deg", "lon_deg"],
                "properties": {
                    "name": {"type": "string"},
                    "lat_deg": {
                        "type": "number",
                        "minimum": -90,
                        "maximum": 90,
                    },
                    "lon_deg": {
                        "type": "number",
                        "minimum": -180,
                        "maximum": 180,
                    },
                },
            },
        },
        "reasoning": {"type": "string"},
    },
}


def _run_codex(
    prompt: str,
    schema: dict[str, object],
    task_name: str,
    model: str,
    timeout_s: int,
) -> str:
    bounded_timeout = max(15, min(timeout_s, 300))
    with tempfile.TemporaryDirectory(
        prefix=f"seaforge-{task_name}-"
    ) as temp_dir:
        temp_path = Path(temp_dir)
        schema_path = temp_path / "response.schema.json"
        output_path = temp_path / "response.json"
        schema_path.write_text(json.dumps(schema), encoding="utf-8")
        command = [
            "codex",
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--cd",
            str(temp_path),
            "--sandbox",
            "read-only",
            "--model",
            model,
            "--output-schema",
            str(schema_path),
            "--output-last-message",
            str(output_path),
            "--color",
            "never",
            "-",
        ]
        completed = subprocess.run(
            command,
            input=prompt,
            text=True,
            capture_output=True,
            cwd=temp_path,
            timeout=bounded_timeout,
            check=False,
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(
                f"codex {task_name} failed with status "
                f"{completed.returncode}: {detail[-1000:]}"
            )
        if not output_path.exists():
            raise RuntimeError(f"codex {task_name} produced no response")
        parsed = json.loads(output_path.read_text(encoding="utf-8"))
        if not isinstance(parsed, dict):
            raise RuntimeError(f"codex {task_name} returned a non-object")
        return json.dumps(parsed)


def run_material_optimizer(
    prompt: str,
    model: str = "gpt-5.6-sol",
    timeout_s: int = 120,
) -> str:
    """Choose one vessel configuration using strict structured output."""
    return _run_codex(
        prompt,
        MATERIAL_REVISION_SCHEMA,
        "material-optimizer",
        model,
        timeout_s,
    )


def run_route_planner(
    prompt: str,
    model: str = "gpt-5.6-sol",
    timeout_s: int = 120,
) -> str:
    """Choose intermediate geographic waypoints using structured output."""
    return _run_codex(
        prompt,
        ROUTE_SCHEMA,
        "route-planner",
        model,
        timeout_s,
    )
