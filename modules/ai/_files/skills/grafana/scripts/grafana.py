#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "httpx>=0.27",
# ]
# [tool.uv]
# exclude-newer = "2025-06-01T00:00:00Z"
# ///
"""Grafana API CLI — manage dashboards, folders, datasources, annotations, and alerting."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any
import httpx

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

class GrafanaClient:
    """Thin HTTP wrapper around the Grafana REST API."""

    def __init__(self, base_url: str, token: str, org_id: int | None = None, timeout: float = 30.0):
        self.base_url = base_url.rstrip("/")
        headers: dict[str, str] = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if org_id:
            headers["X-Grafana-Org-Id"] = str(org_id)
        self._client = httpx.Client(headers=headers, timeout=timeout)

    # -- low-level --------------------------------------------------------

    def _request(self, method: str, endpoint: str, *, params: dict | None = None, json_body: Any = None) -> Any:
        url = f"{self.base_url}{endpoint}"
        resp = self._client.request(method, url, params=params, json=json_body)
        try:
            data = resp.json()
        except Exception:
            data = {"message": resp.text}
        if not resp.is_success:
            msg = data.get("message", resp.text) if isinstance(data, dict) else resp.text
            print(f"ERROR [{resp.status_code}]: {msg}", file=sys.stderr)
            sys.exit(1)
        return data

    def get(self, endpoint: str, **kwargs: Any) -> Any:
        return self._request("GET", endpoint, **kwargs)

    def post(self, endpoint: str, **kwargs: Any) -> Any:
        return self._request("POST", endpoint, **kwargs)

    def put(self, endpoint: str, **kwargs: Any) -> Any:
        return self._request("PUT", endpoint, **kwargs)

    def delete(self, endpoint: str, **kwargs: Any) -> Any:
        return self._request("DELETE", endpoint, **kwargs)

    def patch(self, endpoint: str, **kwargs: Any) -> Any:
        return self._request("PATCH", endpoint, **kwargs)

    # -- health -----------------------------------------------------------

    def health(self) -> dict:
        return self.get("/api/health")

    # -- dashboards -------------------------------------------------------

    def search_dashboards(self, query: str | None = None, tag: str | None = None,
                          folder_uid: str | None = None, limit: int = 100) -> list[dict]:
        params: dict[str, Any] = {"type": "dash-db", "limit": limit}
        if query:
            params["query"] = query
        if tag:
            params["tag"] = tag
        if folder_uid:
            params["folderUIDs"] = folder_uid
        return self.get("/api/search", params=params)

    def get_dashboard(self, uid: str) -> dict:
        return self.get(f"/api/dashboards/uid/{uid}")

    def save_dashboard(self, dashboard: dict, folder_uid: str | None = None,
                       message: str = "", overwrite: bool = False) -> dict:
        body: dict[str, Any] = {"dashboard": dashboard, "overwrite": overwrite}
        if folder_uid:
            body["folderUid"] = folder_uid
        if message:
            body["message"] = message
        return self.post("/api/dashboards/db", json_body=body)

    def delete_dashboard(self, uid: str) -> dict:
        return self.delete(f"/api/dashboards/uid/{uid}")

    def get_dashboard_versions(self, uid: str, limit: int = 20) -> list[dict]:
        return self.get(f"/api/dashboards/uid/{uid}/versions", params={"limit": limit})

    def restore_dashboard_version(self, uid: str, version: int) -> dict:
        return self.post(f"/api/dashboards/uid/{uid}/restore", json_body={"version": version})

    # -- folders ----------------------------------------------------------

    def list_folders(self, limit: int = 1000) -> list[dict]:
        return self.get("/api/folders", params={"limit": limit})

    def get_folder(self, uid: str) -> dict:
        return self.get(f"/api/folders/{uid}")

    def create_folder(self, title: str, uid: str | None = None, parent_uid: str | None = None) -> dict:
        body: dict[str, Any] = {"title": title}
        if uid:
            body["uid"] = uid
        if parent_uid:
            body["parentUid"] = parent_uid
        return self.post("/api/folders", json_body=body)

    def delete_folder(self, uid: str, force_delete_rules: bool = False) -> dict:
        return self.delete(f"/api/folders/{uid}", params={"forceDeleteRules": force_delete_rules})

    # -- datasources ------------------------------------------------------

    def list_datasources(self) -> list[dict]:
        return self.get("/api/datasources")

    def get_datasource(self, uid: str) -> dict:
        return self.get(f"/api/datasources/uid/{uid}")

    def health_check_datasource(self, uid: str) -> dict:
        return self.get(f"/api/datasources/uid/{uid}/health")

    # -- annotations ------------------------------------------------------

    def query_annotations(self, dashboard_uid: str | None = None, tags: list[str] | None = None,
                          limit: int = 100) -> list[dict]:
        params: dict[str, Any] = {"limit": limit}
        if dashboard_uid:
            params["dashboardUID"] = dashboard_uid
        if tags:
            params["tags"] = tags
        return self.get("/api/annotations", params=params)

    def create_annotation(self, text: str, tags: list[str] | None = None,
                          dashboard_uid: str | None = None, time_ms: int | None = None,
                          time_end_ms: int | None = None) -> dict:
        import time as _time
        body: dict[str, Any] = {"text": text, "time": time_ms or int(_time.time() * 1000)}
        if tags:
            body["tags"] = tags
        if dashboard_uid:
            body["dashboardUID"] = dashboard_uid
        if time_end_ms:
            body["timeEnd"] = time_end_ms
        return self.post("/api/annotations", json_body=body)

    def delete_annotation(self, annotation_id: int) -> dict:
        return self.delete(f"/api/annotations/{annotation_id}")

    # -- alerting ---------------------------------------------------------

    def list_alert_rules(self) -> list[dict]:
        return self.get("/api/v1/provisioning/alert-rules")

    def get_alert_rule(self, uid: str) -> dict:
        return self.get(f"/api/v1/provisioning/alert-rules/{uid}")

    def list_contact_points(self) -> list[dict]:
        return self.get("/api/v1/provisioning/contact-points")

    def get_notification_policies(self) -> dict:
        return self.get("/api/v1/provisioning/policies")

    def get_active_alerts(self) -> list[dict]:
        return self.get("/api/alertmanager/grafana/api/v2/alerts")

    # -- users / org ------------------------------------------------------

    def get_current_user(self) -> dict:
        return self.get("/api/user")

    def get_current_org(self) -> dict:
        return self.get("/api/org")


# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------

def _pp(data: Any) -> None:
    """Pretty-print JSON."""
    print(json.dumps(data, indent=2, ensure_ascii=False))


def cmd_health(client: GrafanaClient, _args: list[str]) -> None:
    _pp(client.health())


def cmd_list(client: GrafanaClient, args: list[str]) -> None:
    """List dashboards. Flags: --query <q>, --tag <t>, --folder <uid>, --limit <n>, --json"""
    query = tag = folder_uid = None
    limit = 100
    as_json = False
    i = 0
    while i < len(args):
        if args[i] == "--query" and i + 1 < len(args):
            query = args[i + 1]; i += 2
        elif args[i] == "--tag" and i + 1 < len(args):
            tag = args[i + 1]; i += 2
        elif args[i] == "--folder" and i + 1 < len(args):
            folder_uid = args[i + 1]; i += 2
        elif args[i] == "--limit" and i + 1 < len(args):
            limit = int(args[i + 1]); i += 2
        elif args[i] == "--json":
            as_json = True; i += 1
        else:
            i += 1

    results = client.search_dashboards(query=query, tag=tag, folder_uid=folder_uid, limit=limit)
    if as_json:
        _pp(results)
    else:
        print(f"\nDashboards ({len(results)}):\n" + "-" * 72)
        for d in results:
            tags = f" [{', '.join(d.get('tags', []))}]" if d.get("tags") else ""
            folder = f" ({d.get('folderTitle', '')})" if d.get("folderTitle") else ""
            print(f"  {d['uid']:20s}  {d['title']}{folder}{tags}")
        print("-" * 72)


def cmd_get(client: GrafanaClient, args: list[str]) -> None:
    """Get dashboard by UID. Usage: get <uid> [--json]"""
    if not args:
        print("Usage: get <uid> [--json]", file=sys.stderr); sys.exit(1)
    uid = args[0]
    as_json = "--json" in args
    result = client.get_dashboard(uid)
    if as_json:
        _pp(result)
    else:
        meta = result.get("meta", {})
        dash = result.get("dashboard", {})
        print(f"\nDashboard: {dash.get('title', '?')}\n" + "-" * 72)
        print(f"  UID:      {dash.get('uid')}")
        print(f"  Version:  {meta.get('version')}")
        print(f"  Folder:   {meta.get('folderTitle', 'General')}")
        print(f"  URL:      {meta.get('url')}")
        print(f"  Updated:  {meta.get('updated')}")
        print(f"  Panels:   {len(dash.get('panels', []))}")
        if dash.get("tags"):
            print(f"  Tags:     {', '.join(dash['tags'])}")
        print("-" * 72)


def cmd_export(client: GrafanaClient, args: list[str]) -> None:
    """Export dashboard JSON. Usage: export <uid> [--output <path>]"""
    if not args:
        print("Usage: export <uid> [--output <path>]", file=sys.stderr); sys.exit(1)
    uid = args[0]
    output = None
    if "--output" in args:
        idx = args.index("--output")
        output = args[idx + 1] if idx + 1 < len(args) else None
    result = client.get_dashboard(uid)
    out_path = output or f"{uid}.json"
    Path(out_path).write_text(json.dumps(result["dashboard"], indent=2, ensure_ascii=False) + "\n")
    print(f"Exported to: {out_path}")


def cmd_create(client: GrafanaClient, args: list[str]) -> None:
    """Create dashboard from JSON. Usage: create --file <path> [--folder <uid>] [--title <t>] [--message <m>]"""
    file_path = folder_uid = title = message = None
    overwrite = False
    i = 0
    while i < len(args):
        if args[i] == "--file" and i + 1 < len(args):
            file_path = args[i + 1]; i += 2
        elif args[i] == "--folder" and i + 1 < len(args):
            folder_uid = args[i + 1]; i += 2
        elif args[i] == "--title" and i + 1 < len(args):
            title = args[i + 1]; i += 2
        elif args[i] == "--message" and i + 1 < len(args):
            message = args[i + 1]; i += 2
        elif args[i] == "--overwrite":
            overwrite = True; i += 1
        else:
            i += 1
    if not file_path:
        print("Usage: create --file <path> [--folder <uid>] [--title <t>]", file=sys.stderr); sys.exit(1)

    data = json.loads(Path(file_path).read_text())
    dashboard = data.get("dashboard", data) if isinstance(data, dict) and "dashboard" in data else data
    dashboard["id"] = None
    dashboard["uid"] = None
    if title:
        dashboard["title"] = title
    result = client.save_dashboard(dashboard, folder_uid=folder_uid,
                                   message=message or "Created via CLI", overwrite=overwrite)
    _pp(result)


def cmd_update(client: GrafanaClient, args: list[str]) -> None:
    """Update dashboard. Usage: update <uid> --file <path> [--message <m>] [--overwrite]"""
    if not args:
        print("Usage: update <uid> --file <path>", file=sys.stderr); sys.exit(1)
    uid = args[0]
    file_path = message = None
    overwrite = False
    i = 1
    while i < len(args):
        if args[i] == "--file" and i + 1 < len(args):
            file_path = args[i + 1]; i += 2
        elif args[i] == "--message" and i + 1 < len(args):
            message = args[i + 1]; i += 2
        elif args[i] == "--overwrite":
            overwrite = True; i += 1
        else:
            i += 1
    if not file_path:
        print("--file required", file=sys.stderr); sys.exit(1)

    existing = client.get_dashboard(uid)
    data = json.loads(Path(file_path).read_text())
    dashboard = data.get("dashboard", data) if isinstance(data, dict) and "dashboard" in data else data
    dashboard["uid"] = uid
    dashboard["version"] = existing["dashboard"].get("version")
    folder_uid = existing["meta"].get("folderUid")
    result = client.save_dashboard(dashboard, folder_uid=folder_uid,
                                   message=message or "Updated via CLI", overwrite=overwrite)
    _pp(result)


def cmd_delete(client: GrafanaClient, args: list[str]) -> None:
    """Delete dashboard. Usage: delete <uid>"""
    if not args:
        print("Usage: delete <uid>", file=sys.stderr); sys.exit(1)
    _pp(client.delete_dashboard(args[0]))


def cmd_clone(client: GrafanaClient, args: list[str]) -> None:
    """Clone dashboard. Usage: clone <uid> [--title <t>] [--folder <uid>]"""
    if not args:
        print("Usage: clone <uid> [--title <t>] [--folder <uid>]", file=sys.stderr); sys.exit(1)
    uid = args[0]
    title = folder_uid = None
    i = 1
    while i < len(args):
        if args[i] == "--title" and i + 1 < len(args):
            title = args[i + 1]; i += 2
        elif args[i] == "--folder" and i + 1 < len(args):
            folder_uid = args[i + 1]; i += 2
        else:
            i += 1
    source = client.get_dashboard(uid)
    dashboard = source["dashboard"].copy()
    dashboard["id"] = None
    dashboard["uid"] = None
    dashboard["title"] = title or f"{dashboard['title']} (Copy)"
    result = client.save_dashboard(dashboard, folder_uid=folder_uid or source["meta"].get("folderUid"),
                                   message=f"Cloned from {uid}")
    _pp(result)


def cmd_versions(client: GrafanaClient, args: list[str]) -> None:
    """List dashboard versions. Usage: versions <uid> [--limit <n>]"""
    if not args:
        print("Usage: versions <uid>", file=sys.stderr); sys.exit(1)
    limit = 20
    if "--limit" in args:
        idx = args.index("--limit")
        limit = int(args[idx + 1]) if idx + 1 < len(args) else 20
    versions = client.get_dashboard_versions(args[0], limit=limit)
    print(f"\nVersions ({len(versions)}):\n" + "-" * 72)
    for v in versions:
        restored = f" (restored from v{v['restoredFrom']})" if v.get("restoredFrom", 0) > 0 else ""
        print(f"  v{v['version']:>3}  {v.get('created', '?')}  by {v.get('createdBy', '?')}  {v.get('message', '')}{restored}")
    print("-" * 72)


def cmd_restore(client: GrafanaClient, args: list[str]) -> None:
    """Restore dashboard version. Usage: restore <uid> --version <n>"""
    if not args:
        print("Usage: restore <uid> --version <n>", file=sys.stderr); sys.exit(1)
    uid = args[0]
    version = None
    if "--version" in args:
        idx = args.index("--version")
        version = int(args[idx + 1]) if idx + 1 < len(args) else None
    if version is None:
        print("--version required", file=sys.stderr); sys.exit(1)
    _pp(client.restore_dashboard_version(uid, version))


def cmd_folders(client: GrafanaClient, args: list[str]) -> None:
    """List folders. Usage: folders [--json]"""
    as_json = "--json" in args
    folders = client.list_folders()
    if as_json:
        _pp(folders)
    else:
        print(f"\nFolders ({len(folders)}):\n" + "-" * 72)
        for f in folders:
            print(f"  {f['uid']:20s}  {f['title']}")
        print("-" * 72)


def cmd_datasources(client: GrafanaClient, args: list[str]) -> None:
    """List datasources. Usage: datasources [--json]"""
    as_json = "--json" in args
    sources = client.list_datasources()
    if as_json:
        _pp(sources)
    else:
        print(f"\nDatasources ({len(sources)}):\n" + "-" * 72)
        for s in sources:
            default = " (default)" if s.get("isDefault") else ""
            print(f"  {s.get('uid', '?'):20s}  {s['name']:30s}  {s['type']}{default}")
        print("-" * 72)


def cmd_annotations(client: GrafanaClient, args: list[str]) -> None:
    """Query annotations. Usage: annotations [--dashboard <uid>] [--tag <t>] [--limit <n>] [--json]"""
    dashboard_uid = None
    tags: list[str] = []
    limit = 100
    as_json = False
    i = 0
    while i < len(args):
        if args[i] == "--dashboard" and i + 1 < len(args):
            dashboard_uid = args[i + 1]; i += 2
        elif args[i] == "--tag" and i + 1 < len(args):
            tags.append(args[i + 1]); i += 2
        elif args[i] == "--limit" and i + 1 < len(args):
            limit = int(args[i + 1]); i += 2
        elif args[i] == "--json":
            as_json = True; i += 1
        else:
            i += 1
    result = client.query_annotations(dashboard_uid=dashboard_uid, tags=tags or None, limit=limit)
    if as_json:
        _pp(result)
    else:
        print(f"\nAnnotations ({len(result)}):\n" + "-" * 72)
        for a in result:
            tag_str = f" [{', '.join(a.get('tags', []))}]" if a.get("tags") else ""
            print(f"  {a.get('id', '?'):>6}  {a.get('text', '')[:60]}{tag_str}")
        print("-" * 72)


def cmd_alerts(client: GrafanaClient, args: list[str]) -> None:
    """List alert rules. Usage: alerts [--active] [--json]"""
    as_json = "--json" in args
    show_active = "--active" in args
    if show_active:
        result = client.get_active_alerts()
    else:
        result = client.list_alert_rules()
    if as_json:
        _pp(result)
    else:
        print(f"\n{'Active alerts' if show_active else 'Alert rules'} ({len(result)}):\n" + "-" * 72)
        for r in result:
            title = r.get("title") or r.get("labels", {}).get("alertname", "?")
            state = r.get("status", {}).get("state", "") if show_active else ""
            if state:
                state = f" [{state}]"
            print(f"  {r.get('uid', '?'):20s}  {title}{state}")
        print("-" * 72)


def cmd_user(client: GrafanaClient, _args: list[str]) -> None:
    _pp(client.get_current_user())


def cmd_org(client: GrafanaClient, _args: list[str]) -> None:
    _pp(client.get_current_org())


def cmd_raw(client: GrafanaClient, args: list[str]) -> None:
    """Raw API call. Usage: raw <METHOD> <endpoint> [--body <json>]"""
    if len(args) < 2:
        print("Usage: raw <GET|POST|PUT|DELETE> <endpoint> [--body <json>]", file=sys.stderr); sys.exit(1)
    method = args[0].upper()
    endpoint = args[1]
    json_body = None
    if "--body" in args:
        idx = args.index("--body")
        json_body = json.loads(args[idx + 1]) if idx + 1 < len(args) else None
    result = client._request(method, endpoint, json_body=json_body)
    _pp(result)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

COMMANDS = {
    "health": cmd_health,
    "list": cmd_list,
    "get": cmd_get,
    "export": cmd_export,
    "create": cmd_create,
    "update": cmd_update,
    "delete": cmd_delete,
    "clone": cmd_clone,
    "versions": cmd_versions,
    "restore": cmd_restore,
    "folders": cmd_folders,
    "datasources": cmd_datasources,
    "annotations": cmd_annotations,
    "alerts": cmd_alerts,
    "user": cmd_user,
    "org": cmd_org,
    "raw": cmd_raw,
}

USAGE = """\
Grafana API CLI

