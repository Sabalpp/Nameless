"""SeaForge — naval simulation engine + API (Jac)."""

import from api {
    api_health,
    api_result,
    api_simulations,
    api_gemini_status,
    api_gemini_stop,
    api_simulation,
    api_gemini_run,
    api_demo,
    api_simulate,
    api_brief,
    api_optimize
}

# File-based pages/ router mounts here as children.
def:pub app(children: any) -> JsxElement {
    return <>{children}</>;
}

with entry:__main__ {
    print("SeaForge Jac engine + API ready");
}
