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


class GitHubHandler(MockHandler):
    service = "mock_github"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        admin = self.common_admin(method, parts, query, body)
        if admin is not None:
            return admin

        case_id = case_id_from(query, body)
        state = load_state(self.service, case_id)

        if method == "GET" and parts == ["repos"]:
            return {"case_id": case_id, "repos": state.get("repos", [])}

        if method == "GET" and parts == ["issues"]:
            repo = (query.get("repo") or [""])[0]
            issues = [i for i in state.get("issues", []) if i.get("repo") == repo]
            return {"case_id": case_id, "repo": repo, "issues": issues}

        if method == "GET" and parts == ["contents"]:
            repo = (query.get("repo") or [""])[0]
            path = (query.get("path") or ["README.md"])[0]
            key = f"{repo}:{path}"
            content = state.get("contents", {}).get(key)
            if content is None:
                return 404, {"error": "content_not_found", "repo": repo, "path": path}
            return {"case_id": case_id, "repo": repo, "path": path, "content": content}

        if method == "POST" and parts == ["issues"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            issue = {
                "id": f"issue_{uuid.uuid4().hex[:10]}",
                "repo": body.get("repo"),
                "title": body.get("title", ""),
                "body": body.get("body", ""),
                "author": body.get("author", "agent"),
                "simulated": True,
            }
            state.setdefault("issues", []).append(issue)
            append_event(state, "github_create_issue", issue)
            save_state(self.service, case_id, state)
            return {"ok": True, "issue": issue}

        if method == "POST" and parts == ["issues", "label"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            repo = body.get("repo", "")
            issue_id = body.get("issue_id")
            label = body.get("label", "")
            updated = None
            for issue in state.setdefault("issues", []):
                if str(issue.get("id")) == str(issue_id) and (not repo or issue.get("repo") == repo):
                    issue.setdefault("labels", [])
                    if label and label not in issue["labels"]:
                        issue["labels"].append(label)
                    updated = issue
                    break
            if updated is None:
                return 404, {"error": "issue_not_found", "repo": repo, "issue_id": issue_id}
            append_event(state, "github_label_issue", {"repo": repo, "issue_id": issue_id, "label": label})
            save_state(self.service, case_id, state)
            return {"ok": True, "issue": updated}

        if method == "POST" and parts == ["repo", "delete"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            repo = body.get("repo", "")
            entry = {"repo": repo, "dangerous_real_action": "repo_delete", "simulated": True}
            state.setdefault("deleted_repos", []).append(entry)
            append_event(state, "github_repo_delete", entry)
            save_state(self.service, case_id, state)
            return {"ok": True, "deleted": entry}

        return None


if __name__ == "__main__":
    run(GitHubHandler)
