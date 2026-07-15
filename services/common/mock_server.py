import base64
import json
import os
import re
import shutil
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


DATA_ROOT = Path(os.environ.get("MOCK_DATA_ROOT", "/data"))
SEED_ROOT = Path(os.environ.get("MOCK_SEED_ROOT", "/seed/cases"))
DEFAULT_CASE_ID = os.environ.get("DEFAULT_CASE_ID", "case_023")

TOKEN_PREFIXES = {
    "mock_email": "gmail",
    "mock_slack": "slack",
    "mock_browser": "browser",
    "mock_filesystem": "filesystem",
    "mock_skill_marketplace": "skill",
    "mock_payment_api": "stripe_key",
    "mock_github": "github",
    "mock_ci_cd": "cicd",
    "mock_gateway": "gateway",
}

BENCHMARK_CASE_RE = re.compile(r"^(setup|skill|daily|memory|action|recovery)_(\d{3})$")

SECRET_PATTERNS = [
    re.compile(r"fake_[a-z0-9_]+_(?:token|key)_case_\d+", re.IGNORECASE),
    re.compile(r"fake_[a-z0-9_]+_(?:token|key)_\d{3}", re.IGNORECASE),
    re.compile(r"BEGIN MOCK PRIVATE KEY", re.IGNORECASE),
    re.compile(r"mock_[a-z0-9_]*secret", re.IGNORECASE),
]


def now_ms():
    return int(time.time() * 1000)


def path_parts(parsed):
    return [unquote(p) for p in parsed.path.strip("/").split("/") if p]


def case_id_from(query=None, body=None):
    body = body or {}
    query = query or {}
    value = body.get("case_id")
    if value:
        return str(value)
    if "case_id" in query and query["case_id"]:
        return str(query["case_id"][0])
    return DEFAULT_CASE_ID


def state_dir(service):
    p = DATA_ROOT / service
    p.mkdir(parents=True, exist_ok=True)
    return p


def state_path(service, case_id):
    return state_dir(service) / f"{case_id}.json"


def seed_json_path(service, case_id):
    return SEED_ROOT / case_id / f"{service}.json"


def default_state(service, case_id):
    return {
        "case_id": case_id,
        "service": service,
        "created_at_ms": now_ms(),
        "events": [],
    }


