"""Cost-versus-completion learning graph."""

def _value(item: any, key: str, fallback: any = None) -> any {
    if item and item[key] {
        return item[key];
    }
    return fallback;
}

def _number(value: any, fallback: float = 0.0) -> float {
    if isinstance(value, int) or isinstance(value, float) {
        return float(value);
    }
    return fallback;
}

def _short(value: float) -> str {
    return f"{value:.1f}";
}

def _make_scatter(iterations: list[any]) -> dict[str, any] {
    width = max(980, 240 + len(iterations) * 105);
    left = 105.0;
    right = float(width) - 80.0;
    top = 55.0;
    bottom = 540.0;
    costs: list[float] = [];
    for event in iterations {
        result = _value(event, "result", {});
        costs.append(_number(_value(result, "cost_usd", 0.0)));
    }
    minimum: float = 0.0;
    maximum: float = 1.0;
    found_cost: bool = False;
    for cost in costs {
        if cost > 0.0 {
            if not found_cost {
                minimum = cost;
                maximum = cost;
                found_cost = True;
            } else {
                if cost < minimum {
                    minimum = cost;
                }
                if cost > maximum {
                    maximum = cost;
                }
            }
        }
    }
    if maximum - minimum < 1.0 {
        minimum = max(0.0, minimum - 500.0);
        maximum = maximum + 500.0;
    }

    nodes: list[any] = [];
    edges: list[any] = [];
    for index in range(len(iterations)) {
        event = iterations[index];
        result = _value(event, "result", {});
        configuration = _value(event, "configuration", {});
        cost = _number(_value(result, "cost_usd", 0.0));
        completion = max(
            0.0,
            min(100.0, _number(_value(result, "distance_pct", 0.0)))
        );
        effective_cost = cost if cost > 0.0 else minimum;
        x = left + (
            (effective_cost - minimum) / (maximum - minimum)
        ) * (right - left);
        y = bottom - (completion / 100.0) * (bottom - top);
        survived = bool(_value(result, "survived", False));
        event_id = str(
            _value(event, "event_id", "attempt-" + str(index + 1))
        );
        graph_node = {
            "id": event_id,
            "kind": "attempt",
            "label": (
                str(_value(configuration, "material", "Unknown"))
                + " · "
                + str(_value(configuration, "thickness_mm", 0.0))
                + " mm"
            ),
            "meta": (
                "$"
                + _short(cost)
                + " · "
                + _short(completion)
                + "% complete"
            ),
            "x": x,
            "y": y,
            "cost": cost,
            "completion": completion,
            "survived": survived,
            "phase": str(_value(event, "phase", "iteration")),
            "attempt": index + 1,
            "details": event
        };
        nodes.append(graph_node);
        if index > 0 {
            prior = nodes[index - 1];
            edges.append({
                "x1": prior["x"],
                "y1": prior["y"],
                "x2": x,
                "y2": y
            });
        }
    }
    return {
        "nodes": nodes,
        "edges": edges,
        "width": width,
        "left": left,
        "right": right,
        "top": top,
        "bottom": bottom,
        "minimum": minimum,
        "maximum": maximum
    };
}

