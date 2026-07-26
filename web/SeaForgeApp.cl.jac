"""SeaForge mission control and realtime optimizer stream."""

import from .LearningGraph { LearningGraph }
import from .NodeInspector { NodeInspector }
sv import from ..engine.services {
    list_simulations,
    load_simulation
}

glob _socket: any = None;

def _payload_value(item: any, key: str, fallback: any = None) -> any {
    if item and item[key] {
        return item[key];
    }
    return fallback;
}

def _unwrap_message(raw: any) -> any {
    if raw and raw["data"] {
        data = raw["data"];
        raw_reports = data["reports"];
        reports: list[any] = (
            raw_reports as list[any]
            if isinstance(raw_reports, list)
            else []
        );
        if len(reports) > 0 {
            return reports[len(reports) - 1];
        }
        if data["result"] {
            return data["result"];
        }
    }
    if raw and raw["report"] {
        return raw["report"];
    }
    return raw;
}

def:pub SeaForgeApp() -> JsxElement {
    has origin_name: str = "Norfolk";
    has origin_lat: str = "36.8508";
    has origin_lon: str = "-76.2859";
    has destination_name: str = "Bermuda";
    has destination_lat: str = "32.3078";
    has destination_lon: str = "-64.7505";
    has route_iterations: str = "3";
    has material_iterations: str = "8";
    has use_codex: bool = True;
    has use_live_conditions: bool = False;
    has connection_state: str = "idle";
    has status_message: str = "Ready to launch a mission.";
    has mission_data: any = {};
    has iterations: list[any] = [];
    has selected_node: any = None;
    has saved_runs: list[any] = [];
    has selected_saved: str = "";

    async def refresh_saved() -> None {
        try {
            loaded_runs = await list_simulations();
            saved_runs = loaded_runs;
            if loaded_runs and not selected_saved {
                selected_saved = str(loaded_runs[0]["filename"]);
            }
        } except Exception {
            saved_runs = [];
        }
    }

    async can with entry {
        await refresh_saved();
    }

    can with exit {
        if _socket and _socket.readyState < 2 {
            _socket.close();
        }
    }

    def select_node(graph_node: any) -> None {
        selected_node = graph_node;
    }

    def stop_run(e: MouseEvent) -> None {
        if _socket and _socket.readyState < 2 {
            _socket.close();
        }
        connection_state = "stopped";
        status_message = "Stream stopped by user.";
    }

    def start_run(e: MouseEvent) -> None {
        if _socket and _socket.readyState < 2 {
            _socket.close();
        }
        connection_state = "connecting";
        status_message = "Opening realtime optimizer stream…";
        iterations = [];
        selected_node = None;
        mission_data = {
            "mission": origin_name + " → " + destination_name,
            "agent_backend": "codex-cli" if use_codex else "local-rules"
        };
        event_accumulator: list[any] = [];
        apply_payload = lambda(payload: any) {
            event_type = str(
                _payload_value(payload, "event_type", "")
            );
            if event_type == "session_started" {
                mission_data = payload;
                connection_state = "running";
                status_message = "Mission graph created.";
            } elif event_type == "progress" {
                status_message = str(
                    _payload_value(payload, "message", "Working…")
                );
            } elif event_type == "iteration" {
                iteration = _payload_value(payload, "iteration", {});
                event_accumulator = event_accumulator + [iteration];
                iterations = event_accumulator;
                status_message = (
                    str(_payload_value(payload, "phase", "iteration"))
                    + " "
                    + str(_payload_value(payload, "completed", 0))
                    + " of "
                    + str(_payload_value(payload, "total", 0))
                    + " added to graph"
                );
            } elif event_type == "route_locked" {
                status_message = str(
                    _payload_value(payload, "message", "Route locked.")
                );
            } elif event_type == "complete" {
                connection_state = str(
                    _payload_value(payload, "status", "complete")
                );
                status_message = str(
                    _payload_value(payload, "message", "Run complete.")
                );
                refresh_saved();
            }
        };
        protocol = (
            "wss:" if window.location.protocol == "https:" else "ws:"
        );
        socket_host = window.location.host;
        socket_url = (
            protocol
            + "//"
            + socket_host
            + "/ws/StreamOptimizeFromPoints"
        );
        _socket = new(WebSocket, socket_url) as any; # jac:ignore[E1053]
        _socket.onopen = lambda {
            connection_state = "running";
            status_message = "Connected. Waiting for the first decision…";
            _socket.send(JSON.stringify({
                "origin": {
                    "name": origin_name,
                    "lat_deg": float(origin_lat),
                    "lon_deg": float(origin_lon)
                },
                "destination": {
                    "name": destination_name,
                    "lat_deg": float(destination_lat),
                    "lon_deg": float(destination_lon)
                },
                "name": (
                    origin_name
                    + " to "
                    + destination_name
                    + " live "
                    + str(Date.now())
                ),
                "route_iterations": int(route_iterations),
                "material_iterations": int(material_iterations),
                "use_codex": use_codex,
                "use_live_conditions": use_live_conditions,
                "save_simulation": True,
                "stream_events": True
            }));
        };
        _socket.onmessage = lambda(message_event: any) {
            try {
                raw = JSON.parse(str(message_event.data));
                raw_data = _payload_value(raw, "data", {});
                raw_reports = _payload_value(raw_data, "reports", []);
                report_batch: list[any] = (
                    raw_reports as list[any]
                    if isinstance(raw_reports, list)
                    else [_unwrap_message(raw)]
                );
                for index in range(len(report_batch)) {
                    queued_payload = report_batch[index];
                    setTimeout(
                        lambda {
                            apply_payload(queued_payload);
                        },
                        index * 650
                    );
                }
            } except Exception as error {
                connection_state = "error";
                status_message = "Could not decode stream event: " + str(error);
            }
        };
        _socket.onerror = lambda(error: any) {
            connection_state = "error";
            status_message = "The WebSocket stream reported an error.";
        };
        _socket.onclose = lambda {
            if connection_state == "running" {
                connection_state = "closed";
                status_message = "Realtime stream closed.";
            }
        };
    }

    async def load_saved() -> None {
        if not selected_saved {
            return;
        }
        try {
            trace = await load_simulation(selected_saved);
            trace_mission = _payload_value(trace, "mission", {});
            optimizer = _payload_value(trace, "optimizer", {});
            mission_data = {
                "mission": _payload_value(
                    trace_mission, "name", selected_saved
                ),
                "mission_id": _payload_value(
                    trace_mission, "id", selected_saved
                ),
                "agent_backend": _payload_value(
                    optimizer, "backend", "saved"
                ),
                "codex_model": _payload_value(
                    optimizer, "model", ""
                ),
                "origin": _payload_value(trace_mission, "origin", {}),
                "destination": _payload_value(
                    trace_mission, "destination", {}
                )
            };
            raw_iterations = _payload_value(trace, "iterations", []);
            loaded_iterations: list[any] = (
                raw_iterations as list[any]
                if isinstance(raw_iterations, list)
                else []
            );
            iterations = loaded_iterations;
            selected_node = None;
            connection_state = "loaded";
            status_message = (
                "Loaded "
                + str(len(loaded_iterations))
                + " iterations from "
                + selected_saved
            );
        } except Exception as error {
            connection_state = "error";
            status_message = "Could not load simulation: " + str(error);
        }
    }

    return <main className="app-shell">
        <header className="topbar">
            <div className="brand">
                <div className="brand-mark">SF</div>
                <div>
                    <strong>SeaForge</strong>
                    <span>MISSION INTELLIGENCE</span>
                </div>
            </div>
            <div className={"connection connection--" + connection_state}>
                <i></i>
                <span>{connection_state.upper()}</span>
            </div>
        </header>

        <section className="hero">
            <div>
                <span className="eyebrow">GRAPH-NATIVE VESSEL OPTIMIZATION</span>
                <h1>Watch every decision become graph memory.</h1>
                <p>
                    Codex proposes. The Jac walker traverses. Every route,
                    configuration, and failure appears here the moment it
                    happens.
                </p>
            </div>
            <div className="live-status">
                <span>STREAM STATUS</span>
                <p>{status_message}</p>
            </div>
        </section>

        <section className="workspace">
            <aside className="control-panel">
                <div className="panel-heading">
                    <div>
                        <span className="eyebrow">MISSION INPUT</span>
                        <h2>Plot the voyage</h2>
                    </div>
                </div>
                <div className="point-card">
                    <div className="point-index">A</div>
                    <label>
                        Name
                        <input
                            value={origin_name}
                            onChange={lambda(e: ChangeEvent) {
                                origin_name = e.target.value;
                            }}
                        />
                    </label>
                    <div className="coordinate-row">
                        <label>
                            Latitude
                            <input
                                value={origin_lat}
                                onChange={lambda(e: ChangeEvent) {
                                    origin_lat = e.target.value;
                                }}
                            />
                        </label>
                        <label>
                            Longitude
                            <input
                                value={origin_lon}
                                onChange={lambda(e: ChangeEvent) {
                                    origin_lon = e.target.value;
                                }}
                            />
                        </label>
                    </div>
                </div>
                <div className="route-rail"><i></i><i></i><i></i></div>
                <div className="point-card">
                    <div className="point-index point-index--b">B</div>
                    <label>
                        Name
                        <input
                            value={destination_name}
                            onChange={lambda(e: ChangeEvent) {
                                destination_name = e.target.value;
                            }}
                        />
                    </label>
                    <div className="coordinate-row">
                        <label>
                            Latitude
                            <input
                                value={destination_lat}
                                onChange={lambda(e: ChangeEvent) {
                                    destination_lat = e.target.value;
                                }}
                            />
                        </label>
                        <label>
                            Longitude
                            <input
                                value={destination_lon}
                                onChange={lambda(e: ChangeEvent) {
                                    destination_lon = e.target.value;
                                }}
                            />
                        </label>
                    </div>
                </div>
                <div className="iteration-row">
                    <label>
                        Route attempts
                        <input
                            type="number"
                            min="1"
                            max="8"
                            value={route_iterations}
                            onChange={lambda(e: ChangeEvent) {
                                route_iterations = e.target.value;
                            }}
                        />
                    </label>
                    <label>
                        Material attempts
                        <input
                            type="number"
                            min="0"
                            max="50"
                            value={material_iterations}
                            onChange={lambda(e: ChangeEvent) {
                                material_iterations = e.target.value;
                            }}
                        />
                    </label>
                </div>
                <label className="toggle-row">
                    <span>
                        <strong>Codex optimizer</strong>
                        <small>Use your local Codex CLI</small>
                    </span>
                    <input
                        type="checkbox"
                        checked={use_codex}
                        onChange={lambda(e: ChangeEvent) {
                            use_codex = e.target.checked;
                        }}
                    />
                </label>
                <label className="toggle-row">
                    <span>
                        <strong>Live ocean data</strong>
                        <small>Open-Meteo marine conditions</small>
                    </span>
                    <input
                        type="checkbox"
                        checked={use_live_conditions}
                        onChange={lambda(e: ChangeEvent) {
                            use_live_conditions = e.target.checked;
                        }}
                    />
                </label>
                <div className="action-row">
                    <button
                        className="primary-button"
                        onClick={start_run}
                        disabled={
                            connection_state == "connecting"
                            or connection_state == "running"
                        }
                    >
                        <span>Start live optimization</span>
                        <b>→</b>
                    </button>
                    {if connection_state == "running" or connection_state == "connecting" {
                        <button className="stop-button" onClick={stop_run}>
                            Stop
                        </button>
                    }}
                </div>
                <div className="saved-runs">
                    <span className="section-label">SAVED SIMULATIONS</span>
                    <select
                        value={selected_saved}
                        onChange={lambda(e: ChangeEvent) {
                            selected_saved = e.target.value;
                        }}
                    >
                        {if len(saved_runs) == 0 {
                            <option value="">No simulations yet</option>
                        }}
                        {for run in saved_runs {
                            <option
                                key={str(run["filename"])}
                                value={str(run["filename"])}
                            >
                                {str(run["mission"])}
                                {" · "}
                                {str(run["iterations"])}
                                {" iterations"}
                            </option>
                        }}
                    </select>
                    <button className="secondary-button" onClick={load_saved}>
                        Load graph
                    </button>
                </div>
            </aside>

            <div className="visualization-column">
                <div className="stats-strip">
                    <div>
                        <span>ITERATIONS SEEN</span>
                        <strong>{str(len(iterations)).zfill(2)}</strong>
                    </div>
                    <div>
                        <span>BACKEND</span>
                        <strong>
                            {str(_payload_value(
                                mission_data, "agent_backend", "—"
                            ))}
                        </strong>
                    </div>
                    <div>
                        <span>MODEL</span>
                        <strong>
                            {str(_payload_value(
                                mission_data, "codex_model", "local"
                            )) or "local"}
                        </strong>
                    </div>
                    <div>
                        <span>GRAPH STATE</span>
                        <strong>{connection_state}</strong>
                    </div>
                </div>
                <LearningGraph
                    mission={mission_data}
                    iterations={iterations}
                    selected_id={
                        str(_payload_value(selected_node, "id", ""))
                    }
                    on_select={select_node}
                />
            </div>
            <NodeInspector selected={selected_node} />
        </section>
    </main>;
}
