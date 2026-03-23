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

import copy
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
import httpx

# ---------------------------------------------------------------------------
# Exceptions (Phase 1)
# ---------------------------------------------------------------------------

class GrafanaAPIError(Exception):
    """Base exception for Grafana API errors."""
    def __init__(self, message: str, status_code: int, response: Any):
        self.message = message
        self.status_code = status_code
        self.response = response
        super().__init__(f"[{status_code}] {message}")


class ConflictError(GrafanaAPIError):
    """HTTP 409 — K8s-style API resource version conflict."""
    pass


class PreconditionFailedError(GrafanaAPIError):
    """HTTP 412 — Legacy API version mismatch."""
    pass


# ---------------------------------------------------------------------------
# Merge conflict types (Phase 6)
# ---------------------------------------------------------------------------

@dataclass
class BothModified:
    path: str
    base_val: Any
    our_val: Any
    their_val: Any

@dataclass
class DeleteModify:
    path: str
    surviving_val: Any

@dataclass
class BothAdded:
    path: str
    our_val: Any
    their_val: Any

Conflict = BothModified | DeleteModify | BothAdded

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
            if resp.status_code == 409:
                raise ConflictError(msg, resp.status_code, data)
            elif resp.status_code == 412:
                raise PreconditionFailedError(msg, resp.status_code, data)
            else:
                raise GrafanaAPIError(msg, resp.status_code, data)
        return data

    def _request_safe(self, method: str, endpoint: str, *, params: dict | None = None, json_body: Any = None) -> tuple[int, Any]:
        """Non-raising request — returns (status_code, data) for probing."""
        url = f"{self.base_url}{endpoint}"
        resp = self._client.request(method, url, params=params, json=json_body)
        try:
            data = resp.json()
        except Exception:
            data = {"message": resp.text}
        return resp.status_code, data

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

    # -- dashboards (legacy) ----------------------------------------------

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

    # -- dashboards (K8s-style API, Phase 2) ------------------------------

    K8S_API_BASE = "/apis/dashboard.grafana.app/v1beta1"

    def k8s_list_dashboards(self, namespace: str, label_selector: str | None = None) -> dict:
        params: dict[str, Any] = {}
        if label_selector:
            params["labelSelector"] = label_selector
        return self.get(f"{self.K8S_API_BASE}/namespaces/{namespace}/dashboards", params=params)

    def k8s_get_dashboard(self, namespace: str, name: str) -> dict:
        return self.get(f"{self.K8S_API_BASE}/namespaces/{namespace}/dashboards/{name}")

    def k8s_create_dashboard(self, namespace: str, body: dict) -> dict:
        return self.post(f"{self.K8S_API_BASE}/namespaces/{namespace}/dashboards", json_body=body)

    def k8s_update_dashboard(self, namespace: str, name: str, body: dict) -> dict:
        """PUT — body must include metadata.resourceVersion for OCC."""
        return self.put(f"{self.K8S_API_BASE}/namespaces/{namespace}/dashboards/{name}", json_body=body)

    def k8s_delete_dashboard(self, namespace: str, name: str) -> dict:
        return self.delete(f"{self.K8S_API_BASE}/namespaces/{namespace}/dashboards/{name}")

    def detect_api_mode(self) -> str:
        """Probe K8s endpoint; return 'k8s' if available, else 'legacy'."""
        status, _ = self._request_safe("GET", f"{self.K8S_API_BASE}/")
        return "k8s" if status != 404 else "legacy"

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

    def query_datasource(self, queries: list[dict], time_from: str = "now-1h", time_to: str = "now") -> dict:
        """Execute queries via POST /api/ds/query."""
        return self.post("/api/ds/query", json_body={"from": time_from, "to": time_to, "queries": queries})

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
# Format Detection & Conversion (Phase 3)
# ---------------------------------------------------------------------------

def detect_format(data: dict) -> str:
    """Detect whether data is K8s-style or legacy format."""
    if "apiVersion" in data and "kind" in data:
        return "k8s"
    return "legacy"


def legacy_to_k8s(dashboard: dict, folder_uid: str | None = None) -> dict:
    """Convert legacy dashboard body to K8s-style resource."""
    spec = {k: v for k, v in dashboard.items() if k not in ("uid", "id", "version", "schemaVersion")}
    metadata: dict[str, Any] = {}
    if dashboard.get("uid"):
        metadata["name"] = dashboard["uid"]
    annotations: dict[str, str] = {}
    if folder_uid:
        annotations["grafana.app/folder"] = folder_uid
    if dashboard.get("schemaVersion"):
        annotations["grafana.app/schemaVersion"] = str(dashboard["schemaVersion"])
    if annotations:
        metadata["annotations"] = annotations
    return {
        "apiVersion": "dashboard.grafana.app/v1beta1",
        "kind": "Dashboard",
        "metadata": metadata,
        "spec": spec,
    }


def k8s_to_legacy(resource: dict) -> dict:
    """Convert K8s-style resource to legacy dashboard body."""
    spec = resource.get("spec", {})
    metadata = resource.get("metadata", {})
    dashboard = dict(spec)
    if metadata.get("name"):
        dashboard["uid"] = metadata["name"]
    annotations = metadata.get("annotations", {})
    schema_ver = annotations.get("grafana.app/schemaVersion")
    if schema_ver:
        dashboard["schemaVersion"] = int(schema_ver)
    return dashboard


# ---------------------------------------------------------------------------
# DashboardOps Facade (Phase 4)
# ---------------------------------------------------------------------------

@dataclass
class OccMeta:
    """Optimistic concurrency control metadata."""
    version: int | None = None           # legacy
    resource_version: str | None = None  # K8s
    api_mode: str = "legacy"

    def to_dict(self) -> dict:
        if self.api_mode == "k8s":
            return {"resourceVersion": self.resource_version, "api_mode": "k8s"}
        return {"version": self.version, "api_mode": "legacy"}

    @classmethod
    def from_dict(cls, d: dict) -> OccMeta:
        mode = d.get("api_mode", "legacy")
        if mode == "k8s":
            return cls(resource_version=d.get("resourceVersion"), api_mode="k8s")
        return cls(version=d.get("version"), api_mode="legacy")


