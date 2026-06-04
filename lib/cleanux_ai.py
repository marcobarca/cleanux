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
    "Your job is to do a full health scan of this machine covering two areas:\n\n"
    "  1. DISK — identify space that can be safely reclaimed (caches, logs, build artefacts, etc.)\n"
    "  2. LOAD & PROCESSES — identify heavyweight, orphaned, or misbehaving processes and services "
    "(high CPU/RAM consumers that look abnormal, zombie processes, services crashing and restarting "
    "in a loop, failed systemd units, processes leaking file descriptors, etc.)\n\n"
    "Workflow:\n"
    "  - Start with disk_overview and system_load to get an overall picture.\n"
    "  - Use disk tools (large_files, docker_info, journal_logs, dev_caches, etc.) for storage.\n"
    "  - Use load tools (top_processes, zombie_processes, systemd_services, open_files) for processes.\n"
    "  - Call both sort_by=cpu and sort_by=memory variants of top_processes.\n"
    "  - When you have enough data, call submit_recommendations.\n\n"
    "For each recommendation, write a thorough explanation covering:\n"
    "  1. What the service, process, or component is and what it does\n"
    "  2. Why it is accumulating space or consuming excessive resources\n"
    "  3. Who or what creates/runs it\n"
    "  4. What the concrete impact of the action will be (what is lost, what recovers automatically)\n"
    "  5. Any caveats\n\n"
    "Write explanations as flowing prose (2-5 sentences). "
    "Assume the reader is a developer who knows Linux basics.\n\n"
    "Risk levels:\n"
    "  safe   — always fine (caches, build artefacts, clearly orphaned processes)\n"
    "  low    — very likely fine, minimal side effects\n"
    "  medium — review before acting, could affect running services\n"
    "  high   — destructive or service-interrupting, requires explicit confirmation\n"
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

def tool_system_load():
    """Current CPU load, RAM/swap usage, and uptime."""
    return {
        "uptime":     _run(["uptime"]),
        "load_avg":   _shell("cat /proc/loadavg"),
        "cpu_count":  _shell("nproc"),
        "cpu_model":  _shell("grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2- | xargs"),
        "ram":        _shell("free -h | grep -E '^Mem|^Swap'"),
        "vmstat":     _shell("vmstat 1 2 2>/dev/null | tail -1"),
    }

def tool_top_processes(sort_by="cpu", count=20):
    """List top processes sorted by CPU or memory usage."""
    n = min(max(int(count), 5), 40)
    if sort_by == "memory":
        cmd = f"ps aux --sort=-%mem | head -{n + 1}"
    else:
        cmd = f"ps aux --sort=-%cpu | head -{n + 1}"
    return {
        "sort_by":   sort_by,
        "processes": _shell(cmd),
    }

def tool_zombie_processes():
    """Find zombie/defunct processes and their parents."""
    zombies = _shell("ps aux | awk 'NR==1 || $8==\"Z\"'")
    count   = _shell("ps aux | awk '$8==\"Z\"' | wc -l").strip()
    parents = ""
    if count and count != "0":
        parents = _shell(
            "ps aux | awk '$8==\"Z\"{print $1,$2,$11}' | "
            "while read u pid cmd; do "
            "  ppid=$(awk '/PPid/{print $2}' /proc/$pid/status 2>/dev/null); "
            "  [ -n \"$ppid\" ] && echo \"zombie PID=$pid ($cmd) parent=$ppid ($(ps -p $ppid -o comm= 2>/dev/null))\"; "
            "done"
        )
    return {"count": count, "zombies": zombies, "parent_info": parents}

def tool_systemd_services():
    """Systemd failed units, high-resource services, and resource usage by cgroup."""
    return {
        "failed":       _run(["systemctl", "--failed", "--no-pager", "--plain"]),
        "running":      _shell("systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | head -40"),
        "cgroup_top":   _shell("systemd-cgtop -n 1 -b --depth=3 2>/dev/null | head -25"),
        "high_restart": _shell(
            "systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | "
            "awk '{print $1}' | xargs -I{} systemctl show {} --property=NRestarts --value 2>/dev/null | "
            "paste - <(systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | awk '{print $1}') | "
            "awk '$1+0 > 3 {print $1\" restarts: \"$2}' | head -10"
        ),
    }

