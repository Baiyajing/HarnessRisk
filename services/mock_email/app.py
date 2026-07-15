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


class EmailHandler(MockHandler):
    service = "mock_email"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        admin = self.common_admin(method, parts, query, body)
        if admin is not None:
            return admin

        case_id = case_id_from(query, body)
        state = load_state(self.service, case_id)

        if method == "GET" and parts == ["messages"]:
            mailbox = (query.get("mailbox") or ["inbox"])[0]
            messages = [m for m in state.get("messages", []) if m.get("mailbox", "inbox") == mailbox]
            return {"case_id": case_id, "mailbox": mailbox, "messages": messages}

        if method == "GET" and len(parts) == 2 and parts[0] == "messages":
            message_id = parts[1]
            for msg in state.get("messages", []):
                if msg.get("id") == message_id:
                    return {"case_id": case_id, "message": msg}
            return 404, {"error": "message_not_found", "id": message_id}

        if method == "GET" and len(parts) == 4 and parts[0] == "attachments":
            message_id, filename = parts[1], parts[3]
            for msg in state.get("messages", []):
                if msg.get("id") == message_id:
                    for attachment in msg.get("attachments", []):
                        if attachment.get("filename") == filename:
                            return {"case_id": case_id, "message_id": message_id, "attachment": attachment}
            return 404, {"error": "attachment_not_found"}

        if method == "GET" and parts == ["sent"]:
            return {"case_id": case_id, "sent": state.get("sent", [])}

        if method == "POST" and parts == ["send"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            msg = {
                "id": f"sent_{uuid.uuid4().hex[:10]}",
                "case_id": case_id,
                "mailbox": "sent",
                "to": body.get("to", []),
                "cc": body.get("cc", []),
                "subject": body.get("subject", ""),
                "body_text": body.get("body_text", ""),
                "body_html": body.get("body_html", ""),
                "attachments": body.get("attachments", []),
                "simulated": True,
            }
            state.setdefault("sent", []).append(msg)
            append_event(state, "email_send", {"message": msg})
            save_state(self.service, case_id, state)
            return {"ok": True, "queued": True, "message": msg}

        if method == "POST" and parts == ["receive"]:
            msg = {
                "id": body.get("id") or f"msg_{uuid.uuid4().hex[:10]}",
                "case_id": case_id,
                "mailbox": body.get("mailbox", "inbox"),
                "from": body.get("from", "sender@example.mock"),
                "to": body.get("to", ["agent@example.mock"]),
                "subject": body.get("subject", ""),
                "body_text": body.get("body_text", ""),
                "body_html": body.get("body_html", ""),
                "attachments": body.get("attachments", []),
                "headers": body.get("headers", {}),
            }
            state.setdefault("messages", []).append(msg)
            append_event(state, "email_receive", {"message_id": msg["id"]})
            save_state(self.service, case_id, state)
            return {"ok": True, "message": msg}

        return None


if __name__ == "__main__":
    run(EmailHandler)

