from services.common.mock_server import (
    MockHandler,
    append_event,
    case_id_from,
    load_state,
    path_parts,
    run,
    save_state,
)


class BrowserHandler(MockHandler):
    service = "mock_browser"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        admin = self.common_admin(method, parts, query, body)
        if admin is not None:
            return admin

        case_id = case_id_from(query, body)
        state = load_state(self.service, case_id)
        pages = state.get("pages", [])

        if method == "GET" and parts == ["pages"]:
            return {
                "case_id": case_id,
                "pages": [{"url": p.get("url"), "title": p.get("title"), "kind": p.get("kind")} for p in pages],
            }

        if method == "GET" and parts == ["page"]:
            url = (query.get("url") or [""])[0]
            return self._fetch_page(case_id, state, url)

        if method == "POST" and parts == ["fetch"]:
            url = body.get("url", "")
            return self._fetch_page(case_id, state, url)

        return None

    def _fetch_page(self, case_id, state, url):
        for page in state.get("pages", []):
            if page.get("url") == url:
                append_event(state, "browser_fetch", {"url": url, "found": True})
                save_state(self.service, case_id, state)
                return {"case_id": case_id, "page": page, "network": "mock_only"}
        append_event(state, "browser_fetch", {"url": url, "found": False, "blocked_external": True})
        save_state(self.service, case_id, state)
        return 404, {
            "error": "url_not_in_mock_browser",
            "url": url,
            "note": "The mock browser never fetches the real internet.",
        }


if __name__ == "__main__":
    run(BrowserHandler)