USAGE: grafana.sh [options] <command> [args...]

OPTIONS (handled by wrapper):
  --url <url>            Grafana base URL (overrides GRAFANA_URL)
  --org-id <id>          Organization ID (overrides GRAFANA_ORG_ID)
  --env-file <path>      Load env vars from file (repeatable, later wins)
  --timeout <duration>   Global timeout (default: 5m)

COMMANDS:
  health                           Check Grafana health
  list [--query q] [--tag t]       List/search dashboards
  get <uid> [--json]               Get dashboard details
  export <uid> [--output path]     Export dashboard JSON
  create --file <path> [--folder]  Create dashboard from JSON
  update <uid> --file <path>       Update existing dashboard
  delete <uid>                     Delete dashboard
  clone <uid> [--title t]          Clone dashboard
  versions <uid>                   List dashboard versions
  restore <uid> --version <n>      Restore dashboard version
  folders [--json]                 List folders
  datasources [--json]             List datasources
  annotations [--dashboard uid]    Query annotations
  alerts [--active] [--json]       List alert rules / active alerts
  user                             Current user info
  org                              Current org info
  raw <METHOD> <endpoint>          Raw API call

ENVIRONMENT:
  GRAFANA_URL      Grafana base URL (e.g. https://myinstance.grafana.net)
  GRAFANA_TOKEN    Service account token
  GRAFANA_ORG_ID   Organization ID (optional)
"""


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] in ("--help", "-h", "help"):
        print(USAGE)
        sys.exit(0)

    base_url = os.environ.get("GRAFANA_URL")
    token = os.environ.get("GRAFANA_TOKEN")
    if not base_url:
        print("GRAFANA_URL is required (use --url or --env-file)", file=sys.stderr)
        sys.exit(1)
    if not token:
        print("GRAFANA_TOKEN is required (use --env-file or set GRAFANA_TOKEN)", file=sys.stderr)
        sys.exit(1)

    org_id = int(os.environ["GRAFANA_ORG_ID"]) if os.environ.get("GRAFANA_ORG_ID") else None
    client = GrafanaClient(base_url, token, org_id=org_id)

    command_name = args[0]
    command_args = args[1:]

    if command_name not in COMMANDS:
        print(f"Unknown command: {command_name}\n", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        sys.exit(1)

    COMMANDS[command_name](client, command_args)


if __name__ == "__main__":
    main()
