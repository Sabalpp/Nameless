"""Bounded, isolated Codex CLI calls used by SeaForge walkers."""

import json;
import os;
import subprocess;
import tempfile;

glob MATERIAL_REVISION_SCHEMA: dict[str, any] = {
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
                "Aluminum5083"
            ]
        },
        "thickness_m": {
            "type": "number",
            "minimum": 0.003,
            "maximum": 0.015
        },
        "weld": {
            "type": "string",
            "enum": ["Economy", "Standard", "Premium"]
        },
        "seal": {
            "type": "string",
            "enum": ["Economy", "Commercial", "Marine"]
        },
        "reasoning": {"type": "string"}
    }
};

glob ROUTE_SCHEMA: dict[str, any] = {
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
                        "maximum": 90
                    },
                    "lon_deg": {
                        "type": "number",
                        "minimum": -180,
                        "maximum": 180
                    }
                }
            }
        },
        "reasoning": {"type": "string"}
    }
};

def _run_codex(
    prompt: str,
    schema: dict[str, any],
    task_name: str,
    model: str,
    timeout_s: int
) -> str {
    bounded_timeout = max(15, min(timeout_s, 300));
    with tempfile.TemporaryDirectory(
        prefix=f"seaforge-{task_name}-"
    ) as temp_dir {
        temp_path = temp_dir as str;
        schema_path: str = os.path.join(
            temp_path, "response.schema.json"
        );
        output_path: str = os.path.join(temp_path, "response.json");
        with open(schema_path, "w", encoding="utf-8") as schema_file {
            _ = schema_file.write(json.dumps(schema));
        }
        command: list[str] = [
            "codex",
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--cd",
            str(temp_dir),
            "--sandbox",
            "read-only",
            "--model",
            model,
            "--output-schema",
            schema_path,
            "--output-last-message",
            output_path,
            "--color",
            "never",
            "-"
        ];
        completed = subprocess.run(
            command,
            input=prompt,
            capture_output=True,
            cwd=temp_path,
            timeout=float(bounded_timeout),
            check=False,
            encoding="utf-8",
            errors="replace"
        );
        if completed.returncode != 0 {
            detail = (
                str(completed.stderr).strip()
                or str(completed.stdout).strip()
            );
            raise RuntimeError(
                f"codex {task_name} failed with status "
                f"{completed.returncode}: {detail[-1000:]}"
            );
        }
        if not os.path.exists(output_path) {
            raise RuntimeError(f"codex {task_name} produced no response");
        }
        with open(output_path, "r", encoding="utf-8") as output_file {
            raw = output_file.read() as str;
        }
        parsed = json.loads(raw);
        if not isinstance(parsed, dict) {
            raise RuntimeError(
                f"codex {task_name} returned a non-object"
            );
        }
        return json.dumps(parsed);
    }
}

def run_material_optimizer(
    prompt: str,
    model: str = "gpt-5.6-sol",
    timeout_s: int = 120
) -> str {
    return _run_codex(
        prompt,
        MATERIAL_REVISION_SCHEMA,
        "material-optimizer",
        model,
        timeout_s
    );
}

def run_route_planner(
    prompt: str,
    model: str = "gpt-5.6-sol",
    timeout_s: int = 120
) -> str {
    return _run_codex(
        prompt,
        ROUTE_SCHEMA,
        "route-planner",
        model,
        timeout_s
    );
}