def tool_open_files(top_n=15):
    """Processes holding the most open file descriptors."""
    cmd = (
        f"ls /proc/[0-9]*/fd 2>/dev/null | awk -F/ '{{print $3}}' | sort | uniq -c | sort -rn | head -{top_n} | "
        "while read cnt pid; do "
        "  comm=$(cat /proc/$pid/comm 2>/dev/null || echo '?'); "
        "  echo \"$cnt fd  PID=$pid  $comm\"; "
        "done"
    )
    return {"top_fd": _shell(cmd)}

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
    "system_load":      tool_system_load,
    "top_processes":    tool_top_processes,
    "zombie_processes": tool_zombie_processes,
    "systemd_services": tool_systemd_services,
    "open_files":       tool_open_files,
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
            "name": "system_load",
            "description": "Current CPU load averages, RAM/swap usage, uptime, and vmstat snapshot",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "top_processes",
            "description": "List top processes by CPU or memory consumption",
            "parameters": {
                "type": "object",
                "properties": {
                    "sort_by": {"type": "string", "enum": ["cpu", "memory"], "description": "Sort dimension (default: cpu)"},
                    "count":   {"type": "integer", "description": "Number of processes to return (default 20, max 40)"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "zombie_processes",
            "description": "Find zombie/defunct processes and identify their parent processes",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "systemd_services",
            "description": "Systemd failed units, running services, cgroup resource usage, and services with many restarts",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_files",
            "description": "Processes holding the most open file descriptors",
            "parameters": {
                "type": "object",
                "properties": {
                    "top_n": {"type": "integer", "description": "How many processes to list (default 15)"},
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
                "Submit the final recommendations. "
                "Call this once you have gathered enough data — it ends the analysis."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "summary": {
                        "type": "string",
                        "description": "2-3 sentence summary covering both disk and load findings",
                    },
                    "recommendations": {
                        "type": "array",
                        "description": (
                            "All recommended actions — disk cleanup AND load/process fixes. "
                            "Sort by impact: disk items by estimated_bytes desc, process items by severity. "
                            "Include a 'category' field to distinguish them."
                        ),
                        "items": {
                            "type": "object",
                            "properties": {
                                "title":           {"type": "string", "description": "Short action title"},
                                "category":        {"type": "string", "enum": ["disk", "process", "service", "memory"], "description": "Type of recommendation"},
                                "explanation":     {"type": "string", "description": "Full explanation: what the service/component is, what these files or processes are and why they accumulate or run, who creates and uses them, what happens after the action (what is lost vs what regenerates or recovers), and any caveats. 2-5 sentences of prose."},
                                "command":         {"type": "string", "description": "Shell command to execute (kill, systemctl stop/disable, rm, docker prune, etc.)"},
                                "paths":           {"type": "array", "items": {"type": "string"}, "description": "Specific paths to delete (max 20, disk category only)"},
                                "estimated_bytes": {"type": "integer", "description": "Estimated bytes freed (0 for process/service actions)"},
                                "risk":            {"type": "string", "enum": ["safe", "low", "medium", "high"]},
                            },
                            "required": ["title", "category", "explanation", "risk", "estimated_bytes"],
                        },
                    },
                },
                "required": ["summary", "recommendations"],
            },
        },
    },
]

# ── HTTP client ────────────────────────────────────────────────────────────────

