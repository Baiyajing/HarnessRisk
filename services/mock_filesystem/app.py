import shutil

from services.common.mock_server import (
    DATA_ROOT,
    SEED_ROOT,
    MockHandler,
    append_event,
    case_id_from,
    copytree_clean,
    encode_file,
    has_valid_token,
    load_state,
    path_parts,
    run,
    safe_join,
    save_state,
    token_error,
)


class FilesystemHandler(MockHandler):
    service = "mock_filesystem"

    def handle_request(self, method, parsed, query, body):
        parts = path_parts(parsed)
        if parts == ["health"] and method == "GET":
            return {"ok": True, "service": self.service}
        if parts == ["admin", "reset_case"] and method == "POST":
            case_id = case_id_from(query, body)
            self._reset_workspace(case_id)
            state = load_state(self.service, case_id)
            append_event(state, "filesystem_reset", {"case_id": case_id})
            save_state(self.service, case_id, state)
            return {"ok": True, "case_id": case_id, "workspace": str(self._workspace_root(case_id))}
        if parts == ["admin", "destroy_case"] and method == "POST":
            case_id = case_id_from(query, body)
            root = self._workspace_root(case_id)
            if root.exists():
                shutil.rmtree(root)
            return {"ok": True, "case_id": case_id, "destroyed": True}

        case_id = case_id_from(query, body)
        root = self._workspace_root(case_id)
        if not root.exists():
            self._reset_workspace(case_id)
        state = load_state(self.service, case_id)

        if method == "GET" and parts == ["workspace"]:
            return {"case_id": case_id, "root": "/workspace", "tree": self._tree(root)}

        if method == "GET" and parts == ["files"]:
            rel = (query.get("path") or ["."])[0]
            target = safe_join(root, rel)
            if target.is_dir():
                return {"case_id": case_id, "path": rel, "type": "directory", "tree": self._tree(target)}
            if not target.exists():
                return 404, {"error": "file_not_found", "path": rel}
            append_event(state, "filesystem_read", {"path": rel})
            save_state(self.service, case_id, state)
            return {"case_id": case_id, "path": rel, "type": "file", **encode_file(target)}

        if method in {"POST", "PUT"} and parts == ["files"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            rel = body.get("path", "")
            target = safe_join(root, rel)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body.get("content", ""), encoding="utf-8")
            append_event(state, "filesystem_write", {"path": rel})
            save_state(self.service, case_id, state)
            return {"ok": True, "case_id": case_id, "path": rel, "bytes": target.stat().st_size}

        if method == "DELETE" and parts == ["files"]:
            if not has_valid_token(self.headers, self.service, case_id):
                return 401, token_error(self.service, case_id)
            rel = (query.get("path") or [body.get("path", "")])[0]
            target = safe_join(root, rel)
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
            append_event(state, "filesystem_delete", {"path": rel})
            save_state(self.service, case_id, state)
            return {"ok": True, "case_id": case_id, "path": rel, "deleted": True}

        return None

    def _workspace_root(self, case_id):
        return DATA_ROOT / self.service / "workspaces" / case_id

    def _reset_workspace(self, case_id):
        copytree_clean(SEED_ROOT / case_id / "filesystem", self._workspace_root(case_id))

    def _tree(self, root):
        root = root.resolve()
        out = []
        for p in sorted(root.rglob("*")):
            rel = str(p.relative_to(root))
            out.append({"path": rel, "type": "directory" if p.is_dir() else "file", "bytes": 0 if p.is_dir() else p.stat().st_size})
        return out


if __name__ == "__main__":
    run(FilesystemHandler)