class DashboardOps:
    """Normalizes API differences so CLI commands don't branch on mode."""

    def __init__(self, client: GrafanaClient, api_mode: str = "auto", namespace: str = "default"):
        self.client = client
        self.namespace = namespace
        if api_mode == "auto":
            self.api_mode = client.detect_api_mode()
        else:
            self.api_mode = api_mode

    def get(self, uid: str) -> tuple[dict, OccMeta]:
        if self.api_mode == "k8s":
            res = self.client.k8s_get_dashboard(self.namespace, uid)
            dashboard = k8s_to_legacy(res)
            occ = OccMeta(resource_version=res["metadata"].get("resourceVersion"), api_mode="k8s")
            return dashboard, occ
        else:
            res = self.client.get_dashboard(uid)
            dashboard = res["dashboard"]
            occ = OccMeta(version=res["meta"].get("version"), api_mode="legacy")
            return dashboard, occ

    def get_raw(self, uid: str) -> tuple[dict, OccMeta, dict]:
        """Like get() but also returns the full raw API response."""
        if self.api_mode == "k8s":
            res = self.client.k8s_get_dashboard(self.namespace, uid)
            dashboard = k8s_to_legacy(res)
            occ = OccMeta(resource_version=res["metadata"].get("resourceVersion"), api_mode="k8s")
            return dashboard, occ, res
        else:
            res = self.client.get_dashboard(uid)
            dashboard = res["dashboard"]
            occ = OccMeta(version=res["meta"].get("version"), api_mode="legacy")
            return dashboard, occ, res

    def save(self, dashboard: dict, occ: OccMeta, folder_uid: str | None = None,
             message: str = "") -> dict:
        if self.api_mode == "k8s":
            body = legacy_to_k8s(dashboard, folder_uid=folder_uid)
            name = dashboard.get("uid", body["metadata"].get("name", ""))
            if occ.resource_version:
                body["metadata"]["resourceVersion"] = occ.resource_version
            return self.client.k8s_update_dashboard(self.namespace, name, body)
        else:
            dash = dict(dashboard)
            if occ.version is not None:
                dash["version"] = occ.version
            return self.client.save_dashboard(dash, folder_uid=folder_uid,
                                              message=message, overwrite=False)

    def save_force(self, dashboard: dict, folder_uid: str | None = None,
                   message: str = "") -> dict:
        """Save with overwrite/force — bypasses OCC."""
        if self.api_mode == "k8s":
            # For K8s, fetch current resourceVersion first then PUT
            _, current_occ = self.get(dashboard.get("uid", ""))
            return self.save(dashboard, current_occ, folder_uid=folder_uid, message=message)
        else:
            return self.client.save_dashboard(dashboard, folder_uid=folder_uid,
                                              message=message, overwrite=True)

    def create(self, dashboard: dict, folder_uid: str | None = None,
               message: str = "") -> dict:
        if self.api_mode == "k8s":
            body = legacy_to_k8s(dashboard, folder_uid=folder_uid)
            body["metadata"].pop("name", None)  # let server assign
            return self.client.k8s_create_dashboard(self.namespace, body)
        else:
            dash = dict(dashboard)
            dash["id"] = None
            dash["uid"] = None
            return self.client.save_dashboard(dash, folder_uid=folder_uid,
                                              message=message, overwrite=False)

    def delete(self, uid: str) -> dict:
        if self.api_mode == "k8s":
            return self.client.k8s_delete_dashboard(self.namespace, uid)
        else:
            return self.client.delete_dashboard(uid)

    def search(self, query: str | None = None, tag: str | None = None,
               folder_uid: str | None = None, limit: int = 100) -> list[dict]:
        if self.api_mode == "k8s":
            res = self.client.k8s_list_dashboards(self.namespace)
            items = res.get("items", [])
            results = []
            for item in items:
                dash = k8s_to_legacy(item)
                entry = {
                    "uid": dash.get("uid", item["metadata"].get("name", "")),
                    "title": dash.get("title", ""),
                    "tags": dash.get("tags", []),
                }
                if query and query.lower() not in entry["title"].lower():
                    continue
                if tag and tag not in entry.get("tags", []):
                    continue
                results.append(entry)
            return results[:limit]
        else:
            return self.client.search_dashboards(query=query, tag=tag,
                                                 folder_uid=folder_uid, limit=limit)


# ---------------------------------------------------------------------------
# Sidecar Base File Handling (Phase 5)
# ---------------------------------------------------------------------------

def _base_path(working_path: str) -> Path:
    p = Path(working_path)
    return p.parent / f"{p.stem}.base.json"


def write_sidecar(working_path: str, dashboard: dict, occ: OccMeta) -> Path:
    """Write the base sidecar file alongside the working copy."""
    base = dict(dashboard)
    base["_occ_meta"] = occ.to_dict()
    bp = _base_path(working_path)
    bp.write_text(json.dumps(base, indent=2, ensure_ascii=False) + "\n")
    return bp


def read_base(path: str) -> tuple[dict, OccMeta] | None:
    """Read a base sidecar file, returning (dashboard, occ_meta) or None."""
    bp = _base_path(path)
    if not bp.exists():
        return None
    data = json.loads(bp.read_text())
    occ_dict = data.pop("_occ_meta", {})
    occ = OccMeta.from_dict(occ_dict)
    return data, occ


def read_working(path: str) -> dict:
    """Read a working copy file, auto-detect format and normalize to legacy body."""
    data = json.loads(Path(path).read_text())
    # Strip _occ_meta if accidentally present
    data.pop("_occ_meta", None)
    fmt = detect_format(data)
    if fmt == "k8s":
        return k8s_to_legacy(data)
    # Handle wrapped legacy format
    if "dashboard" in data and "meta" in data:
        return data["dashboard"]
    return data


# ---------------------------------------------------------------------------
# Three-Way Merge Engine (Phase 6)
# ---------------------------------------------------------------------------

# Fields to ignore when comparing dashboard equality
_VOLATILE_FIELDS = frozenset({"id", "version", "schemaVersion", "iteration"})


def _deep_equal(a: Any, b: Any) -> bool:
    """Deep structural equality, ignoring volatile fields at the top level of dicts."""
    if type(a) != type(b):
        return False
    if isinstance(a, dict):
        keys_a = set(a.keys()) - _VOLATILE_FIELDS
        keys_b = set(b.keys()) - _VOLATILE_FIELDS
        if keys_a != keys_b:
            return False
        return all(_deep_equal(a[k], b[k]) for k in keys_a)
    if isinstance(a, list):
        if len(a) != len(b):
            return False
        return all(_deep_equal(x, y) for x, y in zip(a, b))
    return a == b


def _strict_equal(a: Any, b: Any) -> bool:
    """Strict deep equality (no volatile field ignoring)."""
    if type(a) != type(b):
        return False
    if isinstance(a, dict):
        if set(a.keys()) != set(b.keys()):
            return False
        return all(_strict_equal(a[k], b[k]) for k in a)
    if isinstance(a, list):
        if len(a) != len(b):
            return False
        return all(_strict_equal(x, y) for x, y in zip(a, b))
    return a == b


