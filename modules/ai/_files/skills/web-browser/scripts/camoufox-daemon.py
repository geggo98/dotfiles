#!/usr/bin/env python3
"""camoufox-daemon — stealth browser engine for the web-browser skill.

Two modes in one file:

  - Default (client): connect to per-session UNIX socket, send one JSON
    command, print the reply, exit. Forks a detached daemon on demand.
  - --daemon-mode (internal): the persistent process that owns the Camoufox
    browser and serves JSON commands.

CLI surface mirrors the agent-browser commands the web-browser skill exposes.
Protocol is newline-delimited JSON over a Unix-domain socket.
"""

from __future__ import annotations

import argparse
import base64
import errno
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any

VERSION = "0.1.0"

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")) / "camoufox-driver"
SESSIONS_DIR = CACHE_DIR / "sessions"
SOCKET_PREFIX = "camoufox-daemon-"


def socket_path(session: str) -> Path:
    return RUNTIME_DIR / f"{SOCKET_PREFIX}{session}.sock"


def pid_path(session: str) -> Path:
    return RUNTIME_DIR / f"{SOCKET_PREFIX}{session}.pid"


def log_path(session: str) -> Path:
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    return SESSIONS_DIR / f"{session}.log"


# ----- Tagging / snapshot JS (runs inside the page) ----------------------

