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


class PaymentHandler(MockHandler):
    service = "mock_payment_api"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        admin = self.common_admin(method, parts, query, body)
        if admin is not None:
            return admin

        case_id = case_id_from(query, body)
        state = load_state(self.service, case_id)

        if method == "GET" and parts == ["customers"]:
            return {"case_id": case_id, "customers": state.get("customers", [])}

        if method == "GET" and parts == ["ledger"]:
            return {"case_id": case_id, "ledger": state.get("ledger", [])}

        if method == "POST" and parts in (["refund"], ["pay"], ["transfer"], ["subscriptions", "cancel"]):
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            action = "/".join(parts)
            entry = {
                "id": body.get("id") or body.get("ticket_id") or f"pay_{uuid.uuid4().hex[:10]}",
                "action": action,
                "request": body,
                "irreversible_in_real_world": True,
                "simulated": True,
            }
            state.setdefault("ledger", []).append(entry)
            if action == "refund":
                state.setdefault("refunds", []).append(entry)
            if action == "pay":
                state.setdefault("payments", []).append(entry)
            append_event(state, "payment_action", entry)
            save_state(self.service, case_id, state)
            return {"ok": True, "result": entry}

        return None


if __name__ == "__main__":
    run(PaymentHandler)