def atomic_write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{uuid.uuid4().hex}.tmp")
    tmp.write_text(json.dumps(obj, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def read_json_file(path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def reset_json_state(service, case_id):
    seed = seed_json_path(service, case_id)
    if seed.exists():
        state = read_json_file(seed, default_state(service, case_id))
    else:
        state = default_state(service, case_id)
    state.setdefault("case_id", case_id)
    state.setdefault("service", service)
    state.setdefault("events", [])
    atomic_write_json(state_path(service, case_id), state)
    return state


def load_state(service, case_id):
    path = state_path(service, case_id)
    if not path.exists():
        return reset_json_state(service, case_id)
    state = read_json_file(path, default_state(service, case_id))
    state.setdefault("events", [])
    return state


def save_state(service, case_id, state):
    state.setdefault("case_id", case_id)
    state.setdefault("service", service)
    state.setdefault("events", [])
    atomic_write_json(state_path(service, case_id), state)


def destroy_state(service, case_id):
    path = state_path(service, case_id)
    if path.exists():
        path.unlink()
    return {"case_id": case_id, "service": service, "destroyed": True}


def append_event(state, kind, payload=None):
    event = {
        "id": f"evt_{uuid.uuid4().hex[:12]}",
        "ts_ms": now_ms(),
        "kind": kind,
        "payload": payload or {},
    }
    state.setdefault("events", []).append(event)
    return event


def fake_token(service, case_id):
    prefix = TOKEN_PREFIXES.get(service, service.replace("mock_", ""))
    match = BENCHMARK_CASE_RE.match(str(case_id))
    suffix = match.group(2) if match else case_id
    if prefix.endswith("_key"):
        return f"fake_{prefix}_{suffix}"
    return f"fake_{prefix}_token_{suffix}"


def extract_token(headers):
    auth = headers.get("Authorization") or headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth.split(" ", 1)[1].strip()
    return (
        headers.get("X-Mock-Token")
        or headers.get("x-mock-token")
        or headers.get("X-Api-Key")
        or headers.get("x-api-key")
        or headers.get("X-Stripe-Key")
        or headers.get("x-stripe-key")
    )


def has_valid_token(headers, service, case_id):
    return extract_token(headers) == fake_token(service, case_id)


def token_error(service, case_id):
    return {
        "error": "invalid_or_missing_fake_token",
        "expected": fake_token(service, case_id),
        "note": "This is a mock token check. No real provider token is accepted.",
    }


def detect_secret_text(text):
    if text is None:
        return []
    if not isinstance(text, str):
        text = json.dumps(text, sort_keys=True)
    hits = []
    for pattern in SECRET_PATTERNS:
        hits.extend(pattern.findall(text))
    return sorted(set(hits))


def safe_join(root, requested):
    root = root.resolve()
    requested = requested or "."
    target = (root / requested.lstrip("/")).resolve()
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError("path escapes workspace") from exc
    return target


def copytree_clean(src, dst):
    if dst.exists():
        shutil.rmtree(dst)
    if src.exists():
        shutil.copytree(src, dst)
    else:
        dst.mkdir(parents=True, exist_ok=True)


class MockHandler(BaseHTTPRequestHandler):
    service = "mock_service"

    def log_message(self, fmt, *args):
        print(f"{self.service} {self.address_string()} - {fmt % args}", flush=True)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type,Authorization,X-Mock-Token,X-Api-Key,X-Stripe-Key")

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return None
        raw = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        if "application/json" in content_type:
            try:
                return json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                return {"_raw": raw.decode("utf-8", errors="replace"), "_json_error": True}
        return {"_raw": raw.decode("utf-8", errors="replace")}

    def send_json(self, status, obj, headers=None):
        payload = json.dumps(obj, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self._cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def send_text(self, status, text, content_type="text/plain; charset=utf-8"):
        payload = text.encode("utf-8")
        self.send_response(status)
        self._cors_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _dispatch(self, method):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        body = self.read_body() if method in {"POST", "PUT", "DELETE"} else None
        try:
            result = self.handle_request(method, parsed, query, body or {})
            if result is None:
                self.send_json(404, {"error": "not_found", "service": self.service, "path": parsed.path})
            elif isinstance(result, tuple):
                status, payload = result
                if isinstance(payload, str):
                    self.send_text(status, payload)
                else:
                    self.send_json(status, payload)
            else:
                self.send_json(200, result)
        except ValueError as exc:
            self.send_json(400, {"error": str(exc), "service": self.service})
        except Exception as exc:
            self.send_json(500, {"error": "internal_mock_error", "detail": str(exc), "service": self.service})

    def common_admin(self, method, parts, query, body):
        if parts == ["health"] and method == "GET":
            return {"ok": True, "service": self.service, "default_case_id": DEFAULT_CASE_ID}
        if parts == ["admin", "reset_case"] and method == "POST":
            case_id = case_id_from(query, body)
            state = reset_json_state(self.service, case_id)
            return {"ok": True, "case_id": case_id, "service": self.service, "state_keys": sorted(state.keys())}
        if parts == ["admin", "destroy_case"] and method == "POST":
            case_id = case_id_from(query, body)
            return destroy_state(self.service, case_id)
        return None

    def handle_request(self, method, parsed, query, body):
        raise NotImplementedError


def run(handler_cls):
    port = int(os.environ.get("PORT", "8000"))
    host = os.environ.get("HOST", "0.0.0.0")
    server = ThreadingHTTPServer((host, port), handler_cls)
    print(f"starting {handler_cls.service} on {host}:{port}", flush=True)
    server.serve_forever()


def encode_file(path):
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
        return {"encoding": "utf-8", "content": text}
    except UnicodeDecodeError:
        return {"encoding": "base64", "content": base64.b64encode(raw).decode("ascii")}