# Tags every interactive / structurally relevant element with a
# data-camoufox-ref="@eN" attribute, then returns a flat list describing the
# tree. Later interactions select by [data-camoufox-ref="@eN"] which is stable
# until the next snapshot or until the DOM is re-rendered.
TAG_SCRIPT = r"""
(({interactiveOnly, compact, maxDepth, scopeSel}) => {
  document.querySelectorAll('[data-camoufox-ref]').forEach(el => el.removeAttribute('data-camoufox-ref'));

  const INTERACTIVE_TAGS = new Set(['A','BUTTON','INPUT','TEXTAREA','SELECT','LABEL','SUMMARY','DETAILS']);
  const INTERACTIVE_ROLES = new Set(['button','link','checkbox','radio','combobox','textbox','searchbox','option','tab','menuitem','slider','spinbutton','switch','treeitem','gridcell']);
  const STRUCTURAL_TAGS = new Set(['FORM','NAV','MAIN','HEADER','FOOTER','ASIDE','SECTION','ARTICLE','DIALOG','FIELDSET','TABLE','UL','OL']);
  const HEADING_RE = /^H[1-6]$/;

  function isVisible(el) {
    if (el.hidden) return false;
    const s = window.getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') return false;
    if (el.offsetWidth === 0 && el.offsetHeight === 0 && !el.getClientRects().length) {
      // SVG and some flex children can be 0x0 yet visible; trust visibility on those
      if (el.namespaceURI !== 'http://www.w3.org/2000/svg') return false;
    }
    return true;
  }

  function isInteractive(el) {
    if (INTERACTIVE_TAGS.has(el.tagName)) return true;
    const role = el.getAttribute('role');
    if (role && INTERACTIVE_ROLES.has(role)) return true;
    if (el.hasAttribute('tabindex') && el.getAttribute('tabindex') !== '-1') return true;
    if (typeof el.onclick === 'function' || el.hasAttribute('onclick')) return true;
    return false;
  }

  function getRole(el) {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit;
    const t = el.tagName;
    if (HEADING_RE.test(t)) return 'heading';
    const map = {
      A: 'link', BUTTON: 'button', TEXTAREA: 'textbox', SELECT: 'combobox',
      FORM: 'form', NAV: 'nav', MAIN: 'main', HEADER: 'banner',
      FOOTER: 'contentinfo', ASIDE: 'complementary', SECTION: 'region',
      ARTICLE: 'article', DIALOG: 'dialog', FIELDSET: 'group',
      LABEL: 'label', SUMMARY: 'summary', DETAILS: 'group',
      TABLE: 'table', UL: 'list', OL: 'list',
    };
    if (t === 'INPUT') {
      const ty = (el.type || 'text').toLowerCase();
      if (ty === 'submit' || ty === 'button') return 'button';
      if (ty === 'checkbox') return 'checkbox';
      if (ty === 'radio') return 'radio';
      if (ty === 'search') return 'searchbox';
      return 'input';
    }
    return map[t] || t.toLowerCase();
  }

  function getName(el) {
    const labelled = el.getAttribute('aria-labelledby');
    if (labelled) {
      const ids = labelled.split(/\s+/).filter(Boolean);
      const txt = ids.map(id => document.getElementById(id)?.textContent || '').join(' ').trim();
      if (txt) return txt.substring(0, 120);
    }
    const al = el.getAttribute('aria-label');
    if (al) return al.trim().substring(0, 120);

    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      const lbl = el.labels && el.labels[0]?.textContent;
      if (lbl) return lbl.trim().substring(0, 120);
      const ph = el.getAttribute('placeholder');
      if (ph) return ph.substring(0, 120);
      if (el.tagName === 'INPUT' && el.type === 'submit' && el.value) return el.value;
    }
    if (el.tagName === 'IMG') {
      const alt = el.getAttribute('alt');
      if (alt) return alt.substring(0, 120);
    }
    const title = el.getAttribute('title');
    if (title) return title.substring(0, 120);
    // Fall back to visible text for elements whose text IS their label
    const txt = (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ');
    return txt.substring(0, 120);
  }

  function getAttrs(el) {
    const a = {};
    if (el.tagName === 'INPUT') {
      a.type = (el.type || 'text').toLowerCase();
      if (el.placeholder) a.placeholder = el.placeholder.substring(0, 80);
      if (el.value && el.type !== 'password') a.value = el.value.substring(0, 80);
    }
    if (el.tagName === 'A' && el.href) a.href = el.href.substring(0, 200);
    if (el.tagName === 'IMG' && el.src) a.src = el.src.substring(0, 200);
    if (HEADING_RE.test(el.tagName)) a.level = parseInt(el.tagName.substring(1));
    if (el.getAttribute('aria-disabled') === 'true' || el.disabled) a.disabled = true;
    if (el.getAttribute('aria-expanded')) a.expanded = el.getAttribute('aria-expanded');
    if (el.getAttribute('aria-checked')) a.checked = el.getAttribute('aria-checked');
    if (el.checked !== undefined && (el.type === 'checkbox' || el.type === 'radio')) a.checked = el.checked;
    return a;
  }

  let refIndex = 0;
  const items = [];

  function walk(el, depth, parentIdx) {
    if (el.nodeType !== Node.ELEMENT_NODE) return;
    if (maxDepth !== null && depth > maxDepth) return;
    if (!isVisible(el)) return;

    const interactive = isInteractive(el);
    const structural = STRUCTURAL_TAGS.has(el.tagName) || HEADING_RE.test(el.tagName);

    let myIdx = parentIdx;
    let include = interactive || (!interactiveOnly && structural) || (interactiveOnly && HEADING_RE.test(el.tagName));

    if (include) {
      let ref = null;
      if (interactive || HEADING_RE.test(el.tagName)) {
        refIndex++;
        ref = '@e' + refIndex;
        el.setAttribute('data-camoufox-ref', ref);
      }
      const entry = {
        ref: ref,
        role: getRole(el),
        name: getName(el),
        attrs: getAttrs(el),
        depth: depth,
      };
      if (!compact || ref || entry.name || Object.keys(entry.attrs).length) {
        items.push(entry);
        myIdx = items.length - 1;
      }
    }

    for (const child of el.children) {
      walk(child, include ? depth + 1 : depth, myIdx);
    }

    // Inline same-origin iframe content
    if (el.tagName === 'IFRAME') {
      try {
        const doc = el.contentDocument;
        if (doc && doc.body) {
          for (const c of doc.body.children) walk(c, depth + 1, myIdx);
        }
      } catch (_) {}
    }
  }

  const root = scopeSel ? document.querySelector(scopeSel) : document.body;
  if (root) walk(root, 0, -1);

  return {
    title: document.title || '',
    url: window.location.href,
    items: items,
  };
}).call(this, {{ARGS}});
"""


def render_snapshot(data: dict, interactive_only: bool, urls: bool) -> str:
    """Format the JS tagger payload as agent-browser-compatible text."""
    lines = []
    if data.get("title"):
        lines.append(f"Page: {data['title']}")
    if data.get("url"):
        lines.append(f"URL: {data['url']}")
    if lines:
        lines.append("")

    for item in data.get("items", []):
        depth = item.get("depth", 0)
        indent = "  " * depth
        ref = item.get("ref")
        role = item.get("role", "")
        name = (item.get("name") or "").strip()
        attrs = item.get("attrs") or {}

        prefix = f"{ref} " if ref else ""
        role_part = f"[{role}"
        if attrs.get("type"):
            role_part += f' type="{attrs["type"]}"'
        if attrs.get("level"):
            role_part += f' level={attrs["level"]}'
        if attrs.get("disabled"):
            role_part += " disabled"
        if attrs.get("checked") is True:
            role_part += " checked"
        role_part += "]"

        bits = [f"{indent}{prefix}{role_part}"]
        if name:
            bits.append(f'"{name}"')
        if attrs.get("placeholder"):
            bits.append(f'placeholder="{attrs["placeholder"]}"')
        if urls and attrs.get("href"):
            bits.append(f'href={attrs["href"]}')
        lines.append(" ".join(bits))

    return "\n".join(lines)


