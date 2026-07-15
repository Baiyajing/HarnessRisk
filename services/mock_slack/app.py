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


class SlackHandler(MockHandler):
    service = "mock_slack"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        admin = self.common_admin(method, parts, query, body)
        if admin is not None:
            return admin

        case_id = case_id_from(query, body)
        state = load_state(self.service, case_id)

        if method == "GET" and parts == ["users"]:
            return {"case_id": case_id, "users": state.get("users", [])}

        if method == "GET" and parts == ["channels"]:
            return {"case_id": case_id, "channels": state.get("channels", [])}

        if method == "GET" and len(parts) == 3 and parts[0] == "channels" and parts[2] == "messages":
            channel_id = parts[1]
            messages = [m for m in state.get("messages", []) if m.get("channel") == channel_id]
            return {"case_id": case_id, "channel": channel_id, "messages": messages}

        if method == "GET" and len(parts) == 2 and parts[0] == "dms":
            user_id = parts[1]
            messages = [m for m in state.get("messages", []) if user_id in m.get("dm_members", [])]
            return {"case_id": case_id, "user_id": user_id, "messages": messages}

        if method == "POST" and parts == ["chat.postMessage"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            msg = {
                "id": f"slack_{uuid.uuid4().hex[:10]}",
                "channel": body.get("channel"),
                "user": body.get("user", "U_AGENT"),
                "text": body.get("text", ""),
                "dm_members": body.get("dm_members", []),
                "simulated": True,
            }
            state.setdefault("messages", []).append(msg)
            append_event(state, "slack_post_message", msg)
            save_state(self.service, case_id, state)
            return {"ok": True, "message": msg}

        if method == "POST" and parts == ["admin", "impersonate_message"]:
            msg = {
                "id": f"imp_{uuid.uuid4().hex[:10]}",
                "channel": body.get("channel", "C_GENERAL"),
                "user": body.get("user", "U_ADMIN"),
                "text": body.get("text", ""),
                "impersonated": True,
                "display_name": body.get("display_name", "Workspace Admin"),
                "dm_members": body.get("dm_members", []),
            }
            state.setdefault("messages", []).append(msg)
            append_event(state, "slack_impersonated_message", msg)
            save_state(self.service, case_id, state)
            return {"ok": True, "message": msg}

        return None


if __name__ == "__main__":
    run(SlackHandler)

