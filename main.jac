"""SeaForge full-stack entrypoint."""

import from engine.orchestrator {
    OptimizeFromPoints,
    StreamOptimizeFromPoints,
    SetupMission,
    RunVoyage,
    RunOptimizer,
    GetMission,
    MissionGraphDot
}
import from engine.services {
    list_simulations,
    load_simulation
}

cl {
    import ".web/styles.global.css";
    import from .web.SeaForgeApp { SeaForgeApp }

    def:pub app() -> JsxElement {
        return <SeaForgeApp />;
    }
}