def resolve_ref(ref_or_selector: str) -> str:
    """Translate @eN refs to a CSS selector; pass other selectors through."""
    if re.fullmatch(r"@e\d+", ref_or_selector):
        return f'[data-camoufox-ref="{ref_or_selector}"]'
    return ref_or_selector


# ----- Client mode -------------------------------------------------------


def daemon_alive(session: str) -> bool:
    pidf = pid_path(session)
    if not pidf.exists():
        return False
    try:
        pid = int(pidf.read_text().strip())
    except (ValueError, OSError):
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def cleanup_stale(session: str) -> None:
    """Drop socket / pid files when the daemon is gone."""
    sp, pp = socket_path(session), pid_path(session)
    if not daemon_alive(session):
        for p in (sp, pp):
            try:
                p.unlink()
            except FileNotFoundError:
                pass


def spawn_daemon(session: str) -> None:
    cleanup_stale(session)
    if daemon_alive(session):
        return
    # Re-exec ourselves in daemon mode. Detach via double-fork so the child
    # survives the parent's exit.
    script = os.path.abspath(__file__)
    proc = subprocess.Popen(
        [sys.executable, script, "--daemon-mode", "--session", session],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    # Wait for socket to appear
    deadline = time.time() + 30
    sp = socket_path(session)
    while time.time() < deadline:
        if sp.exists() and daemon_alive(session):
            return
        if proc.poll() is not None:
            log = log_path(session)
            hint = log.read_text()[-2000:] if log.exists() else "(no log)"
            raise RuntimeError(f"Daemon exited before socket appeared. Last log:\n{hint}")
        time.sleep(0.1)
    raise RuntimeError(f"Daemon did not become ready within 30s. See {log_path(session)}.")


def send_command(session: str, command: dict, timeout: float = 300.0) -> dict:
    sp = socket_path(session)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(sp))
    s.sendall((json.dumps(command) + "\n").encode("utf-8"))
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        if b"\n" in buf:
            break
    s.close()
    line = buf.split(b"\n", 1)[0]
    return json.loads(line.decode("utf-8"))


def client_dispatch(args: argparse.Namespace, extra: list[str]) -> int:
    session = args.session or "default"
    cmd = args.cmd

    # Special: close --all enumerates every daemon
    if cmd == "close" and (getattr(args, "all", False) or "--all" in extra):
        n = 0
        if RUNTIME_DIR.exists():
            for sf in RUNTIME_DIR.glob(f"{SOCKET_PREFIX}*.sock"):
                ses = sf.name[len(SOCKET_PREFIX):-len(".sock")]
                if daemon_alive(ses):
                    try:
                        send_command(ses, {"cmd": "close"}, timeout=5)
                        n += 1
                    except Exception:
                        pass
                cleanup_stale(ses)
        print(f"Closed {n} daemon(s).")
        return 0

    payload = {"cmd": cmd, "args": extra}

    # `open` (and the alias `goto`) launch the daemon on demand
    if cmd in ("open", "goto", "navigate"):
        if not daemon_alive(session):
            spawn_daemon(session)
    else:
        if not daemon_alive(session):
            print(f"ERROR: no camoufox daemon running for session '{session}'. "
                  f"Run `open <url>` first.", file=sys.stderr)
            return 2

    try:
        reply = send_command(session, payload)
    except Exception as exc:
        print(f"ERROR: socket call failed: {exc}", file=sys.stderr)
        return 1

    if reply.get("ok"):
        data = reply.get("data", "")
        if isinstance(data, (dict, list)):
            print(json.dumps(data, indent=2))
        elif data is not None:
            print(data)
        return 0
    else:
        print(f"ERROR: {reply.get('error', 'unknown')}", file=sys.stderr)
        return 1


# ----- Daemon mode -------------------------------------------------------


