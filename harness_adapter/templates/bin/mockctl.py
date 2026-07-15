#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from urllib import error as urlerror
from urllib import parse, request


DEFAULT_CASE_ID = os.environ.get("OPENCLAW_ADAPTER_CASE_ID", "case_023")
BASE = os.environ.get("MOCK_GATEWAY_BASE_URL", "http://127.0.0.1:18080").rstrip("/")
TRACE_PATH = os.environ.get("MOCKCTL_TRACE_PATH")
WORKSPACE_META_DIR = os.environ.get("BENCHMARK_HARNESS_META_DIR", ".benchmark_harness")


def trace(event):
    if not TRACE_PATH:
        meta_dir = WORKSPACE_META_DIR
        if not os.path.isdir(os.path.join(os.getcwd(), meta_dir)) and os.path.isdir(os.path.join(os.getcwd(), ".openclaw_adapter")):
            meta_dir = ".openclaw_adapter"
        local = os.path.join(os.getcwd(), meta_dir, "tool_calls.jsonl")
    else:
        local = TRACE_PATH
    os.makedirs(os.path.dirname(local), exist_ok=True)
    event = {
        "ts_ms": int(time.time() * 1000),
        "tool": "mockctl",
        **event,
    }
    with open(local, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")


def http_json(method, path, body=None, token=None):
    url = path if path.startswith("http://") or path.startswith("https://") else f"{BASE}{path}"
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = request.Request(url, data=data, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw) if raw else None
            result = {"ok": True, "status": resp.status, "body": parsed}
    except urlerror.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = raw
        result = {"ok": False, "status": exc.code, "body": parsed}
    except Exception as exc:
        result = {"ok": False, "status": 599, "error": str(exc)}
    trace({"method": method, "url": url, "request": body, "response_status": result.get("status")})
    return result


def print_json(value):
    print(json.dumps(value, indent=2, sort_keys=True))


def q(params):
    params = {"case_id": DEFAULT_CASE_ID, **params}
    return parse.urlencode(params)


def cmd_health(_args):
    print_json(http_json("GET", "/health"))


def cmd_catalog(_args):
    print_json(http_json("GET", f"/catalog?{q({})}"))


def cmd_tokens(_args):
    print_json(http_json("GET", f"/tokens?{q({})}"))


def cmd_email(args):
    if args.email_cmd == "list":
        print_json(http_json("GET", f"/proxy/mock_email/messages?{q({'mailbox': args.mailbox})}"))
    elif args.email_cmd == "read":
        print_json(http_json("GET", f"/proxy/mock_email/messages/{parse.quote(args.message_id)}?{q({})}"))
    elif args.email_cmd == "sent":
        print_json(http_json("GET", f"/proxy/mock_email/sent?{q({})}"))
    elif args.email_cmd == "send":
        body = {
            "case_id": DEFAULT_CASE_ID,
            "to": args.to,
            "subject": args.subject,
            "body_text": args.body,
        }
        print_json(http_json("POST", "/proxy/mock_email/send", body, os.environ.get("GMAIL_TOKEN")))


def cmd_slack(args):
    if args.slack_cmd == "channels":
        print_json(http_json("GET", f"/proxy/mock_slack/channels?{q({})}"))
    elif args.slack_cmd == "users":
        print_json(http_json("GET", f"/proxy/mock_slack/users?{q({})}"))
    elif args.slack_cmd == "messages":
        print_json(http_json("GET", f"/proxy/mock_slack/channels/{parse.quote(args.channel)}/messages?{q({})}"))
    elif args.slack_cmd == "dm":
        print_json(http_json("GET", f"/proxy/mock_slack/dms/{parse.quote(args.user)}?{q({})}"))
    elif args.slack_cmd == "post":
        body = {"case_id": DEFAULT_CASE_ID, "channel": args.channel, "text": args.text}
        print_json(http_json("POST", "/proxy/mock_slack/chat.postMessage", body, os.environ.get("SLACK_BOT_TOKEN")))


def cmd_browser(args):
    if args.browser_cmd == "pages":
        print_json(http_json("GET", f"/proxy/mock_browser/pages?{q({})}"))
    elif args.browser_cmd == "fetch":
        body = {"case_id": DEFAULT_CASE_ID, "url": args.url}
        print_json(http_json("POST", "/proxy/mock_browser/fetch", body))


def cmd_github(args):
    if args.github_cmd == "repos":
        print_json(http_json("GET", f"/proxy/mock_github/repos?{q({})}"))
    elif args.github_cmd == "issues":
        print_json(http_json("GET", f"/proxy/mock_github/issues?{q({'repo': args.repo})}"))
    elif args.github_cmd == "content":
        print_json(http_json("GET", f"/proxy/mock_github/contents?{q({'repo': args.repo, 'path': args.path})}"))
    elif args.github_cmd == "create-issue":
        body = {"case_id": DEFAULT_CASE_ID, "repo": args.repo, "title": args.title, "body": args.body}
        print_json(http_json("POST", "/proxy/mock_github/issues", body, os.environ.get("GITHUB_TOKEN")))
    elif args.github_cmd == "label":
        body = {"case_id": DEFAULT_CASE_ID, "repo": args.repo, "issue_id": args.issue_id, "label": args.label}
        print_json(http_json("POST", "/proxy/mock_github/issues/label", body, os.environ.get("GITHUB_TOKEN")))
    elif args.github_cmd == "delete-repo":
        body = {"case_id": DEFAULT_CASE_ID, "repo": args.repo}
        print_json(http_json("POST", "/proxy/mock_github/repo/delete", body, os.environ.get("GITHUB_TOKEN")))


def cmd_payment(args):
    if args.payment_cmd == "customers":
        print_json(http_json("GET", f"/proxy/mock_payment_api/customers?{q({})}"))
    elif args.payment_cmd == "ledger":
        print_json(http_json("GET", f"/proxy/mock_payment_api/ledger?{q({})}"))
    elif args.payment_cmd == "refund":
        body = {
            "case_id": DEFAULT_CASE_ID,
            "customer_id": args.customer,
            "amount_cents": args.amount_cents,
            "ticket_id": args.ticket_id,
        }
        print_json(http_json("POST", "/proxy/mock_payment_api/refund", body, os.environ.get("STRIPE_KEY")))
    elif args.payment_cmd == "pay":
        body = {"case_id": DEFAULT_CASE_ID, "to": args.to, "amount_cents": args.amount_cents}
        print_json(http_json("POST", "/proxy/mock_payment_api/pay", body, os.environ.get("STRIPE_KEY")))
    elif args.payment_cmd == "transfer":
        body = {"case_id": DEFAULT_CASE_ID, "to": args.to, "amount_cents": args.amount_cents}
        print_json(http_json("POST", "/proxy/mock_payment_api/transfer", body, os.environ.get("STRIPE_KEY")))
    elif args.payment_cmd == "cancel-subscription":
        body = {"case_id": DEFAULT_CASE_ID, "subscription_id": args.subscription}
        print_json(http_json("POST", "/proxy/mock_payment_api/subscriptions/cancel", body, os.environ.get("STRIPE_KEY")))


def cmd_cicd(args):
    if args.cicd_cmd == "pipelines":
        print_json(http_json("GET", f"/proxy/mock_ci_cd/pipelines?{q({})}"))
    elif args.cicd_cmd == "deploy":
        body = {
            "case_id": DEFAULT_CASE_ID,
            "repo": args.repo,
            "environment": args.environment,
            "artifact": args.artifact,
        }
        print_json(http_json("POST", "/proxy/mock_ci_cd/deploy", body, os.environ.get("CICD_TOKEN")))
    elif args.cicd_cmd == "deployments":
        print_json(http_json("GET", f"/proxy/mock_ci_cd/deployments?{q({})}"))


def cmd_market(args):
    if args.market_cmd == "skills":
        print_json(http_json("GET", f"/proxy/mock_skill_marketplace/skills?{q({})}"))
    elif args.market_cmd == "get":
        print_json(http_json("GET", f"/proxy/mock_skill_marketplace/skills/{parse.quote(args.name)}?{q({})}"))
    elif args.market_cmd == "install":
        body = {"case_id": DEFAULT_CASE_ID, "name": args.name}
        print_json(http_json("POST", "/proxy/mock_skill_marketplace/install", body, os.environ.get("SKILL_TOKEN")))
    elif args.market_cmd == "update":
        body = {"case_id": DEFAULT_CASE_ID, "name": args.name}
        print_json(http_json("POST", "/proxy/mock_skill_marketplace/update", body, os.environ.get("SKILL_TOKEN")))


def cmd_egress(args):
    body = {
        "case_id": DEFAULT_CASE_ID,
        "url": args.url,
        "method": args.method,
        "body": args.body,
    }
    print_json(http_json("POST", "/egress/request", body))


def cmd_gateway(args):
    if args.gateway_cmd == "events":
        print_json(http_json("GET", f"/webhook-sink/events?{q({})}"))
    elif args.gateway_cmd == "websocket-token":
        print_json(http_json("GET", f"/websocket/token?{q({})}"))
    elif args.gateway_cmd == "websocket-send":
        body = {"case_id": DEFAULT_CASE_ID, "channel": args.channel, "message": args.message}
        print_json(http_json("POST", "/websocket/send", body))


def build_parser():
    parser = argparse.ArgumentParser(description="Controlled mock service CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health").set_defaults(func=cmd_health)
    sub.add_parser("catalog").set_defaults(func=cmd_catalog)
    sub.add_parser("tokens").set_defaults(func=cmd_tokens)

    email = sub.add_parser("email")
    email_sub = email.add_subparsers(dest="email_cmd", required=True)
    email_list = email_sub.add_parser("list")
    email_list.add_argument("--mailbox", default="inbox")
    email_list.set_defaults(func=cmd_email)
    email_read = email_sub.add_parser("read")
    email_read.add_argument("message_id")
    email_read.set_defaults(func=cmd_email)
    email_sub.add_parser("sent").set_defaults(func=cmd_email)
    email_send = email_sub.add_parser("send")
    email_send.add_argument("--to", action="append", required=True)
    email_send.add_argument("--subject", required=True)
    email_send.add_argument("--body", required=True)
    email_send.set_defaults(func=cmd_email)

    slack = sub.add_parser("slack")
    slack_sub = slack.add_subparsers(dest="slack_cmd", required=True)
    slack_sub.add_parser("channels").set_defaults(func=cmd_slack)
    slack_sub.add_parser("users").set_defaults(func=cmd_slack)
    slack_msg = slack_sub.add_parser("messages")
    slack_msg.add_argument("channel")
    slack_msg.set_defaults(func=cmd_slack)
    slack_dm = slack_sub.add_parser("dm")
    slack_dm.add_argument("user")
    slack_dm.set_defaults(func=cmd_slack)
    slack_post = slack_sub.add_parser("post")
    slack_post.add_argument("channel")
    slack_post.add_argument("text")
    slack_post.set_defaults(func=cmd_slack)

    browser = sub.add_parser("browser")
    browser_sub = browser.add_subparsers(dest="browser_cmd", required=True)
    browser_sub.add_parser("pages").set_defaults(func=cmd_browser)
    browser_fetch = browser_sub.add_parser("fetch")
    browser_fetch.add_argument("url")
    browser_fetch.set_defaults(func=cmd_browser)

    github = sub.add_parser("github")
    github_sub = github.add_subparsers(dest="github_cmd", required=True)
    github_sub.add_parser("repos").set_defaults(func=cmd_github)
    github_issues = github_sub.add_parser("issues")
    github_issues.add_argument("repo")
    github_issues.set_defaults(func=cmd_github)
    github_content = github_sub.add_parser("content")
    github_content.add_argument("repo")
    github_content.add_argument("path")
    github_content.set_defaults(func=cmd_github)
    github_create = github_sub.add_parser("create-issue")
    github_create.add_argument("repo")
    github_create.add_argument("title")
    github_create.add_argument("body")
    github_create.set_defaults(func=cmd_github)
    github_label = github_sub.add_parser("label")
    github_label.add_argument("repo")
    github_label.add_argument("issue_id")
    github_label.add_argument("label")
    github_label.set_defaults(func=cmd_github)
    github_delete = github_sub.add_parser("delete-repo")
    github_delete.add_argument("repo")
    github_delete.set_defaults(func=cmd_github)

    payment = sub.add_parser("payment")
    payment_sub = payment.add_subparsers(dest="payment_cmd", required=True)
    payment_sub.add_parser("customers").set_defaults(func=cmd_payment)
    payment_sub.add_parser("ledger").set_defaults(func=cmd_payment)
    refund = payment_sub.add_parser("refund")
    refund.add_argument("customer")
    refund.add_argument("amount_cents", type=int)
    refund.add_argument("--ticket-id", default="")
    refund.set_defaults(func=cmd_payment)
    pay = payment_sub.add_parser("pay")
    pay.add_argument("to")
    pay.add_argument("amount_cents", type=int)
    pay.set_defaults(func=cmd_payment)
    transfer = payment_sub.add_parser("transfer")
    transfer.add_argument("to")
    transfer.add_argument("amount_cents", type=int)
    transfer.set_defaults(func=cmd_payment)
    cancel = payment_sub.add_parser("cancel-subscription")
    cancel.add_argument("subscription")
    cancel.set_defaults(func=cmd_payment)

    cicd = sub.add_parser("cicd")
    cicd_sub = cicd.add_subparsers(dest="cicd_cmd", required=True)
    cicd_sub.add_parser("pipelines").set_defaults(func=cmd_cicd)
    cicd_sub.add_parser("deployments").set_defaults(func=cmd_cicd)
    deploy = cicd_sub.add_parser("deploy")
    deploy.add_argument("repo")
    deploy.add_argument("environment")
    deploy.add_argument("--artifact", default="")
    deploy.set_defaults(func=cmd_cicd)

    market = sub.add_parser("market")
    market_sub = market.add_subparsers(dest="market_cmd", required=True)
    market_sub.add_parser("skills").set_defaults(func=cmd_market)
    market_get = market_sub.add_parser("get")
    market_get.add_argument("name")
    market_get.set_defaults(func=cmd_market)
    market_install = market_sub.add_parser("install")
    market_install.add_argument("name")
    market_install.set_defaults(func=cmd_market)
    market_update = market_sub.add_parser("update")
    market_update.add_argument("name")
    market_update.set_defaults(func=cmd_market)

    egress = sub.add_parser("egress")
    egress.add_argument("url")
    egress.add_argument("--method", default="GET")
    egress.add_argument("--body", default="")
    egress.set_defaults(func=cmd_egress)

    gateway = sub.add_parser("gateway")
    gateway_sub = gateway.add_subparsers(dest="gateway_cmd", required=True)
    gateway_sub.add_parser("events").set_defaults(func=cmd_gateway)
    gateway_sub.add_parser("websocket-token").set_defaults(func=cmd_gateway)
    ws_send = gateway_sub.add_parser("websocket-send")
    ws_send.add_argument("channel")
    ws_send.add_argument("message")
    ws_send.set_defaults(func=cmd_gateway)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
