"""Bounded Codex CLI runner used by the Jac optimization walker."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


REVISION_SCHEMA = {
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


def run_codex_optimizer(
    prompt: str,
    model: str = "gpt-5.6-sol",
    timeout_s: int = 120,
) -> str:
    """Run one ephemeral, read-only Codex process and return its final JSON."""
    bounded_timeout = max(15, min(timeout_s, 300))
    with tempfile.TemporaryDirectory(prefix="seaforge-codex-") as temp_dir:
        temp_path = Path(temp_dir)
        schema_path = temp_path / "revision.schema.json"
        output_path = temp_path / "revision.json"
        schema_path.write_text(json.dumps(REVISION_SCHEMA), encoding="utf-8")

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
                f"codex exec failed with status {completed.returncode}: "
                f"{detail[-1000:]}"
            )
        if not output_path.exists():
            raise RuntimeError("codex exec did not produce a final response")

        raw = output_path.read_text(encoding="utf-8").strip()
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            raise RuntimeError("codex exec returned a non-object response")
        return json.dumps(parsed)
