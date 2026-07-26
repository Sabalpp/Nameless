"""CLI entry point matching Rust seaforge_v2 subcommands."""

import json;
import from pathlib { Path }
import from sys { argv }

import from engine.brief { cmd_brief }
import from engine.envelope { build_output }
import from engine.optimizer { run_optimizer, optimizer_as_ai_output, default_sweep }
import from engine.voyage { run_voyage }
import from engine.brief { default_sim_hull, default_sim_propulsion }
import from api {
    params_to_config_and_route,
    parse_vessel_config,
    parse_voyage_route,
    parse_search_space
}

def write_json(path: str, data: dict) {
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8");
}

def print_summary(outcome: any) {
    if outcome.failure is not None {
        d = outcome.failure;
        print(
            f"  ✗ FAILED — {d.mode.kind} at segment {d.segment_index} "
            + f"({d.distance_completed_nm:.0f} nm, {d.elapsed_h:.1f}h)"
        );
    } else {
        print(
            f"  ✓ SURVIVED — {outcome.distance_completed_nm:.0f} nm, "
            + f"{outcome.time_elapsed_h:.1f}h, fuel {outcome.fuel_remaining_kg:.0f} kg"
        );
    }
}

def load_json_file(path: str) -> dict[str, any] {
    text = Path(path).read_text(encoding="utf-8");
    return json.loads(text) as dict[str, any];
}

def cmd_simulate(config_path: str, route_path: str, out_path: str) {
    config = parse_vessel_config(load_json_file(config_path));
    route = parse_voyage_route(load_json_file(route_path));
    outcome = run_voyage(config, route);
    envelope = build_output(config, route, outcome, None);
    write_json(out_path, envelope);
    print(f"Simulation complete → {out_path}");
    print_summary(outcome);
}

def cmd_simulate_params(params_path: str, out_path: str) {
    params = load_json_file(params_path);
    (config, route) = params_to_config_and_route(params);
    outcome = run_voyage(config, route);
    envelope = build_output(config, route, outcome, None);
    write_json(out_path, envelope);
    print(f"Simulation complete → {out_path}");
    print_summary(outcome);
}

def cmd_optimize(space_path: str, route_path: str, out_path: str) {
    space = parse_search_space(load_json_file(space_path));
    route = parse_voyage_route(load_json_file(route_path));
    result = run_optimizer(space, route);
    envelope = optimizer_as_ai_output(result);
    write_json(out_path, envelope);
    print(f"Optimizer complete → {out_path}");
}

def cmd_demo(out_path: str) {
    hull = default_sim_hull();
    prop = default_sim_propulsion();
    space = default_sweep(hull, prop);
    route = parse_voyage_route(load_json_file("examples/voyage_route.json"));
    result = run_optimizer(space, route);
    envelope = optimizer_as_ai_output(result);
    write_json(out_path, envelope);
    print(f"Demo complete → {out_path}");
}

def main() {
    args = argv;
    if len(args) < 2 {
        cmd_demo("demo_output.json");
        return;
    }
    cmd = args[1];
    if cmd == "simulate" {
        cmd_simulate(args[2], args[3], args[4] if len(args) > 4 else "sim_output.json");
    } elif cmd == "simulate-params" {
        cmd_simulate_params(args[2], args[3] if len(args) > 3 else "sim_output.json");
    } elif cmd == "optimize" {
        cmd_optimize(args[2], args[3], args[4] if len(args) > 4 else "optimizer_output.json");
    } elif cmd == "brief" {
        tier = "standard";
        out_path = "brief_output.json";
        positional: list[str] = [];
        for a in args[3:] {
            if a.startswith("--tier=") {
                tier = a.split("=", 1)[1];
            } else {
                positional.append(a);
            }
        }
        if len(positional) > 0 {
            out_path = positional[0];
        }
        cmd_brief(args[2], out_path, tier);
    } elif cmd == "demo" {
        cmd_demo(args[2] if len(args) > 2 else "demo_output.json");
    } else {
        print(f"Unknown command: {cmd}");
        raise SystemExit(1);
    }
}

with entry:__main__ {
    main();
}