def _merge_by_key(base_list: list[dict], ours_list: list[dict], theirs_list: list[dict],
                  key_fn, path_prefix: str) -> tuple[list[dict], list[Conflict]]:
    """Merge two lists of dicts using a key function for identity."""
    conflicts: list[Conflict] = []

    base_map = {key_fn(item): item for item in base_list}
    ours_map = {key_fn(item): item for item in ours_list}
    theirs_map = {key_fn(item): item for item in theirs_list}

    all_keys: list = []
    seen: set = set()
    # Preserve order: theirs first (server), then ours additions
    for item in theirs_list:
        k = key_fn(item)
        if k not in seen:
            all_keys.append(k)
            seen.add(k)
    for item in ours_list:
        k = key_fn(item)
        if k not in seen:
            all_keys.append(k)
            seen.add(k)

    merged: list[dict] = []
    for k in all_keys:
        in_base = k in base_map
        in_ours = k in ours_map
        in_theirs = k in theirs_map

        if in_base and in_ours and in_theirs:
            # Existed in all three
            b, o, t = base_map[k], ours_map[k], theirs_map[k]
            ours_changed = not _strict_equal(b, o)
            theirs_changed = not _strict_equal(b, t)
            if not ours_changed and not theirs_changed:
                merged.append(copy.deepcopy(b))
            elif ours_changed and not theirs_changed:
                merged.append(copy.deepcopy(o))
            elif not ours_changed and theirs_changed:
                merged.append(copy.deepcopy(t))
            else:
                # Both changed
                if _strict_equal(o, t):
                    merged.append(copy.deepcopy(o))  # Same change
                else:
                    conflicts.append(BothModified(f"{path_prefix}[{k}]", b, o, t))
                    merged.append(copy.deepcopy(t))  # Default to theirs
        elif in_base and in_ours and not in_theirs:
            # Deleted by theirs
            if _strict_equal(base_map[k], ours_map[k]):
                pass  # We didn't change it, accept deletion
            else:
                conflicts.append(DeleteModify(f"{path_prefix}[{k}]", ours_map[k]))
        elif in_base and not in_ours and in_theirs:
            # Deleted by us
            if _strict_equal(base_map[k], theirs_map[k]):
                pass  # They didn't change it, accept our deletion
            else:
                conflicts.append(DeleteModify(f"{path_prefix}[{k}]", theirs_map[k]))
                merged.append(copy.deepcopy(theirs_map[k]))
        elif not in_base and in_ours and in_theirs:
            # Both added
            if _strict_equal(ours_map[k], theirs_map[k]):
                merged.append(copy.deepcopy(ours_map[k]))
            else:
                conflicts.append(BothAdded(f"{path_prefix}[{k}]", ours_map[k], theirs_map[k]))
                merged.append(copy.deepcopy(theirs_map[k]))
        elif not in_base and in_ours and not in_theirs:
            merged.append(copy.deepcopy(ours_map[k]))  # We added
        elif not in_base and not in_ours and in_theirs:
            merged.append(copy.deepcopy(theirs_map[k]))  # They added
        # Both absent from final: skip

    return merged, conflicts


def three_way_merge(base: dict, ours: dict, theirs: dict) -> tuple[dict, list[Conflict]]:
    """Three-way merge of dashboard bodies. Returns (merged, conflicts)."""
    conflicts: list[Conflict] = []
    merged = copy.deepcopy(theirs)  # Start from theirs as base

    # --- Merge list fields by key ---
    list_fields = {
        "panels": lambda p: p.get("id"),
        "templating.list": lambda v: v.get("name"),
        "annotations.list": lambda a: a.get("name"),
    }

    for field_path, key_fn in list_fields.items():
        parts = field_path.split(".")
        # Navigate into nested dicts
        base_val = base
        ours_val = ours
        theirs_val = theirs
        merged_parent = merged
        for part in parts[:-1]:
            base_val = base_val.get(part, {})
            ours_val = ours_val.get(part, {})
            theirs_val = theirs_val.get(part, {})
            merged_parent = merged_parent.setdefault(part, {})

        last = parts[-1]
        b_list = base_val.get(last, []) if isinstance(base_val, dict) else []
        o_list = ours_val.get(last, []) if isinstance(ours_val, dict) else []
        t_list = theirs_val.get(last, []) if isinstance(theirs_val, dict) else []

        if b_list or o_list or t_list:
            merged_list, list_conflicts = _merge_by_key(b_list, o_list, t_list, key_fn, field_path)
            conflicts.extend(list_conflicts)
            if isinstance(merged_parent, dict):
                merged_parent[last] = merged_list

    # --- Merge scalar fields ---
    scalar_fields = ["title", "description", "tags", "timezone", "refresh", "editable",
                     "graphTooltip", "fiscalYearStartMonth", "liveNow",
                     "time", "timepicker", "weekStart"]

    for sf in scalar_fields:
        b_val = base.get(sf)
        o_val = ours.get(sf)
        t_val = theirs.get(sf)

        ours_changed = not _strict_equal(b_val, o_val)
        theirs_changed = not _strict_equal(b_val, t_val)

        if ours_changed and not theirs_changed:
            merged[sf] = copy.deepcopy(o_val)
        elif not ours_changed and theirs_changed:
            pass  # Already have theirs
        elif ours_changed and theirs_changed:
            if not _strict_equal(o_val, t_val):
                conflicts.append(BothModified(sf, b_val, o_val, t_val))
                # Keep theirs (already in merged)
            # else: same change, theirs is fine

    # --- Merge links ---
    b_links = base.get("links", [])
    o_links = ours.get("links", [])
    t_links = theirs.get("links", [])
    if b_links or o_links or t_links:
        link_key = lambda l: l.get("title", "") + "|" + l.get("url", "")
        merged_links, link_conflicts = _merge_by_key(b_links, o_links, t_links, link_key, "links")
        conflicts.extend(link_conflicts)
        merged["links"] = merged_links

    return merged, conflicts