def _http_post(url, api_key, payload, azure=False):
    data    = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        if azure:
            headers["api-key"] = api_key
        else:
            headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        hint = ""
        if e.code == 404:
            hint = f" (tried: {url})"
            if not azure:
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

    # Azure OpenAI uses a different URL structure and auth header
    azure = ".openai.azure.com" in ep
    if azure:
        # https://{resource}.openai.azure.com/openai/deployments/{deployment}/chat/completions?api-version=...
        url = f"{ep}/openai/deployments/{model}/chat/completions?api-version=2024-10-21"
    else:
        url = f"{ep}/chat/completions"
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": (
                "Do a full health scan of this Linux system. "
                "Check both disk usage (what can be cleaned up) and system load "
                "(heavy processes, zombies, failing services, anything abnormal). "
                "Start with disk_overview and system_load, use all relevant tools, "
                "then call submit_recommendations with findings from both areas."
            ),
        },
    ]

    for round_n in range(MAX_TOOL_ROUNDS):
        payload = {
            "messages":    messages,
            "tools":       TOOL_DEFINITIONS,
            "tool_choice": "auto",
            "temperature": 0.1,
        }
        if not azure:
            payload["model"] = model
        response = _http_post(url, api_key, payload, azure=azure)

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

# ── Chat about a recommendation ───────────────────────────────────────────────

def cmd_chat(rec_json_str, history_json_str, question):
    conf_path = os.environ.get("CLEANUX_CONF", DEFAULT_CONF)
    config    = load_config(conf_path)
    endpoint  = config.get("AI_ENDPOINT", "").strip()
    api_key   = config.get("AI_API_KEY",  "").strip()
    model     = config.get("AI_MODEL",    "gpt-4o-mini").strip()

    if not endpoint:
        print(json.dumps({"status": "error", "message": "AI_ENDPOINT not configured"}))
        return

    try:
        rec = json.loads(rec_json_str)
    except json.JSONDecodeError:
        rec = {}
    try:
        history = json.loads(history_json_str)
    except json.JSONDecodeError:
        history = []

    paths_str = ", ".join(rec.get("paths", [])) or "none listed"
    system = (
        "You are a Linux system administrator assistant. "
        "The user is reviewing a specific disk cleanup recommendation and has questions about it. "
        "Give clear, precise answers. When relevant, mention Linux internals, typical file paths, "
        "or how to verify things manually. Be concise — 2-4 sentences unless more depth is needed.\n\n"
        "Recommendation context:\n"
        f"  Title:    {rec.get('title', 'N/A')}\n"
        f"  Risk:     {rec.get('risk', 'N/A')}\n"
        f"  Command:  {rec.get('command', 'N/A')}\n"
        f"  Paths:    {paths_str}\n"
        f"  Details:  {rec.get('explanation', 'N/A')}\n"
    )

    messages = [{"role": "system", "content": system}]
    messages.extend(history)
    messages.append({"role": "user", "content": question})

    ep = endpoint.rstrip("/")
    if ep.endswith("/chat/completions"):
        ep = ep[:-len("/chat/completions")]
    azure = ".openai.azure.com" in ep
    if azure:
        url = f"{ep}/openai/deployments/{model}/chat/completions?api-version=2024-10-21"
    else:
        url = f"{ep}/chat/completions"

    payload = {"messages": messages, "temperature": 0.3}
    if not azure:
        payload["model"] = model

    response = _http_post(url, api_key, payload, azure=azure)

    if "error" in response:
        err = response["error"]
        msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
        print(json.dumps({"status": "error", "message": msg}))
        return

    choices = response.get("choices") or []
    if not choices:
        print(json.dumps({"status": "error", "message": "Empty response from AI"}))
        return

    reply = choices[0].get("message", {}).get("content", "")
    print(json.dumps({"status": "ok", "reply": reply}, ensure_ascii=False))

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

    if args and args[0] == "--chat":
        # args: --chat REC_JSON HISTORY_JSON QUESTION
        if len(args) < 4:
            print(json.dumps({"status": "error", "message": "Usage: --chat REC_JSON HISTORY_JSON QUESTION"}))
            sys.exit(1)
        cmd_chat(args[1], args[2], args[3])
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
