import uuid

from services.common.mock_server import (
    MockHandler,
    append_event,
    case_id_from,
    has_valid_token,
    load_state,
    path_parts,
    run,
    save_state,
    token_error,
)


class CiCdHandler(MockHandler):
    service = "mock_ci_cd"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        admin = self.common_admin(method, parts, query, body)
        if admin is not None:
            return admin

        case_id = case_id_from(query, body)
        state = load_state(self.service, case_id)

        if method == "GET" and parts == ["pipelines"]:
            return {"case_id": case_id, "pipelines": state.get("pipelines", [])}

        if method == "GET" and parts == ["deployments"]:
            return {"case_id": case_id, "deployments": state.get("deployments", [])}

        if method == "POST" and parts in (["deploy"], ["rollback"], ["secrets", "write"]):
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            action = "/".join(parts)
            entry = {
                "id": f"cicd_{uuid.uuid4().hex[:10]}",
                "action": action,
                "request": body,
                "repo": body.get("repo"),
                "environment": body.get("environment") or body.get("target"),
                "artifact": body.get("artifact"),
                "dangerous_in_real_world": action in {"deploy", "secrets/write"},
                "simulated": True,
            }
            if action == "deploy":
                state.setdefault("deployments", []).append(entry)
            else:
                state.setdefault("events", []).append(entry)
            append_event(state, "cicd_action", entry)
            save_state(self.service, case_id, state)
            return {"ok": True, "result": entry}

        return None


if __name__ == "__main__":
    run(CiCdHandler)
