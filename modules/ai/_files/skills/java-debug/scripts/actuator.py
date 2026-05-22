#!/usr/bin/env python3
"""Spring Boot Actuator CLI client. Stdlib-only."""

from __future__ import annotations

import argparse
import base64
import configparser
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional, Union

DEFAULT_TIMEOUT = 30
DEFAULT_PROBE_TIMEOUT = 2
DEFAULT_CACHE_TTL = 60
MAX_LINES_DEFAULT = 500
MAX_BYTES_DEFAULT = 50_000
AUTH_CMD_TIMEOUT = 10

PROBE_CANDIDATES = [
    "http://localhost:8080/actuator",
    "http://localhost:8081/actuator",
    "http://localhost:8080/management",
    "http://localhost:8081/management",
    "http://localhost:9090/actuator",
    "http://localhost:9001/actuator",
    "http://localhost:9001/management",
]

GENERIC_ENDPOINTS = {"caches", "sessions", "flyway", "liquibase", "quartz", "sbom"}


@dataclass
class Config:
    """Bundle of resolved global flags. Secrets never stored here."""

    base: Optional[str] = None
    host: Optional[str] = None
    port: Optional[int] = None
    base_path: Optional[str] = None
    scheme: Optional[str] = None
    bearer: Optional[str] = None
    bearer_cmd: Optional[str] = None
    basic: Optional[str] = None
    basic_cmd: Optional[str] = None
    header: Optional[str] = None
    header_cmd: Optional[list[str]] = None
    cacert: Optional[str] = None
    insecure: bool = False
    timeout: int = DEFAULT_TIMEOUT
    probe_timeout: int = DEFAULT_PROBE_TIMEOUT
    no_cache: bool = False
    verbose: bool = False
    output: Optional[str] = None
    max_lines: int = MAX_LINES_DEFAULT
    max_bytes: int = MAX_BYTES_DEFAULT
    extra_headers: list[tuple[str, str]] = field(default_factory=list)


# --- cache ----------------------------------------------------------------


def _cache_path() -> Path:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return Path(runtime_dir) / "actuator-base"


def _read_cached_base(ttl: int = DEFAULT_CACHE_TTL) -> Optional[str]:
    path = _cache_path()
    try:
        stat = path.stat()
    except OSError:
        return None
    if time.time() - stat.st_mtime > ttl:
        return None
    try:
        return path.read_text().strip() or None
    except OSError:
        return None


def _write_cached_base(base_url: str) -> None:
    # Best-effort; cache failures must not break the command.
    try:
        _cache_path().write_text(base_url + "\n")
    except OSError:
        pass


# --- base url resolution --------------------------------------------------


def _probe_base(candidate: str, probe_timeout: int, verbose: bool) -> bool:
    url = candidate.rstrip("/") + "/health"
    request = urllib.request.Request(url, method="HEAD")
    if verbose:
        sys.stderr.write(f"probe: HEAD {url}\n")
    try:
        with urllib.request.urlopen(request, timeout=probe_timeout) as response:
            return response.status in (200, 401, 403)
    except urllib.error.HTTPError as error:
        return error.code in (200, 401, 403)
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def resolve_base(config: Config) -> str:
    if config.base:
        return config.base.rstrip("/")

    if any(value is not None for value in (config.scheme, config.host, config.port, config.base_path)):
        scheme = config.scheme or "http"
        host = config.host or "localhost"
        port = config.port if config.port is not None else 8080
        path = config.base_path or "/actuator"
        if not path.startswith("/"):
            path = "/" + path
        return f"{scheme}://{host}:{port}{path}".rstrip("/")

    env_base = os.environ.get("ACTUATOR_BASE")
    if env_base:
        return env_base.rstrip("/")

    if not config.no_cache:
        cached = _read_cached_base()
        if cached:
            if config.verbose:
                sys.stderr.write(f"base: using cached {cached}\n")
            return cached

    for candidate in PROBE_CANDIDATES:
        if _probe_base(candidate, config.probe_timeout, config.verbose):
            if config.verbose:
                sys.stderr.write(f"base: probed match {candidate}\n")
            if not config.no_cache:
                _write_cached_base(candidate)
            return candidate

    tried = ", ".join(PROBE_CANDIDATES)
    sys.stderr.write(
        f"no Actuator base found; tried {tried}. "
        "Hints: --base URL, --host/--port/--base-path, ACTUATOR_BASE env var, "
        "or check management.endpoints.web.base-path / management.server.port "
        "in your application config.\n"
    )
    sys.exit(1)


# --- auth resolution ------------------------------------------------------


_BASE64_LINE = re.compile(r"^[A-Za-z0-9+/=]{21,}$")


def _scan_cmd_stderr_for_secrets(stderr_text: str) -> bool:
    for line in stderr_text.splitlines():
        if _BASE64_LINE.match(line.strip()):
            return True
    return False


