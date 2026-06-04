#!/usr/bin/env python3
"""
cleanux-ai — AI-driven system analysis via tool use.

Reads config from /etc/cleanux.conf (or CLEANUX_CONF env var),
runs an OpenAI-compatible tool-use loop, and writes a JSON report to stdout.
"""

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────

DEFAULT_CONF   = "/etc/cleanux.conf"
MAX_TOOL_ROUNDS = 10

SYSTEM_PROMPT = (
    "You are a Linux system administrator assistant. "
    "Your job is to identify disk space that can be safely reclaimed on this machine.\n\n"
    "Use the available tools to inspect the system. Start with disk_overview to get "
    "a picture of overall usage, then drill into specific areas.\n\n"
    "When you have gathered enough information, call submit_recommendations with a "
    "prioritised list of specific, actionable cleanup tasks (largest impact first).\n\n"
    "Risk levels:\n"
    "  safe   — always fine to remove (caches, build artefacts)\n"
    "  low    — very likely fine, minimal chance of side effects\n"
    "  medium — review before removing, could affect running services\n"
    "  high   — destructive, data loss possible if wrong\n"
)

# ── Shell helpers ─────────────────────────────────────────────────────────────

def _run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""

def _shell(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""

# ── Tool implementations ───────────────────────────────────────────────────────

def tool_disk_overview():
    """Overall disk usage — always call this first."""
    return {
        "df":       _run(["df", "-h", "/"]),
        "top_dirs": _shell("du -sh /home /opt /var /tmp /root 2>/dev/null | sort -rh | head -12"),
    }

def tool_large_files(path="/home", min_mb=50, max_age_days=0):
    """Find large files under a path."""
    path = path.strip().rstrip("/") or "/home"
    age_flag = f"-atime +{max_age_days}" if max_age_days > 0 else ""
    cmd = (
        f"find {path} -maxdepth 8 -type f -size +{min_mb}M {age_flag} "
        "! -path '*/proc/*' ! -path '*/sys/*' "
        "-print0 2>/dev/null | xargs -0 du -sh 2>/dev/null | sort -rh | head -30"
    )
    return {"files": _shell(cmd)}

def tool_docker_info():
    """Docker disk usage — images, stopped containers, volumes, build cache."""
    if not shutil.which("docker"):
        return {"available": False}
    return {
        "available":          True,
        "system_df":          _run(["docker", "system", "df"]),
        "images":             _shell("docker images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}' | sort -rh | head -20"),
        "stopped_containers": _shell("docker ps -a --filter status=exited --format '{{.Names}}\t{{.Size}}' | head -20"),
        "volumes":            _shell("docker volume ls -q | head -20"),
    }

def tool_journal_logs():
    """systemd journal disk usage and oldest entry."""
    return {
        "usage":  _run(["journalctl", "--disk-usage"]),
        "oldest": _shell("journalctl --output=short-iso -n 1 --reverse 2>/dev/null | head -1"),
    }

def tool_package_cache():
    """Package manager cache sizes and removable packages."""
    result = {}
    if Path("/var/cache/apt/archives").exists():
        result["apt_archives"]   = _shell("du -sh /var/cache/apt/archives 2>/dev/null")
        result["apt_autoremove"] = _shell("apt-get --dry-run autoremove 2>/dev/null | grep '^Remov' | head -10")
    for mgr in ("dnf", "yum", "pacman", "brew"):
        if shutil.which(mgr):
            result[f"{mgr}_available"] = True
    return result

def tool_dev_caches(user=""):
    """Developer tool cache sizes (npm, pip, cargo, go, node_modules)."""
    home = Path(f"/home/{user}") if user else Path.home()
    result = {}
    candidates = [
        ("npm",   home / ".npm"),
        ("pip",   home / ".cache/pip"),
        ("cargo", home / ".cargo/registry/cache"),
        ("yarn",  home / ".yarn/cache"),
        ("pnpm",  home / ".pnpm-store"),
    ]
    for label, p in candidates:
        if p.exists():
            result[label] = _shell(f"du -sh {p} 2>/dev/null")
    go_cache = _shell("go env GOCACHE 2>/dev/null")
    if go_cache and Path(go_cache).exists():
        result["go"] = _shell(f"du -sh {go_cache} 2>/dev/null")
    nm = _shell(
        f"find {home} /opt -name node_modules -type d -prune "
        "-print0 2>/dev/null | xargs -0 du -sh 2>/dev/null | sort -rh | head -10"
    )
    if nm:
        result["node_modules"] = nm
    return result

def tool_snap_revisions():
    """Snap disabled (old) revisions that can be removed."""
    if not shutil.which("snap"):
        return {"available": False}
    return {
        "available":          True,
        "disabled_revisions": _shell("snap list --all 2>/dev/null | awk 'NR>1 && /disabled/'"),
    }

def tool_temp_files(max_age_days=7):
    """Old temp files and core dumps."""
    return {
        "tmp":   _shell(f"find /tmp -maxdepth 2 -atime +{max_age_days} -print0 2>/dev/null | xargs -0 du -sh 2>/dev/null | sort -rh | head -20"),
        "crash": _shell("find /var/crash /tmp /var -maxdepth 3 \\( -name '*.crash' -o -name 'core' -o -name 'core.*' \\) -print0 2>/dev/null | xargs -0 du -sh 2>/dev/null | sort -rh | head -10"),
    }

# ── Tool registry ──────────────────────────────────────────────────────────────

TOOL_FUNCS = {
    "disk_overview":    tool_disk_overview,
    "large_files":      tool_large_files,
    "docker_info":      tool_docker_info,
    "journal_logs":     tool_journal_logs,
    "package_cache":    tool_package_cache,
    "dev_caches":       tool_dev_caches,
    "snap_revisions":   tool_snap_revisions,
    "temp_files":       tool_temp_files,
}

TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "disk_overview",
            "description": "Overall disk usage breakdown — call this first",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "large_files",
            "description": "Find large files under a directory",
            "parameters": {
                "type": "object",
                "properties": {
                    "path":         {"type": "string",  "description": "Directory to search (e.g. /home, /var, /opt)"},
                    "min_mb":       {"type": "integer", "description": "Minimum size in MB (default 50)"},
                    "max_age_days": {"type": "integer", "description": "Only files not accessed in N days; 0 = all ages"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "docker_info",
            "description": "Docker disk usage — images, stopped containers, volumes, build cache",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "journal_logs",
            "description": "systemd journal size and oldest entry date",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "package_cache",
            "description": "Package manager cache sizes and autoremovable packages",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "dev_caches",
            "description": "Developer tool cache sizes: npm, pip, cargo, go, node_modules",
            "parameters": {
                "type": "object",
                "properties": {
                    "user": {"type": "string", "description": "Username to check (empty = current user)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "snap_revisions",
            "description": "Snap disabled (old) revisions that can be removed",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "temp_files",
            "description": "Old files in /tmp and core dumps",
            "parameters": {
                "type": "object",
                "properties": {
                    "max_age_days": {"type": "integer", "description": "Files not accessed in N days (default 7)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "submit_recommendations",
            "description": (
                "Submit the final cleanup recommendations. "
                "Call this once you have gathered enough data — it ends the analysis."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "summary": {
                        "type": "string",
                        "description": "One or two sentence summary of the findings",
                    },
                    "recommendations": {
                        "type": "array",
                        "description": "Cleanup actions sorted by estimated space freed (largest first)",
                        "items": {
                            "type": "object",
                            "properties": {
                                "title":           {"type": "string", "description": "Short action title"},
                                "explanation":     {"type": "string", "description": "Why this is safe (or risky) to remove"},
                                "command":         {"type": "string", "description": "Shell command to execute (omit if paths-only)"},
                                "paths":           {"type": "array", "items": {"type": "string"}, "description": "Specific paths to delete (max 20)"},
                                "estimated_bytes": {"type": "integer", "description": "Estimated bytes freed (0 if unknown)"},
                                "risk":            {"type": "string", "enum": ["safe", "low", "medium", "high"]},
                            },
                            "required": ["title", "explanation", "risk", "estimated_bytes"],
                        },
                    },
                },
                "required": ["summary", "recommendations"],
            },
        },
    },
]

# ── HTTP client ────────────────────────────────────────────────────────────────

def _http_post(url, api_key, payload):
    data    = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        hint = ""
        if e.code == 404:
            hint = f" — check that your endpoint includes /v1 (tried: {url})"
        elif e.code == 401:
            hint = " — invalid API key"
        elif e.code == 403:
            hint = " — access denied, check your API key permissions"
        return {"error": {"message": f"HTTP {e.code}{hint}: {body[:300]}"}}
    except Exception as e:
        return {"error": {"message": str(e)}}

# ── Tool execution ─────────────────────────────────────────────────────────────

def _execute_tool(name, args):
    func = TOOL_FUNCS.get(name)
    if not func:
        return json.dumps({"error": f"unknown tool: {name}"})
    try:
        return json.dumps(func(**args), ensure_ascii=False)
    except TypeError as e:
        return json.dumps({"error": f"bad args for {name}: {e}"})
    except Exception as e:
        return json.dumps({"error": str(e)})

# ── AI loop ───────────────────────────────────────────────────────────────────

def run_scan(endpoint, api_key, model):
    """Run the tool-use loop and return a recommendations dict."""
    ep = endpoint.rstrip("/")
    # Normalise: strip accidental /chat/completions suffix the user may have pasted
    if ep.endswith("/chat/completions"):
        ep = ep[: -len("/chat/completions")]
    url = f"{ep}/chat/completions"
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": (
                "Analyze this Linux system and tell me what I can clean up to free disk space. "
                "Start with disk_overview, use other tools as needed, "
                "then call submit_recommendations."
            ),
        },
    ]

    for round_n in range(MAX_TOOL_ROUNDS):
        response = _http_post(url, api_key, {
            "model":       model,
            "messages":    messages,
            "tools":       TOOL_DEFINITIONS,
            "tool_choice": "auto",
            "temperature": 0.1,
        })

        if "error" in response:
            err = response["error"]
            msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
            return {"status": "error", "message": msg}

        choices = response.get("choices") or []
        if not choices:
            return {"status": "error", "message": "Empty choices in API response"}

        choice  = choices[0]
        message = choice.get("message", {})
        messages.append(message)

        tool_calls = message.get("tool_calls") or []

        if not tool_calls:
            # Model gave a plain text answer instead of calling a tool
            content = message.get("content") or ""
            return {
                "status": "error",
                "message": f"Model responded without calling a tool (round {round_n + 1}). Response: {content[:400]}",
            }

        tool_results = []
        for tc in tool_calls:
            fn   = tc.get("function", {})
            name = fn.get("name", "")
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}

            if name == "submit_recommendations":
                return {"status": "ok", **args}

            result = _execute_tool(name, args)
            tool_results.append({
                "role":         "tool",
                "tool_call_id": tc.get("id", ""),
                "content":      result,
            })

        messages.extend(tool_results)

    return {"status": "error", "message": f"Reached {MAX_TOOL_ROUNDS} tool rounds without recommendations"}

# ── Config loader ──────────────────────────────────────────────────────────────

def load_config(path):
    config = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    config[key.strip()] = val.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return config

# ── Profile management ────────────────────────────────────────────────────────

PROFILES_DIR = "/etc/cleanux/profiles"

def _profile_path(name):
    slug = "".join(c if c.isalnum() or c in "-_ " else "_" for c in name).strip()
    slug = slug.replace(" ", "_")
    return os.path.join(PROFILES_DIR, slug + ".json")

def cmd_list_profiles():
    profiles = []
    try:
        for fname in sorted(os.listdir(PROFILES_DIR)):
            if not fname.endswith(".json"):
                continue
            try:
                with open(os.path.join(PROFILES_DIR, fname)) as f:
                    p = json.load(f)
                    profiles.append({
                        "name":     p.get("name", fname[:-5]),
                        "endpoint": p.get("endpoint", ""),
                        "model":    p.get("model", ""),
                    })
            except Exception:
                pass
    except FileNotFoundError:
        pass
    print(json.dumps(profiles, ensure_ascii=False))

def cmd_save_profile(name, endpoint, key, model):
    os.makedirs(PROFILES_DIR, mode=0o700, exist_ok=True)
    path = _profile_path(name)
    profile = {"name": name, "endpoint": endpoint, "key": key, "model": model}
    with open(path, "w") as f:
        json.dump(profile, f, ensure_ascii=False, indent=2)
    print(json.dumps({"status": "ok", "path": path}))

def cmd_load_profile(name):
    path = _profile_path(name)
    try:
        with open(path) as f:
            p = json.load(f)
        print(json.dumps({"status": "ok",
                          "endpoint": p.get("endpoint", ""),
                          "key":      p.get("key", ""),
                          "model":    p.get("model", "")}))
    except FileNotFoundError:
        print(json.dumps({"status": "error", "message": f"Profile not found: {name}"}))

def cmd_delete_profile(name):
    path = _profile_path(name)
    try:
        os.remove(path)
        print(json.dumps({"status": "ok"}))
    except FileNotFoundError:
        print(json.dumps({"status": "error", "message": f"Profile not found: {name}"}))

# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]

    if args and args[0] == "--list-profiles":
        cmd_list_profiles()
        return

    if args and args[0] == "--save-profile":
        # args: --save-profile NAME ENDPOINT KEY MODEL
        if len(args) < 5:
            print(json.dumps({"status": "error", "message": "Usage: --save-profile NAME ENDPOINT KEY MODEL"}))
            sys.exit(1)
        cmd_save_profile(args[1], args[2], args[3], args[4])
        return

    if args and args[0] == "--load-profile":
        if len(args) < 2:
            print(json.dumps({"status": "error", "message": "Usage: --load-profile NAME"}))
            sys.exit(1)
        cmd_load_profile(args[1])
        return

    if args and args[0] == "--delete-profile":
        if len(args) < 2:
            print(json.dumps({"status": "error", "message": "Usage: --delete-profile NAME"}))
            sys.exit(1)
        cmd_delete_profile(args[1])
        return

    # Default: run AI scan
    conf_path = os.environ.get("CLEANUX_CONF", DEFAULT_CONF)
    config    = load_config(conf_path)

    endpoint = config.get("AI_ENDPOINT", "").strip()
    api_key  = config.get("AI_API_KEY",  "").strip()
    model    = config.get("AI_MODEL",    "gpt-4o-mini").strip()

    if not endpoint:
        print(json.dumps({"status": "error", "message": "AI_ENDPOINT not configured — set it in " + conf_path}))
        sys.exit(1)

    result = run_scan(endpoint, api_key, model)
    print(json.dumps(result, ensure_ascii=False))

if __name__ == "__main__":
    main()
