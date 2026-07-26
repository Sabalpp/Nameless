"""Inspector for a selected learning-graph node."""

def _inspect_value(item: any, key: str, fallback: any = None) -> any {
    if item and item[key] {
        return item[key];
    }
    return fallback;
}

def:pub NodeInspector(selected: any) -> JsxElement {
    if not selected {
        return <aside className="inspector inspector--empty">
            <span className="eyebrow">NODE INSPECTOR</span>
            <div className="inspector-empty-icon">↗</div>
            <h2>Select a node</h2>
            <p>
                Click any decision, configuration, path, or outcome node to
                inspect exactly what the optimizer tried.
            </p>
        </aside>;
    }
    kind = str(_inspect_value(selected, "kind", "node"));
    details = _inspect_value(selected, "details", {});
    return <aside className="inspector">
        <div className="inspector-head">
            <div>
                <span className="eyebrow">{kind.upper()}</span>
                <h2>{str(_inspect_value(selected, "label", "Node"))}</h2>
            </div>
            <span className={"node-kind node-kind--" + kind}>{kind}</span>
        </div>
        <p className="inspector-meta">
            {str(_inspect_value(selected, "meta", ""))}
        </p>
        {if kind == "decision" {
            <div className="reasoning-block">
                <span>MODEL REASONING</span>
                <p>
                    {str(_inspect_value(
                        details,
                        "decision_reasoning",
                        "No reasoning was recorded for this local-rule decision."
                    ))}
                </p>
            </div>
        }}
        {if kind == "path" {
            <div className="waypoint-list">
                <span className="section-label">WAYPOINT CONDITIONS</span>
                {for point in _inspect_value(details, "path", []) {
                    <div
                        key={
                            str(_inspect_value(point, "sequence", 0))
                            + str(_inspect_value(point, "name", "point"))
                        }
                        className="waypoint-row"
                    >
                        <div>
                            <strong>{str(_inspect_value(point, "name", "Waypoint"))}</strong>
                            <small>
                                {str(_inspect_value(point, "lat_deg", "—"))}
                                {", "}
                                {str(_inspect_value(point, "lon_deg", "—"))}
                            </small>
                        </div>
                        <div className="condition-pills">
                            <span>
                                Hs {str(_inspect_value(point, "hs_m", "—"))} m
                            </span>
                            <span>
                                Wind {str(_inspect_value(point, "wind_speed_ms", "—"))} m/s
                            </span>
                        </div>
                    </div>
                }}
            </div>
        }}
        <span className="section-label">FULL NODE DATA</span>
        <pre className="json-view">
            {JSON.stringify(details, None, 2)}
        </pre>
    </aside>;
}