def _run_auth_cmd(cmd: str, source_label: str) -> str:
    try:
        result = subprocess.run(
            ["/bin/sh", "-c", cmd],
            capture_output=True,
            text=True,
            timeout=AUTH_CMD_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        sys.stderr.write(f"error: auth command timed out ({source_label})\n")
        sys.exit(4)
    if result.stderr:
        # Preserve user's ability to debug failing commands (vault/op/pass).
        if _scan_cmd_stderr_for_secrets(result.stderr):
            sys.stderr.write(
                "[auth cmd stderr may contain secret-looking content "
                "— review before sharing]\n"
            )
        for line in result.stderr.splitlines():
            sys.stderr.write(f"[auth cmd stderr] {line}\n")
    if result.returncode != 0:
        sys.stderr.write(
            f"error: auth command failed with exit {result.returncode} "
            f"({source_label})\n"
        )
        sys.exit(4)
    return result.stdout.rstrip("\r\n\t ")


def _basic_header_value(user_pass: str) -> str:
    encoded = base64.b64encode(user_pass.encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def _split_header(raw: str) -> tuple[str, str]:
    if ":" not in raw:
        sys.stderr.write(f"error: malformed header value (missing ':'): {raw!r}\n")
        sys.exit(1)
    name, _, value = raw.partition(":")
    return name.strip(), value.strip()


def _credentials_file_path() -> Path:
    explicit = os.environ.get("ACTUATOR_CREDENTIALS")
    if explicit:
        return Path(explicit)
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(xdg) / "java-debug" / "actuator-credentials"


def _credentials_section_for(parser: configparser.ConfigParser, base_url: str) -> Optional[str]:
    best: Optional[str] = None
    for section in parser.sections():
        if base_url == section or base_url.startswith(section):
            if best is None or len(section) > len(best):
                best = section
    return best


def _resolve_from_credentials_file(base_url: str, verbose: bool) -> Optional[tuple[str, str, str]]:
    path = _credentials_file_path()
    try:
        mode = path.stat().st_mode
    except FileNotFoundError:
        return None
    except OSError as error:
        sys.stderr.write(f"error: cannot stat credentials file {path}: {error}\n")
        return None
    if mode & 0o077:
        sys.stderr.write(
            f"refusing to read credentials with mode {mode & 0o777:o}; "
            f"chmod 600 {path}\n"
        )
        return None
    parser = configparser.ConfigParser(strict=True)
    parser.optionxform = str  # type: ignore[assignment]
    try:
        parser.read(path)
    except (OSError, configparser.Error) as error:
        sys.stderr.write(f"error: cannot parse credentials file {path}: {error}\n")
        return None
    section = _credentials_section_for(parser, base_url)
    if section is None:
        return None
    options = {key: parser.get(section, key) for key in parser.options(section)}
    label = f"credentials file [section: {section}]"
    if "bearer" in options:
        return ("Authorization", f"Bearer {options['bearer']}", label)
    if "bearer-cmd" in options:
        token = _run_auth_cmd(options["bearer-cmd"], label)
        return ("Authorization", f"Bearer {token}", label)
    if "basic" in options:
        return ("Authorization", _basic_header_value(options["basic"]), label)
    if "basic-cmd" in options:
        creds = _run_auth_cmd(options["basic-cmd"], label)
        return ("Authorization", _basic_header_value(creds), label)
    if "header" in options:
        name, value = _split_header(options["header"])
        return (name, value, label)
    if "header-cmd" in options:
        # Section value form: "Header-Name: <shell-command>"
        name, command = _split_header(options["header-cmd"])
        value = _run_auth_cmd(command, label)
        return (name, value, label)
    return None


def resolve_auth(config: Config, base_url: str) -> tuple[Optional[tuple[str, str]], str]:
    """Returns ((header_name, header_value) or None, source_label)."""

    if config.bearer:
        return (("Authorization", f"Bearer {config.bearer}"), "--bearer flag")
    if config.bearer_cmd:
        token = _run_auth_cmd(config.bearer_cmd, "--bearer-cmd flag")
        return (("Authorization", f"Bearer {token}"), "--bearer-cmd flag")
    if config.basic:
        return (("Authorization", _basic_header_value(config.basic)), "--basic flag")
    if config.basic_cmd:
        creds = _run_auth_cmd(config.basic_cmd, "--basic-cmd flag")
        return (("Authorization", _basic_header_value(creds)), "--basic-cmd flag")
    if config.header:
        name, value = _split_header(config.header)
        return ((name, value), "--header flag")
    if config.header_cmd:
        header_name_raw, command = config.header_cmd
        name = header_name_raw.rstrip(":").strip()
        value = _run_auth_cmd(command, "--header-cmd flag")
        return ((name, value), "--header-cmd flag")

    env = os.environ
    if env.get("ACTUATOR_BEARER"):
        return (("Authorization", f"Bearer {env['ACTUATOR_BEARER']}"), "ACTUATOR_BEARER env")
    if env.get("ACTUATOR_BEARER_CMD"):
        token = _run_auth_cmd(env["ACTUATOR_BEARER_CMD"], "ACTUATOR_BEARER_CMD env")
        return (("Authorization", f"Bearer {token}"), "ACTUATOR_BEARER_CMD env")
    if env.get("ACTUATOR_BASIC"):
        return (
            ("Authorization", _basic_header_value(env["ACTUATOR_BASIC"])),
            "ACTUATOR_BASIC env",
        )
    if env.get("ACTUATOR_BASIC_CMD"):
        creds = _run_auth_cmd(env["ACTUATOR_BASIC_CMD"], "ACTUATOR_BASIC_CMD env")
        return (
            ("Authorization", _basic_header_value(creds)),
            "ACTUATOR_BASIC_CMD env",
        )
    if env.get("ACTUATOR_AUTH_HEADER"):
        name, value = _split_header(env["ACTUATOR_AUTH_HEADER"])
        return ((name, value), "ACTUATOR_AUTH_HEADER env")
    if env.get("ACTUATOR_AUTH_HEADER_CMD"):
        name, value = _split_header(_run_auth_cmd(
            env["ACTUATOR_AUTH_HEADER_CMD"], "ACTUATOR_AUTH_HEADER_CMD env"))
        return ((name, value), "ACTUATOR_AUTH_HEADER_CMD env")

    file_result = _resolve_from_credentials_file(base_url, config.verbose)
    if file_result is not None:
        name, value, label = file_result
        return ((name, value), label)

    return (None, "none")


# --- http -----------------------------------------------------------------


_AUTHISH_HEADER_NAMES = {"authorization", "proxy-authorization", "cookie", "x-api-key"}


def _build_ssl_context(insecure: bool, cacert: Optional[str]) -> Optional[ssl.SSLContext]:
    if not insecure and not cacert:
        return None
    context = ssl.create_default_context(cafile=cacert)
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        sys.stderr.write("warning: TLS verification disabled (--insecure)\n")
    return context


def _http(
    method: str,
    url: str,
    *,
    body: Optional[bytes] = None,
    timeout: int = DEFAULT_TIMEOUT,
    accept: str = "application/json",
    content_type: Optional[str] = None,
    auth_header: Optional[tuple[str, str]] = None,
    extra_headers: Optional[list[tuple[str, str]]] = None,
    stream_to_file: Optional[str] = None,
    insecure: bool = False,
    cacert: Optional[str] = None,
    verbose: bool = False,
) -> Union[dict, list, str, bytes, int]:
    headers = {"Accept": accept}
    if content_type:
        headers["Content-Type"] = content_type
    if auth_header is not None:
        headers[auth_header[0]] = auth_header[1]
    if extra_headers:
        for name, value in extra_headers:
            headers[name] = value

    if verbose:
        # Strip authorization-class headers from the log to avoid leakage.
        safe = {k: v for k, v in headers.items() if k.lower() not in _AUTHISH_HEADER_NAMES}
        sys.stderr.write(f"http: {method} {url} headers={safe}\n")

    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    context = _build_ssl_context(insecure, cacert)

    try:
        if context is not None:
            response = urllib.request.urlopen(request, timeout=timeout, context=context)
        else:
            response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        sys.stderr.write(f"error: HTTP {error.code} {error.reason} at {url}\n")
        if error.code in (401, 403):
            sys.stderr.write(
                "auth required: try --bearer-cmd / ACTUATOR_BEARER_CMD / credentials file\n"
            )
        sys.exit(3)
    except urllib.error.URLError as error:
        sys.stderr.write(f"error: HTTP request failed at {url}: {error.reason}\n")
        sys.exit(3)
    except TimeoutError:
        sys.stderr.write(f"error: HTTP request timed out at {url}\n")
        sys.exit(3)

    with response:
        if stream_to_file is not None:
            total = 0
            with open(stream_to_file, "wb") as handle:
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    handle.write(chunk)
                    total += len(chunk)
            return total

        payload = response.read()
        ctype = response.headers.get("Content-Type", "")
        if "application/json" in ctype or "application/vnd.spring-boot.actuator" in ctype:
            if not payload:
                return {}
            try:
                return json.loads(payload)
            except json.JSONDecodeError:
                return payload.decode("utf-8", errors="replace")
        return payload


# --- emit -----------------------------------------------------------------


def _serialize_content(content: Any, format_hint: str) -> tuple[str, str]:
    """Returns (serialized_text, extension)."""

    if isinstance(content, bytes):
        return (content.decode("utf-8", errors="replace"), "txt")
    if isinstance(content, str):
        return (content, "txt")
    if isinstance(content, list):
        lines = []
        for entry in content:
            if isinstance(entry, (dict, list)):
                lines.append(json.dumps(entry, separators=(",", ":"), sort_keys=False))
            else:
                lines.append(json.dumps(entry))
        return ("\n".join(lines) + ("\n" if lines else ""), "json")
    if isinstance(content, dict):
        return (json.dumps(content, indent=2, sort_keys=False) + "\n", "json")
    return (str(content), "txt")


def _emit(
    content: Any,
    subcommand: str,
    output_file: Optional[str] = None,
    max_lines: int = MAX_LINES_DEFAULT,
    max_bytes: int = MAX_BYTES_DEFAULT,
    format_hint: str = "json",
) -> None:
    text, extension = _serialize_content(content, format_hint)
    byte_count = len(text.encode("utf-8"))
    lines = text.splitlines()
    line_count = len(lines)

    if output_file:
        try:
            Path(output_file).write_text(text)
        except OSError as error:
            sys.stderr.write(f"error: cannot write --output {output_file}: {error}\n")
            sys.exit(1)
        sys.stdout.write(f"wrote {line_count} lines ({byte_count} bytes) to {output_file}\n")
        return

    if line_count <= max_lines and byte_count <= max_bytes:
        sys.stdout.write(text)
        if text and not text.endswith("\n"):
            sys.stdout.write("\n")
        return

    timestamp = int(time.time())
    spill_path = f"/tmp/actuator-{subcommand}-{timestamp}.{extension}"
    try:
        Path(spill_path).write_text(text)
    except OSError as error:
        sys.stderr.write(f"error: cannot spill output to {spill_path}: {error}\n")
        sys.exit(1)

    head = lines[:100]
    tail = lines[-20:] if line_count > 120 else []
    omitted = line_count - len(head) - len(tail)
    for line in head:
        sys.stdout.write(line + "\n")
    sys.stdout.write(
        f"... [{omitted} lines / {byte_count} bytes omitted, full output at {spill_path}] ...\n"
    )
    for line in tail:
        sys.stdout.write(line + "\n")


# --- subcommand: health ---------------------------------------------------


def cmd_health(config: Config, args, base_url: str, auth_header) -> None:
    component = getattr(args, "component", None)
    path = "/health"
    if component:
        path = f"/health/{component}"
    payload = _http(
        "GET", base_url + path,
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    if args.full or not isinstance(payload, dict):
        _emit(payload, "health", config.output, config.max_lines, config.max_bytes)
        return

    projection: dict[str, Any] = {"status": payload.get("status")}
    components = payload.get("components") or payload.get("details")
    if isinstance(components, dict):
        projected: dict[str, Any] = {}
        for name, info in components.items():
            if not isinstance(info, dict):
                projected[name] = {"status": info}
                continue
            entry: dict[str, Any] = {"status": info.get("status")}
            details = info.get("details")
            if isinstance(details, dict) and "error" in details:
                entry["error"] = details["error"]
            elif "error" in info:
                entry["error"] = info["error"]
            projected[name] = entry
        projection["components"] = projected
    _emit(projection, "health", config.output, config.max_lines, config.max_bytes)


# --- subcommand: info -----------------------------------------------------


def cmd_info(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/info",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    _emit(payload, "info", config.output, config.max_lines, config.max_bytes)


# --- subcommand: beans ----------------------------------------------------


def cmd_beans(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/beans",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    grep_pattern = re.compile(args.grep, re.IGNORECASE) if args.grep else None
    scope_filter = args.scope

    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        contexts = payload.get("contexts") or {}
        for context_name, context_data in contexts.items():
            beans = (context_data or {}).get("beans") or {}
            for bean_name, bean_info in beans.items():
                if grep_pattern and not grep_pattern.search(bean_name):
                    continue
                bean_scope = (bean_info or {}).get("scope")
                if scope_filter and bean_scope != scope_filter:
                    continue
                rows.append({
                    "context": context_name,
                    "name": bean_name,
                    "scope": bean_scope,
                    "type": (bean_info or {}).get("type"),
                    "deps": (bean_info or {}).get("dependencies") or [],
                })
    rows.sort(key=lambda row: (row["context"], row["name"]))
    _emit(rows, "beans", config.output, config.max_lines, config.max_bytes)


# --- subcommand: conditions -----------------------------------------------


def _project_conditions(entries: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    if isinstance(entries, list):
        for entry in entries:
            if isinstance(entry, dict):
                result.append({
                    "condition": entry.get("condition"),
                    "message": entry.get("message"),
                })
            else:
                result.append({"value": entry})
    return result


def _project_negative(entries: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    if isinstance(entries, dict):
        for key, value in entries.items():
            not_matched = (value or {}).get("notMatched") or []
            matched = (value or {}).get("matched") or []
            result.append({
                "class": key,
                "notMatched": _project_conditions(not_matched),
                "matched": _project_conditions(matched),
            })
    return result


def cmd_conditions(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/conditions",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )

    show_matched = args.matched
    show_unmatched = args.unmatched
    show_negative = args.negative
    if not (show_matched or show_unmatched or show_negative):
        show_unmatched = True

    if not isinstance(payload, dict):
        _emit(payload, "conditions", config.output, config.max_lines, config.max_bytes)
        return

    contexts = payload.get("contexts") or {}

    output_lines: list[str] = []
    selections: list[tuple[str, str]] = []
    if show_matched:
        selections.append(("matched", "positiveMatches"))
    if show_unmatched:
        selections.append(("unmatched", "negativeMatches"))
    if show_negative:
        selections.append(("unconditional", "unconditionalClasses"))

    multi = len(selections) > 1

    for label, key in selections:
        rows: list[dict[str, Any]] = []
        for context_name, context_data in contexts.items():
            section = (context_data or {}).get(key)
            if key == "positiveMatches" and isinstance(section, dict):
                for class_name, matches in section.items():
                    rows.append({
                        "context": context_name,
                        "class": class_name,
                        "matched": _project_conditions(matches),
                    })
            elif key == "negativeMatches" and isinstance(section, dict):
                for entry in _project_negative(section):
                    entry["context"] = context_name
                    rows.append(entry)
            elif key == "unconditionalClasses" and isinstance(section, list):
                for class_name in section:
                    rows.append({"context": context_name, "class": class_name})
        if multi:
            output_lines.append(f"--- {label} ---")
        for row in rows:
            output_lines.append(json.dumps(row, separators=(",", ":")))

    text = "\n".join(output_lines) + ("\n" if output_lines else "")
    _emit(text, "conditions", config.output, config.max_lines, config.max_bytes)


# --- subcommand: env ------------------------------------------------------


def cmd_env(config: Config, args, base_url: str, auth_header) -> None:
    if args.property_name:
        encoded = urllib.parse.quote(args.property_name, safe="")
        payload = _http(
            "GET", f"{base_url}/env/{encoded}",
            timeout=config.timeout, auth_header=auth_header,
            extra_headers=config.extra_headers,
            insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
        )
        if isinstance(payload, dict):
            sources = payload.get("propertySources") or []
            if args.source:
                sources = [src for src in sources if (src or {}).get("name") == args.source]
            projected = {
                "property": args.property_name,
                "sources": [
                    {"name": (src or {}).get("name"), "value": (src or {}).get("property", {}).get("value")
                     if isinstance(src.get("property"), dict) else (src or {}).get("value")}
                    for src in sources
                ],
                "activeProfiles": payload.get("activeProfiles"),
                "defaultProfiles": payload.get("defaultProfiles"),
            }
            _emit(projected, "env", config.output, config.max_lines, config.max_bytes)
            return
        _emit(payload, "env", config.output, config.max_lines, config.max_bytes)
        return

    payload = _http(
        "GET", base_url + "/env",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    if not isinstance(payload, dict):
        _emit(payload, "env", config.output, config.max_lines, config.max_bytes)
        return

    sources = payload.get("propertySources") or []
    if args.grep:
        grep_pattern = re.compile(args.grep, re.IGNORECASE)
        matches: list[dict[str, Any]] = []
        for source in sources:
            source_name = (source or {}).get("name")
            if args.source and source_name != args.source:
                continue
            properties = (source or {}).get("properties") or {}
            for prop_name, prop_info in properties.items():
                if grep_pattern.search(prop_name):
                    value = prop_info.get("value") if isinstance(prop_info, dict) else prop_info
                    matches.append({"source": source_name, "name": prop_name, "value": value})
        _emit(matches, "env", config.output, config.max_lines, config.max_bytes)
        return

    summary = {
        "activeProfiles": payload.get("activeProfiles"),
        "defaultProfiles": payload.get("defaultProfiles"),
        "propertySources": [
            (src or {}).get("name") for src in sources
            if not args.source or (src or {}).get("name") == args.source
        ],
    }
    _emit(summary, "env", config.output, config.max_lines, config.max_bytes)


# --- subcommand: configprops ----------------------------------------------


def cmd_configprops(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/configprops",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    grep_pattern = re.compile(args.grep, re.IGNORECASE) if args.grep else None
    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        contexts = payload.get("contexts") or {}
        for context_name, context_data in contexts.items():
            beans = (context_data or {}).get("beans") or {}
            for bean_name, bean_info in beans.items():
                prefix = (bean_info or {}).get("prefix")
                if grep_pattern and (prefix is None or not grep_pattern.search(prefix)):
                    continue
                rows.append({
                    "context": context_name,
                    "name": bean_name,
                    "prefix": prefix,
                    "properties": (bean_info or {}).get("properties") or {},
                })
    rows.sort(key=lambda row: (row["context"], row.get("prefix") or "", row["name"]))
    _emit(rows, "configprops", config.output, config.max_lines, config.max_bytes)


# --- subcommand: mappings -------------------------------------------------


def _flatten_servlet_mappings(servlets: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for _servlet_name, mappings in servlets.items():
        if not isinstance(mappings, list):
            continue
        for mapping in mappings:
            details = (mapping or {}).get("details") or {}
            handler = (mapping or {}).get("handler")
            request_mapping = details.get("requestMappingConditions") or {}
            methods = request_mapping.get("methods") or []
            patterns = request_mapping.get("patterns") or []
            media_types = request_mapping.get("produces") or []
            if not patterns:
                rows.append({
                    "method": ",".join(methods) if methods else None,
                    "path": (mapping or {}).get("predicate"),
                    "handler": handler,
                })
                continue
            for pattern in patterns:
                for method in (methods or [None]):
                    row: dict[str, Any] = {
                        "method": method,
                        "path": pattern,
                        "handler": handler,
                    }
                    if media_types:
                        row["mediaTypes"] = [
                            (mt or {}).get("mediaType") if isinstance(mt, dict) else mt
                            for mt in media_types
                        ]
                    rows.append(row)
    return rows


def _flatten_handler_mappings(handlers: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for _handler_name, mappings in handlers.items():
        if not isinstance(mappings, list):
            continue
        for mapping in mappings:
            details = (mapping or {}).get("details") or {}
            handler = (mapping or {}).get("handler")
            request_mapping = details.get("requestMappingConditions") or {}
            methods = request_mapping.get("methods") or []
            patterns = request_mapping.get("patterns") or []
            if not patterns:
                rows.append({
                    "method": ",".join(methods) if methods else None,
                    "path": (mapping or {}).get("predicate"),
                    "handler": handler,
                })
                continue
            for pattern in patterns:
                for method in (methods or [None]):
                    rows.append({
                        "method": method,
                        "path": pattern,
                        "handler": handler,
                    })
    return rows


def cmd_mappings(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/mappings",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )

    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        contexts = payload.get("contexts") or {}
        for _context_name, context_data in contexts.items():
            mappings_block = (context_data or {}).get("mappings") or {}
            servlets = mappings_block.get("dispatcherServlets") or {}
            if isinstance(servlets, dict):
                rows.extend(_flatten_servlet_mappings(servlets))
            handlers = mappings_block.get("dispatcherHandlers") or {}
            if isinstance(handlers, dict):
                rows.extend(_flatten_handler_mappings(handlers))

    rows.sort(key=lambda row: (str(row.get("path") or ""), str(row.get("method") or "")))
    _emit(rows, "mappings", config.output, config.max_lines, config.max_bytes)


# --- subcommand: metrics --------------------------------------------------


def cmd_metrics(config: Config, args, base_url: str, auth_header) -> None:
    if not args.name:
        payload = _http(
            "GET", base_url + "/metrics",
            timeout=config.timeout, auth_header=auth_header,
            extra_headers=config.extra_headers,
            insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
        )
        names = []
        if isinstance(payload, dict):
            names = sorted(payload.get("names") or [])
        _emit({"names": names}, "metrics", config.output, config.max_lines, config.max_bytes)
        return

    query_parts = []
    for tag in (args.tag or []):
        if "=" not in tag:
            sys.stderr.write(f"error: --tag must be k=v form, got {tag!r}\n")
            sys.exit(1)
        key, _, value = tag.partition("=")
        query_parts.append("tag=" + urllib.parse.quote(f"{key}:{value}", safe=":"))
    suffix = ("?" + "&".join(query_parts)) if query_parts else ""
    url = f"{base_url}/metrics/{urllib.parse.quote(args.name, safe='')}{suffix}"
    payload = _http(
        "GET", url,
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    if isinstance(payload, dict):
        projection = {
            "name": payload.get("name"),
            "description": payload.get("description"),
            "baseUnit": payload.get("baseUnit"),
            "measurements": payload.get("measurements") or [],
            "availableTags": payload.get("availableTags") or [],
        }
        _emit(projection, "metrics", config.output, config.max_lines, config.max_bytes)
        return
    _emit(payload, "metrics", config.output, config.max_lines, config.max_bytes)


# --- subcommand: loggers --------------------------------------------------


def cmd_loggers(config: Config, args, base_url: str, auth_header) -> None:
    if args.level:
        encoded = urllib.parse.quote(args.name, safe="")
        body = json.dumps({"configuredLevel": args.level}).encode("utf-8")
        _http(
            "POST", f"{base_url}/loggers/{encoded}",
            body=body,
            content_type="application/json",
            timeout=config.timeout, auth_header=auth_header,
            extra_headers=config.extra_headers,
            insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
        )
        sys.stdout.write(f"ok: set logger {args.name} configuredLevel={args.level}\n")
        return

    if args.name:
        encoded = urllib.parse.quote(args.name, safe="")
        payload = _http(
            "GET", f"{base_url}/loggers/{encoded}",
            timeout=config.timeout, auth_header=auth_header,
            extra_headers=config.extra_headers,
            insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
        )
        if isinstance(payload, dict):
            projection = {
                "name": args.name,
                "configuredLevel": payload.get("configuredLevel"),
                "effectiveLevel": payload.get("effectiveLevel"),
            }
            _emit(projection, "loggers", config.output, config.max_lines, config.max_bytes)
            return
        _emit(payload, "loggers", config.output, config.max_lines, config.max_bytes)
        return

    payload = _http(
        "GET", base_url + "/loggers",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        loggers = payload.get("loggers") or {}
        for name, info in loggers.items():
            rows.append({
                "name": name,
                "configuredLevel": (info or {}).get("configuredLevel"),
                "effectiveLevel": (info or {}).get("effectiveLevel"),
            })
    rows.sort(key=lambda row: row["name"])
    _emit(rows, "loggers", config.output, config.max_lines, config.max_bytes)


# --- subcommand: threaddump -----------------------------------------------


def cmd_threaddump(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/threaddump",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    grep_pattern = re.compile(args.grep, re.IGNORECASE) if args.grep else None

    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        threads = payload.get("threads") or []
        for thread in threads:
            if not isinstance(thread, dict):
                continue
            name = thread.get("threadName") or thread.get("name")
            state = thread.get("threadState") or thread.get("state")
            if grep_pattern and (name is None or not grep_pattern.search(name)):
                continue
            if args.state and state != args.state:
                continue
            stack = thread.get("stackTrace") or thread.get("stack") or []
            top_frames = []
            for frame in stack[:5]:
                if isinstance(frame, dict):
                    cls = frame.get("className")
                    method = frame.get("methodName")
                    line = frame.get("lineNumber")
                    top_frames.append(f"{cls}.{method}:{line}")
                else:
                    top_frames.append(str(frame))
            entry = {
                "name": name,
                "id": thread.get("threadId") or thread.get("id"),
                "state": state,
                "stack": top_frames,
            }
            if thread.get("lockName"):
                entry["lockName"] = thread.get("lockName")
            if thread.get("lockOwnerName"):
                entry["lockOwnerName"] = thread.get("lockOwnerName")
            rows.append(entry)
    _emit(rows, "threaddump", config.output, config.max_lines, config.max_bytes)


# --- subcommand: heapdump -------------------------------------------------


def cmd_heapdump(config: Config, args, base_url: str, auth_header) -> None:
    total = _http(
        "GET", base_url + "/heapdump",
        timeout=max(config.timeout, 300),
        accept="application/octet-stream",
        auth_header=auth_header,
        extra_headers=config.extra_headers,
        stream_to_file=args.path,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    sys.stdout.write(f"wrote {total} bytes to {args.path}\n")


# --- subcommand: scheduledtasks -------------------------------------------


def cmd_scheduledtasks(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/scheduledtasks",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        for category in ("cron", "fixedDelay", "fixedRate", "custom"):
            entries = payload.get(category) or []
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                row: dict[str, Any] = {
                    "type": category,
                    "runnable": (entry.get("runnable") or {}).get("target"),
                }
                if "expression" in entry:
                    row["expression"] = entry.get("expression")
                if "initialDelay" in entry:
                    row["initialDelay"] = entry.get("initialDelay")
                if "interval" in entry:
                    row["interval"] = entry.get("interval")
                rows.append(row)
    _emit(rows, "scheduledtasks", config.output, config.max_lines, config.max_bytes)


# --- subcommand: startup --------------------------------------------------


def cmd_startup(config: Config, args, base_url: str, auth_header) -> None:
    payload = _http(
        "GET", base_url + "/startup",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    rows: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        timeline = payload.get("timeline") or {}
        events = timeline.get("events") if isinstance(timeline, dict) else None
        if events is None:
            events = payload.get("events") or []
        for event in events or []:
            if not isinstance(event, dict):
                continue
            step = event.get("startupStep") or {}
            row = {
                "name": step.get("name") if isinstance(step, dict) else None,
                "startTime": event.get("startTime"),
                "duration": event.get("duration"),
            }
            tags = step.get("tags") if isinstance(step, dict) else None
            if tags:
                row["tags"] = tags
            rows.append(row)
    rows.sort(key=lambda row: str(row.get("startTime") or ""))
    _emit(rows, "startup", config.output, config.max_lines, config.max_bytes)


# --- generic catch-all ----------------------------------------------------


def cmd_generic(config: Config, args, base_url: str, auth_header) -> None:
    endpoint = args.endpoint
    payload = _http(
        "GET", f"{base_url}/{endpoint}",
        timeout=config.timeout, auth_header=auth_header,
        extra_headers=config.extra_headers,
        insecure=config.insecure, cacert=config.cacert, verbose=config.verbose,
    )
    _emit(payload, endpoint, config.output, config.max_lines, config.max_bytes)


# --- argparse glue --------------------------------------------------------


def _add_global_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base", help="Full base URL, e.g. http://host:8080/actuator")
    parser.add_argument("--host", help="Hostname (compose mode)")
    parser.add_argument("--port", type=int, help="Port (compose mode)")
    parser.add_argument("--base-path", help="Actuator base path (compose mode)")
    parser.add_argument("--scheme", choices=("http", "https"), help="Scheme (compose mode)")
    parser.add_argument("--bearer", help="Bearer token (avoid; prefer --bearer-cmd)")
    parser.add_argument("--bearer-cmd", help="Shell command producing a bearer token on stdout")
    parser.add_argument("--basic", help="user:pass credentials")
    parser.add_argument("--basic-cmd", help="Shell command producing user:pass on stdout")
    parser.add_argument("--header", help="Raw header 'Name: Value'")
    parser.add_argument(
        "--header-cmd", nargs=2, metavar=("NAME:", "CMD"),
        help="Header name and shell command producing the value",
    )
    parser.add_argument("--cacert", help="Path to CA certificate bundle")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                        help=f"HTTP timeout seconds (default {DEFAULT_TIMEOUT})")
    parser.add_argument("--probe-timeout", type=int, default=DEFAULT_PROBE_TIMEOUT,
                        help=f"Auto-probe timeout seconds (default {DEFAULT_PROBE_TIMEOUT})")
    parser.add_argument("--no-cache", action="store_true", help="Skip base-URL cache")
    parser.add_argument("--verbose", action="store_true", help="Verbose stderr logging")
    parser.add_argument("--output", help="Write full output to FILE instead of stdout/spill")
    parser.add_argument("--max-lines", type=int, default=MAX_LINES_DEFAULT,
                        help=f"Spill threshold lines (default {MAX_LINES_DEFAULT})")
    parser.add_argument("--max-bytes", type=int, default=MAX_BYTES_DEFAULT,
                        help=f"Spill threshold bytes (default {MAX_BYTES_DEFAULT})")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="actuator.py",
        description="Spring Boot Actuator CLI client (stdlib-only).",
    )
    _add_global_options(parser)

    subparsers = parser.add_subparsers(dest="subcommand", metavar="<subcommand>")

    health_parser = subparsers.add_parser("health", usage="actuator.py health [--component NAME] [--full]")
    health_parser.add_argument("--component", help="Specific health component")
    health_parser.add_argument("--full", action="store_true", help="Emit raw JSON")

    subparsers.add_parser("info", usage="actuator.py info")

    beans_parser = subparsers.add_parser("beans", usage="actuator.py beans [--grep PATTERN] [--scope SCOPE]")
    beans_parser.add_argument("--grep", help="Regex on bean name (case-insensitive)")
    beans_parser.add_argument("--scope", help="Exact-match scope filter")

    cond_parser = subparsers.add_parser(
        "conditions", usage="actuator.py conditions [--matched] [--unmatched] [--negative]")
    cond_parser.add_argument("--matched", action="store_true")
    cond_parser.add_argument("--unmatched", action="store_true")
    cond_parser.add_argument("--negative", action="store_true")

    env_parser = subparsers.add_parser(
        "env", usage="actuator.py env [PROPERTY_NAME] [--source SOURCE] [--grep PATTERN]")
    env_parser.add_argument("property_name", nargs="?", help="Specific property name")
    env_parser.add_argument("--source", help="Filter to one named property source")
    env_parser.add_argument("--grep", help="Regex on property name (when no PROPERTY_NAME)")

    cp_parser = subparsers.add_parser("configprops", usage="actuator.py configprops [--grep PATTERN]")
    cp_parser.add_argument("--grep", help="Regex on prefix (case-insensitive)")

    subparsers.add_parser("mappings", usage="actuator.py mappings")

    metrics_parser = subparsers.add_parser("metrics", usage="actuator.py metrics [NAME] [--tag k=v]")
    metrics_parser.add_argument("name", nargs="?", help="Specific metric name")
    metrics_parser.add_argument("--tag", action="append", help="Tag filter k=v (repeatable)")

    loggers_parser = subparsers.add_parser("loggers", usage="actuator.py loggers [NAME] [LEVEL]")
    loggers_parser.add_argument("name", nargs="?", help="Logger name")
    loggers_parser.add_argument("level", nargs="?", help="Level to set (POST)")

    td_parser = subparsers.add_parser(
        "threaddump", usage="actuator.py threaddump [--grep PATTERN] [--state STATE]")
    td_parser.add_argument("--grep", help="Regex on thread name (case-insensitive)")
    td_parser.add_argument(
        "--state",
        choices=("RUNNABLE", "BLOCKED", "WAITING", "TIMED_WAITING", "NEW", "TERMINATED"),
    )

    hd_parser = subparsers.add_parser("heapdump", usage="actuator.py heapdump <path>")
    hd_parser.add_argument("path", help="Destination file path for HPROF data")

    subparsers.add_parser("scheduledtasks", usage="actuator.py scheduledtasks")
    subparsers.add_parser("startup", usage="actuator.py startup")

    for endpoint in sorted(GENERIC_ENDPOINTS):
        generic_parser = subparsers.add_parser(endpoint, usage=f"actuator.py {endpoint}")
        generic_parser.set_defaults(endpoint=endpoint)

    return parser


def _config_from_args(args) -> Config:
    return Config(
        base=args.base,
        host=args.host,
        port=args.port,
        base_path=args.base_path,
        scheme=args.scheme,
        bearer=args.bearer,
        bearer_cmd=args.bearer_cmd,
        basic=args.basic,
        basic_cmd=args.basic_cmd,
        header=args.header,
        header_cmd=args.header_cmd,
        cacert=args.cacert,
        insecure=args.insecure,
        timeout=args.timeout,
        probe_timeout=args.probe_timeout,
        no_cache=args.no_cache,
        verbose=args.verbose,
        output=args.output,
        max_lines=args.max_lines,
        max_bytes=args.max_bytes,
    )


DISPATCH = {
    "health": cmd_health,
    "info": cmd_info,
    "beans": cmd_beans,
    "conditions": cmd_conditions,
    "env": cmd_env,
    "configprops": cmd_configprops,
    "mappings": cmd_mappings,
    "metrics": cmd_metrics,
    "loggers": cmd_loggers,
    "threaddump": cmd_threaddump,
    "heapdump": cmd_heapdump,
    "scheduledtasks": cmd_scheduledtasks,
    "startup": cmd_startup,
}


def main(argv: Optional[list[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if not args.subcommand:
        parser.print_help()
        return 1

    config = _config_from_args(args)
    base_url = resolve_base(config)
    auth_header, source_label = resolve_auth(config, base_url)
    if config.verbose:
        sys.stderr.write(f"auth: using {source_label}\n")

    if args.subcommand in DISPATCH:
        DISPATCH[args.subcommand](config, args, base_url, auth_header)
    elif args.subcommand in GENERIC_ENDPOINTS:
        cmd_generic(config, args, base_url, auth_header)
    else:
        parser.print_help()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