def:pub LearningGraph(
    mission: any,
    iterations: list[any],
    selected_id: str,
    on_select: Callable[[any], None]
) -> JsxElement {
    material_iterations = [
        event for event in iterations
        if str(_value(event, "phase", "")) == "material_search"
    ];
    graph: dict[str, any] = _make_scatter(material_iterations);
    nodes = graph["nodes"];
    edges = graph["edges"];
    width: float = _number(graph["width"], 980.0);
    left: float = _number(graph["left"], 105.0);
    right: float = _number(graph["right"], 900.0);
    top: float = _number(graph["top"], 55.0);
    bottom: float = _number(graph["bottom"], 540.0);
    minimum: float = _number(graph["minimum"], 0.0);
    maximum: float = _number(graph["maximum"], 1.0);

    return <section className="graph-panel">
        <div className="panel-heading">
            <div>
                <span className="eyebrow">OPTIMIZER KNOWLEDGE GRAPH</span>
                <h2>Cost vs. voyage completion</h2>
            </div>
            <div className="legend">
                <span><i className="legend-dot legend-dot--decision"></i>Attempt</span>
                <span><i className="legend-dot legend-dot--result"></i>Survived</span>
                <span><i className="legend-dot legend-dot--failed"></i>Failed</span>
            </div>
        </div>
        <div className="graph-scroll">
            <svg
                className="learning-graph scatter-graph"
                width={width}
                height="620"
                viewBox={"0 0 " + str(width) + " 620"}
            >
                {for percent in [0, 25, 50, 75, 100] {
                    <line
                        key={"grid-" + str(percent)}
                        className="scatter-grid"
                        x1={left}
                        y1={bottom - (float(percent) / 100.0) * (bottom - top)}
                        x2={right}
                        y2={bottom - (float(percent) / 100.0) * (bottom - top)}
                    />
                    <text
                        key={"ylabel-" + str(percent)}
                        className="axis-tick"
                        x={left - 18}
                        y={bottom - (float(percent) / 100.0) * (bottom - top) + 4}
                        textAnchor="end"
                    >
                        {str(percent) + "%"}
                    </text>
                }}
                <line className="scatter-axis" x1={left} y1={top} x2={left} y2={bottom} />
                <line className="scatter-axis" x1={left} y1={bottom} x2={right} y2={bottom} />
                <text
                    className="axis-title"
                    x={(left + right) / 2.0}
                    y="598"
                    textAnchor="middle"
                >
                    CONFIGURATION COST (USD)
                </text>
                <text
                    className="axis-title"
                    x="23"
                    y={(top + bottom) / 2.0}
                    textAnchor="middle"
                    transform={
                        "rotate(-90 23 "
                        + str((top + bottom) / 2.0)
                        + ")"
                    }
                >
                    VOYAGE COMPLETED
                </text>
                <text className="axis-tick" x={left} y={bottom + 24}>
                    {"$" + _short(minimum)}
                </text>
                <text
                    className="axis-tick"
                    x={right}
                    y={bottom + 24}
                    textAnchor="end"
                >
                    {"$" + _short(maximum)}
                </text>

                {for edge in edges {
                    <line
                        key={
                            str(edge["x1"])
                            + "-"
                            + str(edge["y1"])
                            + "-"
                            + str(edge["x2"])
                        }
                        className="attempt-edge"
                        x1={edge["x1"]}
                        y1={edge["y1"]}
                        x2={edge["x2"]}
                        y2={edge["y2"]}
                    />
                }}
                {for graph_node in nodes {
                    <g
                        key={str(graph_node["id"])}
                        className={
                            "scatter-node "
                            + (
                                "scatter-node--survived"
                                if graph_node["survived"]
                                else "scatter-node--failed"
                            )
                            + (
                                " scatter-node--selected"
                                if str(graph_node["id"]) == selected_id
                                else ""
                            )
                        }
                        transform={
                            "translate("
                            + str(graph_node["x"])
                            + ","
                            + str(graph_node["y"])
                            + ")"
                        }
                        onClick={lambda(e: MouseEvent) {
                            on_select(graph_node);
                        }}
                    >
                        <circle className="node-halo" r="19" />
                        <circle className="node-core" r="7" />
                        <text className="attempt-number" x="0" y="-27" textAnchor="middle">
                            {"#" + str(graph_node["attempt"])}
                        </text>
                        <text className="attempt-label" x="13" y="-4">
                            {str(graph_node["label"])}
                        </text>
                        <text className="attempt-meta" x="13" y="12">
                            {str(graph_node["meta"])}
                        </text>
                    </g>
                }}
                {if len(material_iterations) == 0 {
                    <text
                        className="graph-empty"
                        x={(left + right) / 2.0}
                        y={(top + bottom) / 2.0}
                        textAnchor="middle"
                    >
                        Start a run or load a saved simulation.
                    </text>
                }}
            </svg>
        </div>
    </section>;
}