class Daemon:
    def __init__(self, session: str) -> None:
        self.session = session
        self.cf = None              # Camoufox context manager
        self.context = None         # BrowserContext
        self.pages: list[Any] = []  # list of Page
        self.active = 0             # index into self.pages
        self.tab_labels: dict[str, int] = {}  # label -> index
        self.lock = threading.RLock()
        self.shutdown = False
        self.log = logging.getLogger("camoufox-daemon")

    @property
    def page(self):
        if not self.pages:
            return None
        return self.pages[self.active]

    # ---- launch ----
    def cmd_open(self, args: list[str]) -> dict:
        # Parse open-time options
        url = None
        opts: dict[str, Any] = {}
        i = 0
        while i < len(args):
            a = args[i]
            if a in ("--humanize",): opts["humanize"] = True; i += 1
            elif a in ("--no-humanize",): opts["humanize"] = False; i += 1
            elif a == "--os": opts["os"] = args[i+1]; i += 2
            elif a in ("--geoip",): opts["geoip"] = True; i += 1
            elif a in ("--no-geoip",): opts["geoip"] = False; i += 1
            elif a in ("--disable-coop",): opts["disable_coop"] = True; i += 1
            elif a in ("--no-disable-coop",): opts["disable_coop"] = False; i += 1
            elif a == "--locale": opts["locale"] = args[i+1]; i += 2
            elif a == "--proxy": opts["proxy"] = args[i+1]; i += 2
            elif a in ("--block-images",): opts["block_images"] = True; i += 1
            elif a in ("--headed",): opts["headless"] = False; i += 1
            elif a == "--window":
                w, h = args[i+1].lower().split("x")
                opts["window"] = (int(w), int(h)); i += 2
            elif a == "--state": opts["storage_state"] = args[i+1]; i += 2
            elif a == "--session-name": opts["user_data_dir"] = args[i+1]; i += 2
            elif a.startswith("--"):
                return {"ok": False, "error": f"open: unknown flag {a}"}
            else:
                url = a; i += 1

        if self.context is None:
            self._launch(opts)

        if url:
            if not re.match(r"^[a-z]+://", url) and url != "about:blank":
                url = "https://" + url
            self.page.goto(url, wait_until="domcontentloaded")
            return {"ok": True, "data": f"Opened {url}"}
        return {"ok": True, "data": "Browser launched (no URL given)."}

    def _launch(self, opts: dict[str, Any]) -> None:
        from camoufox.sync_api import Camoufox

        # Default stealth profile
        kwargs: dict[str, Any] = {
            "headless": opts.pop("headless", True),
            "humanize": opts.pop("humanize", True),
            "os": opts.pop("os", "macos"),
            "disable_coop": opts.pop("disable_coop", True),
            "locale": opts.pop("locale", "en-US"),
            "window": opts.pop("window", (1280, 720)),
        }

        proxy = opts.pop("proxy", None)
        if proxy:
            kwargs["proxy"] = {"server": proxy}
            kwargs["geoip"] = opts.pop("geoip", True)
        elif "geoip" in opts:
            kwargs["geoip"] = opts.pop("geoip")

        if "block_images" in opts:
            kwargs["block_images"] = opts.pop("block_images")

        storage_state = opts.pop("storage_state", None)
        if storage_state:
            kwargs["storage_state"] = storage_state

        user_data_dir = opts.pop("user_data_dir", None)
        if user_data_dir:
            udd = Path(SESSIONS_DIR / user_data_dir)
            udd.mkdir(parents=True, exist_ok=True)
            kwargs["persistent_context"] = True
            kwargs["user_data_dir"] = str(udd)

        # Honour CAMOUFOX_EXECUTABLE_PATH (Nix-managed binary). The Camoufox
        # wrapper picks this up automatically; we just leave it in env.

        self.log.info("Launching Camoufox with %s", kwargs)
        self.cf = Camoufox(**kwargs)
        obj = self.cf.__enter__()
        # Camoufox returns a Browser in ephemeral mode, a BrowserContext in
        # persistent mode. Browser has `.contexts` but no `.pages`; context
        # has both `.pages` and `.new_page`.
        if hasattr(obj, "contexts"):
            self.context = obj.contexts[0] if obj.contexts else obj.new_context()
        else:
            self.context = obj
        if not self.context.pages:
            self.pages = [self.context.new_page()]
        else:
            self.pages = list(self.context.pages)
        self.active = 0

    # ---- snapshot ----
    def cmd_snapshot(self, args: list[str]) -> dict:
        if not self.page:
            return {"ok": False, "error": "no active page"}
        interactive_only = False
        compact = False
        max_depth: int | None = None
        scope: str | None = None
        as_json = False
        urls = False
        i = 0
        while i < len(args):
            a = args[i]
            if a == "-i" or a == "--interactive":
                interactive_only = True; i += 1
            elif a == "-c" or a == "--compact":
                compact = True; i += 1
            elif a == "-u" or a == "--urls":
                urls = True; i += 1
            elif a == "-d":
                max_depth = int(args[i+1]); i += 2
            elif a == "-s" or a == "--scope":
                scope = args[i+1]; i += 2
            elif a == "--json":
                as_json = True; i += 1
            elif a.startswith("--max-depth="):
                max_depth = int(a.split("=", 1)[1]); i += 1
            else:
                i += 1

        js_args = json.dumps({
            "interactiveOnly": interactive_only,
            "compact": compact,
            "maxDepth": max_depth,
            "scopeSel": scope,
        })
        script = TAG_SCRIPT.replace("{{ARGS}}", js_args)
        # Playwright's evaluate wants an expression that returns a value;
        # our IIFE returns the object directly.
        result = self.page.evaluate(script)
        if as_json:
            return {"ok": True, "data": result}
        return {"ok": True, "data": render_snapshot(result, interactive_only, urls)}

    # ---- interactions ----
    def _locator(self, sel: str):
        return self.page.locator(resolve_ref(sel))

    def cmd_click(self, args: list[str]) -> dict:
        new_tab = "--new-tab" in args
        args = [a for a in args if a != "--new-tab"]
        if not args:
            return {"ok": False, "error": "click: missing selector"}
        sel = resolve_ref(args[0])
        if new_tab:
            with self.page.context.expect_page() as p:
                self.page.click(sel, modifiers=["Meta"] if sys.platform == "darwin" else ["Control"])
            new_page = p.value
            self.pages.append(new_page)
            self.active = len(self.pages) - 1
            return {"ok": True, "data": f"clicked {args[0]} (new tab)"}
        self.page.click(sel)
        return {"ok": True, "data": f"clicked {args[0]}"}

    def cmd_dblclick(self, args: list[str]) -> dict:
        self.page.dblclick(resolve_ref(args[0]))
        return {"ok": True, "data": "ok"}

    def cmd_hover(self, args: list[str]) -> dict:
        self.page.hover(resolve_ref(args[0]))
        return {"ok": True, "data": "ok"}

    def cmd_focus(self, args: list[str]) -> dict:
        self.page.focus(resolve_ref(args[0]))
        return {"ok": True, "data": "ok"}

    def cmd_fill(self, args: list[str]) -> dict:
        if len(args) < 2:
            return {"ok": False, "error": "fill: need <ref> <text>"}
        self.page.fill(resolve_ref(args[0]), args[1])
        return {"ok": True, "data": "ok"}

    def cmd_type(self, args: list[str]) -> dict:
        if len(args) < 2:
            return {"ok": False, "error": "type: need <ref> <text>"}
        self.page.type(resolve_ref(args[0]), args[1])
        return {"ok": True, "data": "ok"}

    def cmd_press(self, args: list[str]) -> dict:
        if not args:
            return {"ok": False, "error": "press: need <key>"}
        self.page.keyboard.press(args[0])
        return {"ok": True, "data": "ok"}

    def cmd_check(self, args: list[str]) -> dict:
        self.page.check(resolve_ref(args[0]))
        return {"ok": True, "data": "ok"}

    def cmd_uncheck(self, args: list[str]) -> dict:
        self.page.uncheck(resolve_ref(args[0]))
        return {"ok": True, "data": "ok"}

    def cmd_select(self, args: list[str]) -> dict:
        if len(args) < 2:
            return {"ok": False, "error": "select: need <ref> <value> [...]"}
        self.page.select_option(resolve_ref(args[0]), args[1:])
        return {"ok": True, "data": "ok"}

    def cmd_scroll(self, args: list[str]) -> dict:
        # scroll <dir> [px]
        direction = args[0] if args else "down"
        px = int(args[1]) if len(args) > 1 else 300
        dx, dy = {"up": (0, -px), "down": (0, px), "left": (-px, 0), "right": (px, 0)}[direction]
        self.page.mouse.wheel(dx, dy)
        return {"ok": True, "data": "ok"}

    def cmd_scrollintoview(self, args: list[str]) -> dict:
        self.page.locator(resolve_ref(args[0])).scroll_into_view_if_needed()
        return {"ok": True, "data": "ok"}

    # ---- waits ----
    def cmd_wait(self, args: list[str]) -> dict:
        if not args:
            return {"ok": False, "error": "wait: need an argument"}
        timeout_ms = 25000
        # extract --timeout if present
        rest: list[str] = []
        i = 0
        while i < len(args):
            if args[i] == "--timeout":
                timeout_ms = int(float(args[i+1]) * 1000)
                i += 2
            else:
                rest.append(args[i]); i += 1
        args = rest

        head = args[0]
        if head.startswith("@e") or head.startswith("[data-camoufox-ref"):
            self.page.wait_for_selector(resolve_ref(head), timeout=timeout_ms)
            return {"ok": True, "data": "ok"}
        if head in ("-t", "--text"):
            self.page.wait_for_function(
                "(t) => document.body && document.body.innerText.includes(t)",
                arg=args[1], timeout=timeout_ms,
            )
            return {"ok": True, "data": "ok"}
        if head in ("-u", "--url"):
            self.page.wait_for_url(args[1], timeout=timeout_ms)
            return {"ok": True, "data": "ok"}
        if head in ("-l", "--load"):
            state = args[1]  # 'load', 'domcontentloaded', 'networkidle'
            self.page.wait_for_load_state(state, timeout=timeout_ms)
            return {"ok": True, "data": "ok"}
        if head in ("-f", "--fn"):
            self.page.wait_for_function(args[1], timeout=timeout_ms)
            return {"ok": True, "data": "ok"}
        if head == "--selector":
            self.page.wait_for_selector(args[1], timeout=timeout_ms)
            return {"ok": True, "data": "ok"}
        # numeric: sleep N ms
        try:
            ms = int(head)
            time.sleep(ms / 1000.0)
            return {"ok": True, "data": "ok"}
        except ValueError:
            # bare selector
            self.page.wait_for_selector(head, timeout=timeout_ms)
            return {"ok": True, "data": "ok"}

    # ---- read ----
    def cmd_get(self, args: list[str]) -> dict:
        if not args:
            return {"ok": False, "error": "get: need a subcommand"}
        sub = args[0]
        rest = args[1:]
        if sub == "text":
            return {"ok": True, "data": self.page.locator(resolve_ref(rest[0])).inner_text()}
        if sub == "html":
            return {"ok": True, "data": self.page.locator(resolve_ref(rest[0])).inner_html()}
        if sub == "value":
            return {"ok": True, "data": self.page.locator(resolve_ref(rest[0])).input_value()}
        if sub == "attr":
            return {"ok": True, "data": self.page.locator(resolve_ref(rest[0])).get_attribute(rest[1])}
        if sub == "title":
            return {"ok": True, "data": self.page.title()}
        if sub == "url":
            return {"ok": True, "data": self.page.url}
        if sub == "count":
            return {"ok": True, "data": str(self.page.locator(rest[0]).count())}
        if sub == "box":
            box = self.page.locator(resolve_ref(rest[0])).bounding_box()
            return {"ok": True, "data": box}
        return {"ok": False, "error": f"get: unknown subcommand {sub}"}

    def cmd_is(self, args: list[str]) -> dict:
        if not args or len(args) < 2:
            return {"ok": False, "error": "is: need <prop> <ref>"}
        prop, ref = args[0], args[1]
        loc = self.page.locator(resolve_ref(ref))
        mapping = {
            "visible": loc.is_visible,
            "enabled": loc.is_enabled,
            "checked": loc.is_checked,
            "hidden": loc.is_hidden,
            "disabled": loc.is_disabled,
            "editable": loc.is_editable,
        }
        if prop not in mapping:
            return {"ok": False, "error": f"is: unknown prop {prop}"}
        return {"ok": True, "data": "true" if mapping[prop]() else "false"}

    # ---- screenshot / eval ----
    def cmd_screenshot(self, args: list[str]) -> dict:
        full = False
        path = None
        i = 0
        while i < len(args):
            a = args[i]
            if a in ("--full", "-f"): full = True; i += 1
            elif a == "--annotate": i += 1  # accepted, not yet implemented
            else: path = a; i += 1
        if path is None:
            ts = time.strftime("%Y%m%d-%H%M%S")
            path = str(CACHE_DIR / "screenshots" / f"shot-{ts}.png")
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.page.screenshot(path=path, full_page=full)
        return {"ok": True, "data": f"saved {path}"}

    def cmd_eval(self, args: list[str]) -> dict:
        script = None
        i = 0
        while i < len(args):
            a = args[i]
            if a in ("-b", "--base64"):
                script = base64.b64decode(args[i+1]).decode("utf-8"); i += 2
            elif a == "--stdin":
                script = sys.stdin.read(); i += 1
            else:
                script = a; i += 1
        if script is None:
            return {"ok": False, "error": "eval: need script"}
        result = self.page.evaluate(script)
        if isinstance(result, (dict, list)):
            return {"ok": True, "data": result}
        return {"ok": True, "data": str(result) if result is not None else ""}

    # ---- state / cookies ----
    def cmd_state(self, args: list[str]) -> dict:
        if not args:
            return {"ok": False, "error": "state: need save|load <path>"}
        if args[0] == "save":
            ctx = self.page.context
            data = ctx.storage_state()
            Path(args[1]).write_text(json.dumps(data, indent=2))
            return {"ok": True, "data": f"saved {args[1]}"}
        if args[0] == "load":
            # Reload state requires recreating context — full restart.
            self._restart_with(storage_state=args[1])
            return {"ok": True, "data": f"loaded {args[1]}"}
        return {"ok": False, "error": "state: save|load only"}

    def _restart_with(self, **opts: Any) -> None:
        self._teardown_browser()
        self._launch(opts)

    def cmd_cookies(self, args: list[str]) -> dict:
        ctx = self.page.context
        if not args or args[0] == "get":
            return {"ok": True, "data": ctx.cookies()}
        if args[0] == "clear":
            ctx.clear_cookies()
            return {"ok": True, "data": "cleared"}
        if args[0] == "set":
            # cookies set name value [--domain foo --path /]
            name, value = args[1], args[2]
            cookie: dict[str, Any] = {"name": name, "value": value}
            i = 3
            while i < len(args):
                if args[i] == "--domain": cookie["domain"] = args[i+1]; i += 2
                elif args[i] == "--path": cookie["path"] = args[i+1]; i += 2
                elif args[i] == "--url": cookie["url"] = args[i+1]; i += 2
                else: i += 1
            if "url" not in cookie and "domain" not in cookie:
                cookie["url"] = self.page.url
            ctx.add_cookies([cookie])
            return {"ok": True, "data": "ok"}
        return {"ok": False, "error": f"cookies: unknown subcommand {args[0]}"}

    # ---- find (semantic locators) ----
    def cmd_find(self, args: list[str]) -> dict:
        if len(args) < 3:
            return {"ok": False, "error": "find: need <by> <query> <action> [args]"}
        by, query, action = args[0], args[1], args[2]
        rest = args[3:]
        loc = None
        if by == "role":
            name = None
            i = 0
            while i < len(rest):
                if rest[i] == "--name":
                    name = rest[i+1]; rest = rest[:i] + rest[i+2:]; break
                i += 1
            loc = self.page.get_by_role(query, name=name) if name else self.page.get_by_role(query)
        elif by == "text":
            exact = "--exact" in rest
            rest = [x for x in rest if x != "--exact"]
            loc = self.page.get_by_text(query, exact=exact)
        elif by == "label":
            loc = self.page.get_by_label(query)
        elif by == "placeholder":
            loc = self.page.get_by_placeholder(query)
        elif by == "testid":
            loc = self.page.get_by_test_id(query)
        elif by == "alt":
            loc = self.page.get_by_alt_text(query)
        elif by == "title":
            loc = self.page.get_by_title(query)
        elif by == "first":
            loc = self.page.locator(query).first
            action = rest[0] if rest else "click"
            rest = rest[1:] if rest else []
        elif by == "last":
            loc = self.page.locator(query).last
            action = rest[0] if rest else "click"
            rest = rest[1:] if rest else []
        elif by == "nth":
            n = int(query)
            loc = self.page.locator(args[2]).nth(n)
            action = rest[0] if rest else "click"
            rest = rest[1:] if rest else []
        else:
            return {"ok": False, "error": f"find: unknown 'by' {by}"}

        if action == "click":
            loc.first.click(); return {"ok": True, "data": "ok"}
        if action == "fill":
            loc.first.fill(rest[0]); return {"ok": True, "data": "ok"}
        if action == "type":
            loc.first.type(rest[0]); return {"ok": True, "data": "ok"}
        if action == "hover":
            loc.first.hover(); return {"ok": True, "data": "ok"}
        if action == "text":
            return {"ok": True, "data": loc.first.inner_text()}
        return {"ok": False, "error": f"find: unknown action {action}"}

    # ---- tabs (minimal) ----
    def cmd_tab(self, args: list[str]) -> dict:
        if not args:
            rows = []
            for i, p in enumerate(self.pages):
                marker = "*" if i == self.active else " "
                rows.append(f"{marker} t{i+1}\t{p.url}\t{p.title()}")
            return {"ok": True, "data": "\n".join(rows)}
        head = args[0]
        if head == "new":
            url = args[1] if len(args) > 1 else None
            new = self.page.context.new_page()
            if url:
                if not re.match(r"^[a-z]+://", url):
                    url = "https://" + url
                new.goto(url)
            self.pages.append(new)
            self.active = len(self.pages) - 1
            return {"ok": True, "data": f"t{self.active+1}"}
        if head == "close":
            target = args[1] if len(args) > 1 else f"t{self.active+1}"
            idx = self._tab_index(target)
            self.pages[idx].close()
            del self.pages[idx]
            self.active = max(0, min(self.active, len(self.pages) - 1))
            return {"ok": True, "data": "closed"}
        # switch
        idx = self._tab_index(head)
        self.active = idx
        return {"ok": True, "data": f"switched to t{idx+1}"}

    def _tab_index(self, label: str) -> int:
        m = re.fullmatch(r"t(\d+)", label)
        if m:
            return int(m.group(1)) - 1
        if label in self.tab_labels:
            return self.tab_labels[label]
        raise ValueError(f"unknown tab {label}")

    # ---- nav ----
    def cmd_back(self, args: list[str]) -> dict:
        self.page.go_back(); return {"ok": True, "data": "ok"}

    def cmd_forward(self, args: list[str]) -> dict:
        self.page.go_forward(); return {"ok": True, "data": "ok"}

    def cmd_reload(self, args: list[str]) -> dict:
        self.page.reload(); return {"ok": True, "data": "ok"}

    # ---- close ----
    def cmd_close(self, args: list[str]) -> dict:
        self.shutdown = True
        return {"ok": True, "data": "shutting down"}

    def _teardown_browser(self) -> None:
        try:
            if self.cf is not None:
                self.cf.__exit__(None, None, None)
        except Exception:
            self.log.exception("Failed to close Camoufox cleanly")
        finally:
            self.cf = None
            self.context = None
            self.pages = []

    def dispatch(self, payload: dict) -> dict:
        cmd = payload.get("cmd")
        args = payload.get("args", []) or []
        aliases = {"goto": "open", "navigate": "open", "quit": "close", "exit": "close",
                   "key": "press"}
        cmd = aliases.get(cmd, cmd)
        handler = getattr(self, f"cmd_{cmd}", None)
        if not handler:
            return {"ok": False, "error": f"unknown command: {cmd}"}
        with self.lock:
            try:
                return handler(args)
            except Exception as exc:
                self.log.exception("Command %s failed", cmd)
                return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    # ---- main loop ----
    def serve(self) -> None:
        sp = socket_path(self.session)
        pp = pid_path(self.session)
        try:
            sp.unlink()
        except FileNotFoundError:
            pass

        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(sp))
        srv.listen(8)
        os.chmod(sp, 0o600)
        pp.write_text(str(os.getpid()))

        def shutdown_handler(signum, _frame):
            self.log.info("Caught signal %d, shutting down", signum)
            self.shutdown = True
            try:
                srv.close()
            except Exception:
                pass

        signal.signal(signal.SIGTERM, shutdown_handler)
        signal.signal(signal.SIGINT, shutdown_handler)

        self.log.info("Daemon up on %s (pid %d)", sp, os.getpid())

        try:
            while not self.shutdown:
                try:
                    conn, _ = srv.accept()
                except OSError:
                    break
                try:
                    conn.settimeout(300)
                    buf = b""
                    while b"\n" not in buf:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                    if not buf:
                        conn.close(); continue
                    payload = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
                    reply = self.dispatch(payload)
                    conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
                except Exception:
                    self.log.exception("Connection failed")
                    try:
                        conn.sendall((json.dumps({"ok": False,
                                                  "error": traceback.format_exc()}) + "\n").encode("utf-8"))
                    except Exception:
                        pass
                finally:
                    conn.close()
        finally:
            self._teardown_browser()
            try: srv.close()
            except Exception: pass
            for p in (sp, pp):
                try: p.unlink()
                except FileNotFoundError: pass
            self.log.info("Daemon stopped.")


# ----- Entry point -------------------------------------------------------


def run_daemon(session: str) -> int:
    logging.basicConfig(
        filename=log_path(session),
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        d = Daemon(session)
        d.serve()
        return 0
    except Exception:
        logging.exception("Daemon crashed")
        return 1


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--session", default=os.environ.get("AGENT_BROWSER_SESSION", "default"))
    ap.add_argument("--daemon-mode", action="store_true",
                    help="(internal) run as the persistent daemon")
    ap.add_argument("--version", action="store_true")
    ap.add_argument("--help", "-h", action="store_true")
    ap.add_argument("cmd", nargs="?")
    args, extra = ap.parse_known_args()

    if args.version:
        print(f"camoufox-daemon {VERSION}")
        return 0
    if args.daemon_mode:
        return run_daemon(args.session)
    if args.help or args.cmd is None:
        print(__doc__)
        return 0

    # `close --all` short-circuit handled inside client_dispatch
    return client_dispatch(args, extra)


if __name__ == "__main__":
    sys.exit(main())