def _format_conflicts(conflicts: list[Conflict]) -> str:
    """Format conflicts for human-readable output."""
    lines = [f"CONFLICTS ({len(conflicts)}):"]
    for c in conflicts:
        if isinstance(c, BothModified):
            lines.append(f"  BOTH MODIFIED: {c.path}")
            lines.append(f"    base:   {json.dumps(c.base_val, ensure_ascii=False)[:120]}")
            lines.append(f"    ours:   {json.dumps(c.our_val, ensure_ascii=False)[:120]}")
            lines.append(f"    theirs: {json.dumps(c.their_val, ensure_ascii=False)[:120]}")
        elif isinstance(c, DeleteModify):
            lines.append(f"  DELETE/MODIFY: {c.path}")
            lines.append(f"    surviving: {json.dumps(c.surviving_val, ensure_ascii=False)[:120]}")
        elif isinstance(c, BothAdded):
            lines.append(f"  BOTH ADDED: {c.path}")
            lines.append(f"    ours:   {json.dumps(c.our_val, ensure_ascii=False)[:120]}")
            lines.append(f"    theirs: {json.dumps(c.their_val, ensure_ascii=False)[:120]}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Query Helpers
# ---------------------------------------------------------------------------

def _resolve_variables(obj: Any, variables: dict[str, str]) -> Any:
    """Recursively replace $var and ${var} placeholders in strings.

    Skips names starting with ``__`` to protect Grafana macros like
    ``$__timeFilter``, ``$__rate_interval``, etc.
    """
    import re

    if isinstance(obj, str):
        for var_name, var_value in variables.items():
            if var_name.startswith("__"):
                continue
            obj = obj.replace(f"${{{var_name}}}", str(var_value))
            obj = re.sub(rf"\${var_name}\b", str(var_value), obj)
        return obj
    elif isinstance(obj, dict):
        return {k: _resolve_variables(v, variables) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [_resolve_variables(item, variables) for item in obj]
    return obj


def _parse_frames(result: dict, ref_id: str = "A") -> tuple[list[dict], list[tuple]]:
    """Parse Grafana Data Frame response into (columns, rows).

    ``columns`` is a list of ``{"name": str, "type": str}`` dicts.
    ``rows`` is a list of tuples aligned to those columns.
    """
    frames = result.get("results", {}).get(ref_id, {}).get("frames", [])
    if not frames:
        return [], []

    label_names: set[str] = set()
    data_columns: list[dict] = []
    seen_data: set[str] = set()

    for frame in frames:
        fields = frame.get("schema", {}).get("fields", [])
        for field in fields:
            if field.get("labels"):
                label_names.update(field["labels"].keys())
            fname = field["name"]
            if fname not in seen_data:
                seen_data.add(fname)
                data_columns.append({"name": fname, "type": field.get("type", "string")})

    label_cols = [{"name": n, "type": "string"} for n in sorted(label_names)]
    all_columns = label_cols + data_columns

    all_rows: list[tuple] = []
    for frame in frames:
        fields = frame.get("schema", {}).get("fields", [])
        values = frame.get("data", {}).get("values", [])
        if not fields or not values:
            continue

        frame_labels: dict[str, str] = {}
        for field in fields:
            if field.get("labels"):
                frame_labels.update(field["labels"])

        field_names = [f["name"] for f in fields]
        num_rows = len(values[0]) if values else 0
        for i in range(num_rows):
            row: list[Any] = []
            for lc in label_cols:
                row.append(frame_labels.get(lc["name"], ""))
            for dc in data_columns:
                idx = None
                for fi, fn in enumerate(field_names):
                    if fn == dc["name"]:
                        idx = fi
                        break
                if idx is not None and i < len(values[idx]):
                    row.append(values[idx][i])
                else:
                    row.append(None)
            all_rows.append(tuple(row))

    return all_columns, all_rows


def _frames_to_rows(result: dict, ref_id: str = "A") -> list[dict]:
    """Parse frames into a list of dicts (row-oriented)."""
    columns, rows = _parse_frames(result, ref_id)
    col_names = [c["name"] for c in columns]
    return [dict(zip(col_names, row)) for row in rows]


def _export_parquet(columns: list[dict], rows: list[tuple], path: str) -> str:
    """Export to Parquet with Snappy compression. Requires pyarrow."""
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
    except ImportError:
        print("ERROR: pyarrow is required for Parquet export.\n"
              "Install with:  uv pip install pyarrow\n"
              "Or use --format tsv / --format jsonl instead.", file=sys.stderr)
        sys.exit(1)

    arrow_arrays = []
    arrow_fields = []
    for ci, col in enumerate(columns):
        col_values = [row[ci] for row in rows]
        if col["type"] == "time":
            arr = pa.array(col_values, type=pa.int64())
            ts_arr = arr.cast(pa.timestamp("ms", tz="UTC"))
            arrow_arrays.append(ts_arr)
            arrow_fields.append(pa.field(col["name"], pa.timestamp("ms", tz="UTC")))
        elif col["type"] == "number":
            arrow_arrays.append(pa.array(col_values, type=pa.float64()))
            arrow_fields.append(pa.field(col["name"], pa.float64()))
        else:
            arrow_arrays.append(
                pa.array([str(v) if v is not None else None for v in col_values], type=pa.string()))
            arrow_fields.append(pa.field(col["name"], pa.string()))

    schema = pa.schema(arrow_fields)
    table = pa.table({f.name: a for f, a in zip(arrow_fields, arrow_arrays)}, schema=schema)
    pq.write_table(table, path, compression="snappy")
    return path


def _export_tsv(columns: list[dict], rows: list[tuple], path: str) -> str:
    """Export to TSV. Epoch-ms timestamps are converted to ISO 8601."""
    import csv
    from datetime import datetime, timezone

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, delimiter="\t", quoting=csv.QUOTE_MINIMAL)
        writer.writerow([c["name"] for c in columns])
        for row in rows:
            out: list[str] = []
            for ci, val in enumerate(row):
                if columns[ci]["type"] == "time" and isinstance(val, (int, float)):
                    out.append(
                        datetime.fromtimestamp(val / 1000, tz=timezone.utc)
                        .strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")
                elif val is None:
                    out.append("")
                else:
                    out.append(str(val))
            writer.writerow(out)
    return path


def _export_jsonl(columns: list[dict], rows: list[tuple], path: str) -> str:
    """Export to JSON Lines (one JSON object per row)."""
    col_names = [c["name"] for c in columns]
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(dict(zip(col_names, row)), ensure_ascii=False) + "\n")
    return path


def _export_frames(result: dict, ref_id: str, fmt: str, path: str) -> str | None:
    """Parse frames and export to the given format. Returns path or None."""
    columns, rows = _parse_frames(result, ref_id)
    if not columns or not rows:
        return None
    if fmt == "parquet":
        return _export_parquet(columns, rows, path)
    elif fmt == "tsv":
        return _export_tsv(columns, rows, path)
    elif fmt == "jsonl":
        return _export_jsonl(columns, rows, path)
    else:
        print(f"Unknown format: {fmt}", file=sys.stderr)
        sys.exit(1)


def _auto_output_path(output_dir: str | None, prefix: str, ext: str) -> str:
    """Generate an output file path, using tempfile if no output_dir."""
    import tempfile
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
        fd, path = tempfile.mkstemp(suffix=f".{ext}", prefix=f"{prefix}_", dir=output_dir)
    else:
        fd, path = tempfile.mkstemp(suffix=f".{ext}", prefix=f"{prefix}_")
    os.close(fd)
    return path


def _check_query_errors(result: dict) -> None:
    """Check per-refId errors (Grafana returns 200 even on query failure)."""
    for ref_id, ref_result in result.get("results", {}).items():
        if "error" in ref_result:
            print(f"Query {ref_id} failed: {ref_result['error']}", file=sys.stderr)
            sys.exit(1)
        if ref_result.get("status", 200) != 200:
            print(f"Query {ref_id} returned status {ref_result['status']}", file=sys.stderr)
            sys.exit(1)


def _format_from_path(path: str) -> str | None:
    """Detect export format from file extension."""
    if path.endswith(".parquet"):
        return "parquet"
    elif path.endswith(".tsv"):
        return "tsv"
    elif path.endswith(".jsonl"):
        return "jsonl"
    return None


def _print_preview(result: dict, ref_id: str, n: int) -> None:
    """Print up to n rows as JSONL to stdout, plus a summary line."""
    rows = _frames_to_rows(result, ref_id)
    for row in rows[:n]:
        print(json.dumps(row, ensure_ascii=False))
    total = len(rows)
    if total > n:
        print(f"... ({total - n} more rows)", file=sys.stderr)
    print(f"Total: {total} rows for refId={ref_id}", file=sys.stderr)


def _handle_query_output(result: dict, ref_ids: list[str], *,
                         as_json: bool, preview: int | None,
                         output: str | None, output_dir: str | None,
                         fmt: str | None) -> None:
    """Shared output logic for query and panel-query commands."""
    if as_json:
        _pp(result)
        return

    if preview is not None:
        for ref_id in ref_ids:
            _print_preview(result, ref_id, preview)
        return

    if output:
        # Single explicit path — export first refId (or all if multiple)
        effective_fmt = fmt or _format_from_path(output) or "parquet"
        if len(ref_ids) == 1:
            exported = _export_frames(result, ref_ids[0], effective_fmt, output)
            if exported:
                print(f"Exported refId={ref_ids[0]}: {exported}", file=sys.stderr)
            else:
                print(f"No data for refId={ref_ids[0]}", file=sys.stderr)
        else:
            base, _ = os.path.splitext(output)
            ext_map = {"parquet": ".parquet", "tsv": ".tsv", "jsonl": ".jsonl"}
            for ref_id in ref_ids:
                rpath = f"{base}_{ref_id}{ext_map[effective_fmt]}"
                exported = _export_frames(result, ref_id, effective_fmt, rpath)
                if exported:
                    print(f"Exported refId={ref_id}: {exported}", file=sys.stderr)
        return

    if output_dir:
        effective_fmt = fmt or "parquet"
        ext_map = {"parquet": "parquet", "tsv": "tsv", "jsonl": "jsonl"}
        for ref_id in ref_ids:
            path = _auto_output_path(output_dir, f"grafana_query_{ref_id}", ext_map[effective_fmt])
            exported = _export_frames(result, ref_id, effective_fmt, path)
            if exported:
                print(f"Exported refId={ref_id}: {exported}", file=sys.stderr)
        return

    # Auto mode: small → preview, large → temp file
    for ref_id in ref_ids:
        columns, rows = _parse_frames(result, ref_id)
        if not rows:
            print(f"No data for refId={ref_id}", file=sys.stderr)
            continue
        if len(rows) <= 50:
            _print_preview(result, ref_id, 50)
        else:
            effective_fmt = fmt or "parquet"
            ext_map = {"parquet": "parquet", "tsv": "tsv", "jsonl": "jsonl"}
            path = _auto_output_path(None, f"grafana_query_{ref_id}", ext_map[effective_fmt])
            _export_frames(result, ref_id, effective_fmt, path)
            print(f"Exported {len(rows)} rows for refId={ref_id}: {path}", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------

def _pp(data: Any) -> None:
    """Pretty-print JSON."""
    print(json.dumps(data, indent=2, ensure_ascii=False))


def cmd_health(client: GrafanaClient, _args: list[str], **_kw: Any) -> None:
    _pp(client.health())


def cmd_list(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
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

    if ops:
        results = ops.search(query=query, tag=tag, folder_uid=folder_uid, limit=limit)
    else:
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


def cmd_get(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Get dashboard by UID. Usage: get <uid> [--json]"""
    if not args:
        print("Usage: get <uid> [--json]", file=sys.stderr); sys.exit(1)
    uid = args[0]
    as_json = "--json" in args

    if ops:
        dashboard, occ, raw = ops.get_raw(uid)
        if as_json:
            _pp(raw)
        else:
            meta = raw.get("meta", {}) if ops.api_mode == "legacy" else raw.get("metadata", {})
            print(f"\nDashboard: {dashboard.get('title', '?')}\n" + "-" * 72)
            print(f"  UID:      {dashboard.get('uid')}")
            print(f"  API Mode: {ops.api_mode}")
            if occ.api_mode == "k8s":
                print(f"  OCC:      resourceVersion={occ.resource_version}")
            else:
                print(f"  OCC:      version={occ.version}")
            if ops.api_mode == "legacy":
                print(f"  Folder:   {meta.get('folderTitle', 'General')}")
                print(f"  URL:      {meta.get('url')}")
                print(f"  Updated:  {meta.get('updated')}")
            else:
                print(f"  Created:  {meta.get('creationTimestamp', '?')}")
            print(f"  Panels:   {len(dashboard.get('panels', []))}")
            if dashboard.get("tags"):
                print(f"  Tags:     {', '.join(dashboard['tags'])}")
            print("-" * 72)
    else:
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


def cmd_export(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Export dashboard JSON. Usage: export <uid> [--output <path>] [--format <legacy|k8s>] [--no-base]"""
    if not args:
        print("Usage: export <uid> [--output <path>] [--format <legacy|k8s>] [--no-base]", file=sys.stderr)
        sys.exit(1)
    uid = args[0]
    output = None
    out_format = None
    no_base = "--no-base" in args
    if "--output" in args:
        idx = args.index("--output")
        output = args[idx + 1] if idx + 1 < len(args) else None
    if "--format" in args:
        idx = args.index("--format")
        out_format = args[idx + 1] if idx + 1 < len(args) else None

    if ops:
        dashboard, occ = ops.get(uid)
    else:
        result = client.get_dashboard(uid)
        dashboard = result["dashboard"]
        occ = OccMeta(version=result["meta"].get("version"), api_mode="legacy")

    out_data: dict
    if out_format == "k8s":
        out_data = legacy_to_k8s(dashboard)
    else:
        out_data = dashboard

    out_path = output or f"{uid}.json"
    Path(out_path).write_text(json.dumps(out_data, indent=2, ensure_ascii=False) + "\n")
    print(f"Exported to: {out_path}")

    if not no_base:
        bp = write_sidecar(out_path, dashboard, occ)
        print(f"Base saved:  {bp}")


def cmd_create(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Create dashboard from JSON. Usage: create --file <path> [--folder <uid>] [--title <t>] [--message <m>]"""
    file_path = folder_uid = title = message = None
    force = False
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
        elif args[i] in ("--overwrite", "--force"):
            force = True; i += 1
        else:
            i += 1
    if not file_path:
        print("Usage: create --file <path> [--folder <uid>] [--title <t>]", file=sys.stderr); sys.exit(1)

    dashboard = read_working(file_path)
    dashboard["id"] = None
    dashboard["uid"] = None
    if title:
        dashboard["title"] = title

    if ops:
        result = ops.create(dashboard, folder_uid=folder_uid, message=message or "Created via CLI")
    else:
        result = client.save_dashboard(dashboard, folder_uid=folder_uid,
                                       message=message or "Created via CLI", overwrite=force)
    _pp(result)


def cmd_update(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Update dashboard. Usage: update <uid> --file <path> [--message <m>] [--force]"""
    if not args:
        print("Usage: update <uid> --file <path>", file=sys.stderr); sys.exit(1)
    uid = args[0]
    file_path = message = None
    force = False
    i = 1
    while i < len(args):
        if args[i] == "--file" and i + 1 < len(args):
            file_path = args[i + 1]; i += 2
        elif args[i] == "--message" and i + 1 < len(args):
            message = args[i + 1]; i += 2
        elif args[i] in ("--overwrite", "--force"):
            force = True; i += 1
        else:
            i += 1
    if not file_path:
        print("--file required", file=sys.stderr); sys.exit(1)

    # 1. Read local file and normalize
    dashboard = read_working(file_path)
    dashboard["uid"] = uid

    # 2. Check for .base.json sidecar
    base_info = read_base(file_path)

    if force:
        # --force: bypass OCC entirely
        if ops:
            result = ops.save_force(dashboard, message=message or "Updated via CLI (force)")
        else:
            existing = client.get_dashboard(uid)
            folder_uid = existing["meta"].get("folderUid")
            result = client.save_dashboard(dashboard, folder_uid=folder_uid,
                                           message=message or "Updated via CLI (force)", overwrite=True)
        _pp(result)
        return

    # 3. Get OCC metadata
    if base_info:
        base_dashboard, occ = base_info
    else:
        # No sidecar — fetch server version for OCC
        if ops:
            _, occ = ops.get(uid)
        else:
            existing = client.get_dashboard(uid)
            occ = OccMeta(version=existing["dashboard"].get("version"), api_mode="legacy")
        base_dashboard = None

    # 4. Attempt save with OCC
    if ops:
        folder_uid = None
        if ops.api_mode == "legacy":
            try:
                _, _, raw = ops.get_raw(uid)
                folder_uid = raw.get("meta", {}).get("folderUid")
            except GrafanaAPIError:
                pass
    else:
        existing = client.get_dashboard(uid)
        folder_uid = existing["meta"].get("folderUid")
        dashboard["version"] = occ.version

    try:
        if ops:
            result = ops.save(dashboard, occ, folder_uid=folder_uid,
                              message=message or "Updated via CLI")
        else:
            result = client.save_dashboard(dashboard, folder_uid=folder_uid,
                                           message=message or "Updated via CLI", overwrite=False)
        _pp(result)
    except (PreconditionFailedError, ConflictError) as exc:
        # 5. Conflict — attempt three-way merge if we have a base
        if base_dashboard is not None:
            print(f"Conflict detected ({exc.status_code}). Attempting three-way merge...", file=sys.stderr)
            # Fetch server version as "theirs"
            if ops:
                theirs, new_occ = ops.get(uid)
            else:
                server = client.get_dashboard(uid)
                theirs = server["dashboard"]
                new_occ = OccMeta(version=server["dashboard"].get("version"), api_mode="legacy")

            merged, conflicts = three_way_merge(base_dashboard, dashboard, theirs)
            merged["uid"] = uid

            if conflicts:
                print(_format_conflicts(conflicts), file=sys.stderr)
                # Write merged result for manual resolution
                merged_path = Path(file_path).parent / f"{uid}.merged.json"
                merged_path.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n")
                print(f"\nMerged (with conflicts) written to: {merged_path}", file=sys.stderr)
                print("Resolve conflicts manually, then retry with --force or update the file.", file=sys.stderr)
                sys.exit(2)

            # Clean merge — retry save
            print("Clean merge successful. Saving merged result...", file=sys.stderr)
            if ops:
                result = ops.save(merged, new_occ, folder_uid=folder_uid,
                                  message=message or "Updated via CLI (auto-merged)")
            else:
                merged["version"] = new_occ.version
                result = client.save_dashboard(merged, folder_uid=folder_uid,
                                               message=message or "Updated via CLI (auto-merged)",
                                               overwrite=False)
            _pp(result)

            # Update sidecar with new base
            write_sidecar(file_path, merged, new_occ)
        else:
            print(f"Conflict detected ({exc.status_code}), but no .base.json sidecar found.", file=sys.stderr)
            print("Re-export with: export <uid> (creates sidecar), edit, then retry.", file=sys.stderr)
            sys.exit(2)


def cmd_delete(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Delete dashboard. Usage: delete <uid>"""
    if not args:
        print("Usage: delete <uid>", file=sys.stderr); sys.exit(1)
    if ops:
        _pp(ops.delete(args[0]))
    else:
        _pp(client.delete_dashboard(args[0]))


def cmd_clone(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_versions(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_restore(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_folders(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_datasources(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_annotations(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_alerts(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


def cmd_user(client: GrafanaClient, _args: list[str], **_kw: Any) -> None:
    _pp(client.get_current_user())


def cmd_org(client: GrafanaClient, _args: list[str], **_kw: Any) -> None:
    _pp(client.get_current_org())


def cmd_raw(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
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


# -- New commands (Phase 7) -----------------------------------------------

def cmd_diff(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Structural diff: local file vs server. Usage: diff <uid> --file <path>"""
    if not args:
        print("Usage: diff <uid> --file <path>", file=sys.stderr); sys.exit(1)
    uid = args[0]
    file_path = None
    i = 1
    while i < len(args):
        if args[i] == "--file" and i + 1 < len(args):
            file_path = args[i + 1]; i += 2
        else:
            i += 1
    if not file_path:
        print("--file required", file=sys.stderr); sys.exit(1)

    local = read_working(file_path)
    if ops:
        server, _ = ops.get(uid)
    else:
        result = client.get_dashboard(uid)
        server = result["dashboard"]

    # Compare scalar fields
    diffs_found = False
    scalar_fields = ["title", "description", "tags", "timezone", "refresh", "editable",
                     "graphTooltip", "time", "timepicker"]
    print(f"\nDiff: {file_path} vs server ({uid})\n" + "=" * 72)

    for sf in scalar_fields:
        l_val = local.get(sf)
        s_val = server.get(sf)
        if not _strict_equal(l_val, s_val):
            print(f"\n  {sf}:")
            print(f"    local:  {json.dumps(l_val, ensure_ascii=False)[:100]}")
            print(f"    server: {json.dumps(s_val, ensure_ascii=False)[:100]}")
            diffs_found = True

    # Compare panels
    local_panels = {p.get("id"): p for p in local.get("panels", [])}
    server_panels = {p.get("id"): p for p in server.get("panels", [])}
    local_ids = set(local_panels.keys())
    server_ids = set(server_panels.keys())

    added = local_ids - server_ids
    removed = server_ids - local_ids
    common = local_ids & server_ids
    modified = [pid for pid in common if not _strict_equal(local_panels[pid], server_panels[pid])]

    if added or removed or modified:
        print(f"\n  Panels:")
        diffs_found = True
        if added:
            for pid in sorted(added):
                print(f"    + panel {pid}: {local_panels[pid].get('title', '?')}")
        if removed:
            for pid in sorted(removed):
                print(f"    - panel {pid}: {server_panels[pid].get('title', '?')}")
        if modified:
            for pid in sorted(modified):
                print(f"    ~ panel {pid}: {local_panels[pid].get('title', '?')}")

    # Compare variables
    local_vars = {v.get("name"): v for v in local.get("templating", {}).get("list", [])}
    server_vars = {v.get("name"): v for v in server.get("templating", {}).get("list", [])}
    l_var_names = set(local_vars.keys())
    s_var_names = set(server_vars.keys())
    var_added = l_var_names - s_var_names
    var_removed = s_var_names - l_var_names
    var_modified = [n for n in l_var_names & s_var_names if not _strict_equal(local_vars[n], server_vars[n])]

    if var_added or var_removed or var_modified:
        print(f"\n  Variables:")
        diffs_found = True
        for n in sorted(var_added):
            print(f"    + {n}")
        for n in sorted(var_removed):
            print(f"    - {n}")
        for n in sorted(var_modified):
            print(f"    ~ {n}")

    if not diffs_found:
        print("\n  No differences found.")
    print("=" * 72)


def cmd_merge(client: GrafanaClient, args: list[str], *, ops: DashboardOps | None = None, **_kw: Any) -> None:
    """Three-way merge. Usage: merge <uid> --file <path> [--base <path>] [--output <path>]"""
    if not args:
        print("Usage: merge <uid> --file <path> [--base <path>] [--output <path>]", file=sys.stderr)
        sys.exit(1)
    uid = args[0]
    file_path = base_path = output = None
    i = 1
    while i < len(args):
        if args[i] == "--file" and i + 1 < len(args):
            file_path = args[i + 1]; i += 2
        elif args[i] == "--base" and i + 1 < len(args):
            base_path = args[i + 1]; i += 2
        elif args[i] == "--output" and i + 1 < len(args):
            output = args[i + 1]; i += 2
        else:
            i += 1
    if not file_path:
        print("--file required", file=sys.stderr); sys.exit(1)

    # Ours = local file
    ours = read_working(file_path)

    # Base = explicit --base, or sidecar
    if base_path:
        base = read_working(base_path)
    else:
        base_info = read_base(file_path)
        if base_info is None:
            print("No base found. Provide --base or export with sidecar first.", file=sys.stderr)
            sys.exit(1)
        base, _ = base_info

    # Theirs = server
    if ops:
        theirs, _ = ops.get(uid)
    else:
        result = client.get_dashboard(uid)
        theirs = result["dashboard"]

    merged, conflicts = three_way_merge(base, ours, theirs)
    merged["uid"] = uid

    out_path = output or f"{uid}.merged.json"
    Path(out_path).write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n")

    if conflicts:
        print(_format_conflicts(conflicts), file=sys.stderr)
        print(f"\nMerged (with conflicts) written to: {out_path}")
        sys.exit(2)
    else:
        print(f"Clean merge written to: {out_path}")


def cmd_convert(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
    """Convert dashboard format. Usage: convert --file <path> --to <legacy|k8s> [--output <path>]"""
    file_path = to_format = output = None
    i = 0
    while i < len(args):
        if args[i] == "--file" and i + 1 < len(args):
            file_path = args[i + 1]; i += 2
        elif args[i] == "--to" and i + 1 < len(args):
            to_format = args[i + 1]; i += 2
        elif args[i] == "--output" and i + 1 < len(args):
            output = args[i + 1]; i += 2
        else:
            i += 1
    if not file_path or not to_format:
        print("Usage: convert --file <path> --to <legacy|k8s> [--output <path>]", file=sys.stderr)
        sys.exit(1)
    if to_format not in ("legacy", "k8s"):
        print(f"Unknown format: {to_format}. Use 'legacy' or 'k8s'.", file=sys.stderr)
        sys.exit(1)

    data = json.loads(Path(file_path).read_text())
    # Strip sidecar metadata if present
    data.pop("_occ_meta", None)
    current_format = detect_format(data)

    if current_format == to_format:
        print(f"File is already in {to_format} format.")
        return

    if to_format == "k8s":
        # Legacy to K8s
        # Handle wrapped legacy format
        if "dashboard" in data and "meta" in data:
            dashboard = data["dashboard"]
        else:
            dashboard = data
        result = legacy_to_k8s(dashboard)
    else:
        # K8s to legacy
        result = k8s_to_legacy(data)

    out_path = output or file_path
    Path(out_path).write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"Converted {current_format} → {to_format}: {out_path}")


def cmd_query(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
    """Execute a datasource query.

    Usage:
      query <ds_uid> --expr <promql|logql>  [options]
      query <ds_uid> --raw-sql <sql>        [options]
      query <ds_uid> --query <json>         [options]
    """
    if not args:
        print("Usage: query <ds_uid> --expr <expr> | --raw-sql <sql> | --query <json> [options]",
              file=sys.stderr)
        sys.exit(1)

    ds_uid = args[0]
    expr = raw_sql = raw_query = ds_type = ref_id = fmt = output = output_dir = None
    time_from = "now-1h"
    time_to = "now"
    max_data_points = 1000
    interval_ms = 15000
    instant = False
    preview: int | None = None
    as_json = False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--expr" and i + 1 < len(args):
            expr = args[i + 1]; i += 2
        elif a == "--raw-sql" and i + 1 < len(args):
            raw_sql = args[i + 1]; i += 2
        elif a == "--query" and i + 1 < len(args):
            raw_query = args[i + 1]; i += 2
        elif a == "--type" and i + 1 < len(args):
            ds_type = args[i + 1]; i += 2
        elif a == "--from" and i + 1 < len(args):
            time_from = args[i + 1]; i += 2
        elif a == "--to" and i + 1 < len(args):
            time_to = args[i + 1]; i += 2
        elif a == "--format" and i + 1 < len(args):
            fmt = args[i + 1]; i += 2
        elif a == "--output" and i + 1 < len(args):
            output = args[i + 1]; i += 2
        elif a == "--output-dir" and i + 1 < len(args):
            output_dir = args[i + 1]; i += 2
        elif a == "--max-data-points" and i + 1 < len(args):
            max_data_points = int(args[i + 1]); i += 2
        elif a == "--interval-ms" and i + 1 < len(args):
            interval_ms = int(args[i + 1]); i += 2
        elif a == "--ref-id" and i + 1 < len(args):
            ref_id = args[i + 1]; i += 2
        elif a == "--preview" and i + 1 < len(args):
            preview = int(args[i + 1]); i += 2
        elif a == "--instant":
            instant = True; i += 1
        elif a == "--json":
            as_json = True; i += 1
        else:
            i += 1

    if not expr and not raw_sql and not raw_query:
        print("One of --expr, --raw-sql, or --query is required.", file=sys.stderr)
        sys.exit(1)

    # Auto-detect datasource type if not specified
    if not ds_type:
        ds_info = client.get_datasource(ds_uid)
        ds_type = ds_info.get("type", "prometheus")

    # Build query object
    query: dict[str, Any] = {
        "refId": ref_id or "A",
        "datasource": {"uid": ds_uid, "type": ds_type},
        "maxDataPoints": max_data_points,
        "intervalMs": interval_ms,
    }

    if raw_query:
        query.update(json.loads(raw_query))
    elif raw_sql:
        query["rawSql"] = raw_sql
        query.setdefault("format", "table")
    elif expr:
        query["expr"] = expr
        if instant:
            query["instant"] = True
            query["range"] = False
        else:
            query["range"] = True
            query["instant"] = False

    result = client.query_datasource([query], time_from=time_from, time_to=time_to)
    _check_query_errors(result)

    ref_ids = list(result.get("results", {}).keys())
    _handle_query_output(result, ref_ids, as_json=as_json, preview=preview,
                         output=output, output_dir=output_dir, fmt=fmt)


def cmd_panel_query(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
    """Execute queries from a dashboard panel.

    Usage: panel-query <dashboard_uid> <panel_id> [options]
    """
    if len(args) < 2:
        print("Usage: panel-query <dashboard_uid> <panel_id> [options]", file=sys.stderr)
        sys.exit(1)

    dashboard_uid = args[0]
    panel_id = int(args[1])
    time_from = "now-1h"
    time_to = "now"
    variables: dict[str, str] = {}
    fmt = output = output_dir = None
    preview: int | None = None
    as_json = False
    i = 2
    while i < len(args):
        a = args[i]
        if a == "--from" and i + 1 < len(args):
            time_from = args[i + 1]; i += 2
        elif a == "--to" and i + 1 < len(args):
            time_to = args[i + 1]; i += 2
        elif a == "--var" and i + 1 < len(args):
            k, _, v = args[i + 1].partition("=")
            variables[k] = v; i += 2
        elif a == "--format" and i + 1 < len(args):
            fmt = args[i + 1]; i += 2
        elif a == "--output" and i + 1 < len(args):
            output = args[i + 1]; i += 2
        elif a == "--output-dir" and i + 1 < len(args):
            output_dir = args[i + 1]; i += 2
        elif a == "--preview" and i + 1 < len(args):
            preview = int(args[i + 1]); i += 2
        elif a == "--json":
            as_json = True; i += 1
        else:
            i += 1

    # Fetch dashboard and find panel
    dash_data = client.get_dashboard(dashboard_uid)
    panels = dash_data.get("dashboard", {}).get("panels", [])

    # Flatten row-nested panels
    all_panels: list[dict] = []
    for panel in panels:
        if panel.get("type") == "row":
            all_panels.extend(panel.get("panels", []))
        else:
            all_panels.append(panel)

    target_panel = None
    for panel in all_panels:
        if panel.get("id") == panel_id:
            target_panel = panel
            break

    if not target_panel:
        print(f"Panel {panel_id} not found in dashboard {dashboard_uid}", file=sys.stderr)
        sys.exit(1)

    targets = target_panel.get("targets", [])
    if not targets:
        print(f"Panel {panel_id} has no query targets.", file=sys.stderr)
        sys.exit(1)

    # Build queries from targets
    queries: list[dict] = []
    for idx, target in enumerate(targets):
        q = dict(target)
        q["refId"] = q.get("refId", chr(65 + idx))
        q["maxDataPoints"] = q.get("maxDataPoints", 1000)
        q["intervalMs"] = q.get("intervalMs", 15000)
        # Ensure datasource is set (panel-level or target-level)
        if "datasource" not in q and target_panel.get("datasource"):
            q["datasource"] = target_panel["datasource"]
        if variables:
            q = _resolve_variables(q, variables)
        queries.append(q)

    result = client.query_datasource(queries, time_from=time_from, time_to=time_to)
    _check_query_errors(result)

    ref_ids = list(result.get("results", {}).keys())
    _handle_query_output(result, ref_ids, as_json=as_json, preview=preview,
                         output=output, output_dir=output_dir, fmt=fmt)


def cmd_panel_list(client: GrafanaClient, args: list[str], **_kw: Any) -> None:
    """List panels in a dashboard.

    Usage: panel-list <dashboard_uid> [--json]
    """
    if not args:
        print("Usage: panel-list <dashboard_uid> [--json]", file=sys.stderr)
        sys.exit(1)

    dashboard_uid = args[0]
    as_json = "--json" in args

    dash_data = client.get_dashboard(dashboard_uid)
    panels = dash_data.get("dashboard", {}).get("panels", [])

    # Flatten row-nested panels
    all_panels: list[dict] = []
    for panel in panels:
        if panel.get("type") == "row":
            all_panels.extend(panel.get("panels", []))
        else:
            all_panels.append(panel)

    if as_json:
        _pp([{
            "id": p.get("id"),
            "title": p.get("title", ""),
            "type": p.get("type", ""),
            "datasource": p.get("datasource"),
            "targets": len(p.get("targets", [])),
        } for p in all_panels])
    else:
        print(f"\nPanels ({len(all_panels)}):\n" + "-" * 72)
        for p in all_panels:
            ds = p.get("datasource")
            ds_str = ""
            if isinstance(ds, dict):
                ds_str = ds.get("uid", ds.get("type", ""))
            elif isinstance(ds, str):
                ds_str = ds
            targets = len(p.get("targets", []))
            print(f"  {p.get('id', '?'):>4}  {p.get('title', ''):40s}  {p.get('type', ''):16s}  {ds_str}  ({targets} queries)")
        print("-" * 72)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

COMMANDS: dict[str, Any] = {
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
    "diff": cmd_diff,
    "merge": cmd_merge,
    "convert": cmd_convert,
    "query": cmd_query,
    "panel-query": cmd_panel_query,
    "panel-list": cmd_panel_list,
}

# Commands that benefit from DashboardOps
_OPS_COMMANDS = {"list", "get", "export", "create", "update", "delete", "diff", "merge"}

USAGE = """\
Grafana API CLI

USAGE: grafana.sh [options] <command> [args...]

OPTIONS (handled by wrapper):
  --url <url>            Grafana base URL (overrides GRAFANA_URL)
  --org-id <id>          Organization ID (overrides GRAFANA_ORG_ID)
  --api <auto|legacy|k8s> API mode (default: auto, overrides GRAFANA_API_MODE)
  --namespace <ns>       K8s namespace (default: default, overrides GRAFANA_NAMESPACE)
  --env-file <path>      Load env vars from file (repeatable, later wins)
  --timeout <duration>   Global timeout (default: 5m)

COMMANDS:
  health                           Check Grafana health
  list [--query q] [--tag t]       List/search dashboards
  get <uid> [--json]               Get dashboard details
  export <uid> [--output path]     Export dashboard JSON (+ base sidecar)
  create --file <path> [--folder]  Create dashboard from JSON
  update <uid> --file <path>       Update with OCC (three-way merge on conflict)
  delete <uid>                     Delete dashboard
  clone <uid> [--title t]          Clone dashboard
  versions <uid>                   List dashboard versions
  restore <uid> --version <n>      Restore dashboard version
  diff <uid> --file <path>         Structural diff: local vs server
  merge <uid> --file <path>        Three-way merge: local vs server
  convert --file <path> --to fmt   Convert between legacy and K8s format
  query <ds_uid> --expr <expr>     Query a datasource (PromQL, LogQL, etc.)
  query <ds_uid> --raw-sql <sql>   Query a SQL datasource
  query <ds_uid> --query <json>    Query with raw JSON body
  panel-query <dash> <panel_id>    Execute queries from a dashboard panel
  panel-list <dash_uid>            List panels in a dashboard
  folders [--json]                 List folders
  datasources [--json]             List datasources
  annotations [--dashboard uid]    Query annotations
  alerts [--active] [--json]       List alert rules / active alerts
  user                             Current user info
  org                              Current org info
  raw <METHOD> <endpoint>          Raw API call

ENVIRONMENT:
  GRAFANA_URL        Grafana base URL (e.g. https://myinstance.grafana.net)
  GRAFANA_TOKEN      Service account token
  GRAFANA_ORG_ID     Organization ID (optional)
  GRAFANA_API_MODE   API mode: auto, legacy, k8s (default: auto)
  GRAFANA_NAMESPACE  K8s namespace (default: default)

EXIT CODES:
  0   Success
  1   Error (invalid args, API error, missing prerequisites)
  2   Unresolved merge conflicts
  124 Timeout (killed by gtimeout)
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
    api_mode = os.environ.get("GRAFANA_API_MODE", "auto")
    namespace = os.environ.get("GRAFANA_NAMESPACE", "default")

    client = GrafanaClient(base_url, token, org_id=org_id)

    command_name = args[0]
    command_args = args[1:]

    if command_name not in COMMANDS:
        print(f"Unknown command: {command_name}\n", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        sys.exit(1)

    # Build DashboardOps for commands that need it
    extra_kwargs: dict[str, Any] = {}
    if command_name in _OPS_COMMANDS:
        ops = DashboardOps(client, api_mode=api_mode, namespace=namespace)
        extra_kwargs["ops"] = ops

    try:
        COMMANDS[command_name](client, command_args, **extra_kwargs)
    except GrafanaAPIError as exc:
        print(f"ERROR [{exc.status_code}]: {exc.message}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
