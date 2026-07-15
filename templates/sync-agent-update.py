#!/usr/bin/env python3
"""sync-agent-update (Python port)

Updates this project's vendored agent executables straight from the
agent-rules-skill repository (or a local checkout):
  bin/sync-agent-config          (port matching its shebang)
  bin/sync-agent-update          (itself)
  .agents/hooks/sync-on-edit.sh  (only when the project has it)

Nothing is applied without a y/n confirmation (single keypress on a TTY;
EOF answers n, so non-interactive runs never write silently). Downloads are
verified against the source's SHA256SUMS when it is published. State lives
under the "update" namespace of bin/sync-agent-config-options.json.

Stdlib-only port of the Ruby reference.
"""

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF_PATH = os.path.abspath(__file__)
OPTIONS_FILE = os.path.join(ROOT, "bin", "sync-agent-config-options.json")
DEFAULT_REPO = "renan-garcia/agent-rules-skill"
ARGS = sys.argv[1:]

USAGE = """sync-agent-update — update this project's vendored agent executables

Updates bin/sync-agent-config, bin/sync-agent-update (itself) and
.agents/hooks/sync-on-edit.sh from the agent-rules-skill repository.

Usage:
  bin/sync-agent-update                    # list changes and confirm with y/n
  bin/sync-agent-update --check            # dry-run; exit 1 when updates exist
  bin/sync-agent-update --yes              # apply without prompting
  bin/sync-agent-update --ref <tag|branch> # pin the source ref
  bin/sync-agent-update --repo owner/name  # update from a fork
  bin/sync-agent-update --source <dir|url> # alternate source (offline/tests)

The ref resolves from --ref, then the ref saved in
bin/sync-agent-config-options.json, then the repo's latest GitHub release.
Downloads are verified against the source's SHA256SUMS when published.
"""

CHECK = "--check" in ARGS
YES = "--yes" in ARGS

if "-h" in ARGS or "--help" in ARGS:
    sys.stdout.write(USAGE)
    sys.exit(0)


def die(message):
    sys.stderr.write("%s\n" % message)
    sys.exit(1)


def flag_value(name):
    for arg in ARGS:
        if arg.startswith(name + "="):
            return arg[len(name) + 1:]
    if name in ARGS:
        idx = ARGS.index(name)
        if idx + 1 < len(ARGS) and not ARGS[idx + 1].startswith("--"):
            return ARGS[idx + 1]
    return None


# ── Options file (shared with bin/sync-agent-config) ──────────────────────────

def json_file(data):
    return json.dumps(data, indent=2) + "\n"


def load_options():
    if not os.path.exists(OPTIONS_FILE):
        return {}
    try:
        with open(OPTIONS_FILE) as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_options(options):
    os.makedirs(os.path.dirname(OPTIONS_FILE), exist_ok=True)
    with open(OPTIONS_FILE, "w") as fh:
        fh.write(json_file(options))


# ── HTTP ──────────────────────────────────────────────────────────────────────

def http_get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "sync-agent-update"})
    try:
        with urllib.request.urlopen(request) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        die("HTTP %d fetching %s" % (error.code, url))
    except (urllib.error.URLError, OSError) as error:
        die("Network error fetching %s: %s" % (url, error))


# ── Interaction ───────────────────────────────────────────────────────────────

def read_answer():
    """One answer from the user. On a TTY, reads a single raw keypress (echoed
    back with a newline so the transcript stays clean); otherwise reads a line,
    so piped stdin still works. EOF and Ctrl-D answer n (the safe default)."""
    if sys.stdin.isatty():
        try:
            import termios
            import tty
        except ImportError:
            pass
        else:
            fd = sys.stdin.fileno()
            old_attrs = termios.tcgetattr(fd)
            try:
                # TCSANOW: the default TCSAFLUSH would discard a key already
                # typed between the prompt and the mode switch.
                tty.setcbreak(fd, termios.TCSANOW)
                char = sys.stdin.read(1)
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)
            if char == "" or char in ("\x03", "\x04"):
                char = "n"
            answer = char.strip().lower()
            sys.stdout.write("%s\n" % (answer if re.fullmatch(r"[a-z]", answer) else ""))
            sys.stdout.flush()
            return answer
    line = sys.stdin.readline()
    return "n" if line == "" else line.strip().lower()


def template_for(file_path):
    """The shebang of each installed executable selects the port to fetch; bun
    runs the Node port with the shebang rewritten after download."""
    with open(file_path) as fh:
        shebang = fh.readline()
    name = os.path.basename(file_path)
    if "bun" in shebang:
        return "templates/%s.js" % name, "bun"
    if "node" in shebang:
        return "templates/%s.js" % name, None
    if "python" in shebang:
        return "templates/%s.py" % name, None
    return "templates/%s" % name, None


# ── Source resolution ─────────────────────────────────────────────────────────

options = load_options()
update_opts = options.get("update")
if not isinstance(update_opts, dict):
    update_opts = {}

source = flag_value("--source")
repo = flag_value("--repo") or update_opts.get("repo") or DEFAULT_REPO
ref = flag_value("--ref") or update_opts.get("ref")

if source:
    if re.match(r"^https?://", source):
        base = source.rstrip("/")
        fetch = lambda p: http_get("%s/%s" % (base, p))  # noqa: E731
        source_label = base
    else:
        src_dir = os.path.abspath(source)
        if not os.path.isdir(src_dir):
            die("Invalid --source directory: %s" % source)

        def fetch(p, _dir=src_dir):
            f = os.path.join(_dir, p)
            if not os.path.exists(f):
                return None
            with open(f) as fh:
                return fh.read()

        source_label = "%s (local)" % src_dir
else:
    if ref is None:
        body = http_get("https://api.github.com/repos/%s/releases/latest" % repo)
        if body:
            try:
                ref = json.loads(body).get("tag_name")
            except Exception:
                ref = None
        if not ref:
            die("No release found for %s. Pass --ref <tag-or-branch> (e.g. --ref main)." % repo)
    base = "https://raw.githubusercontent.com/%s/%s" % (repo, ref)
    fetch = lambda p: http_get("%s/%s" % (base, p))  # noqa: E731
    source_label = "%s@%s" % (repo, ref)


# ── Targets ───────────────────────────────────────────────────────────────────

sync_target = os.path.join(ROOT, "bin", "sync-agent-config")
if not os.path.exists(sync_target):
    die("No bin/sync-agent-config found — this project does not look bootstrapped.")

targets = [sync_target, SELF_PATH]
hook = os.path.join(ROOT, ".agents", "hooks", "sync-on-edit.sh")
if os.path.exists(hook):
    targets.append(hook)


# ── Fetch + compare ───────────────────────────────────────────────────────────

sums_raw = fetch("SHA256SUMS")
sums = {}
if sums_raw:
    for line in sums_raw.split("\n"):
        m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", line.strip())
        if m:
            sums[m.group(2)] = m.group(1).lower()
else:
    sys.stderr.write(
        "⚠️  SHA256SUMS not found at %s — skipping integrity verification.\n" % source_label
    )

print("Update source: %s" % source_label)

changes = []
for target in targets:
    rel = target[len(ROOT) + 1:]
    if os.path.basename(target) == "sync-on-edit.sh":
        template_path, transform = "templates/sync-on-edit.sh", None
    else:
        template_path, transform = template_for(target)

    content = fetch(template_path)
    if content is None:
        die("Missing %s at %s — aborting." % (template_path, source_label))

    if sums:
        if template_path in sums:
            digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
            if digest != sums[template_path]:
                die("Checksum mismatch for %s — aborting." % template_path)
        else:
            sys.stderr.write("⚠️  No checksum for %s in SHA256SUMS.\n" % template_path)

    if transform == "bun":
        content = content.replace("env node", "env bun", 1)

    with open(target) as fh:
        current = fh.read()
    if current == content:
        print("  %s — up to date" % rel)
    else:
        print("  %s — update available" % rel)
        changes.append((target, rel, content))

if not changes:
    print("Everything is up to date. [%s]" % source_label)
    sys.exit(0)

if CHECK:
    print("%d update(s) available. Run bin/sync-agent-update to apply." % len(changes))
    sys.exit(1)


# ── Confirm + apply ───────────────────────────────────────────────────────────

if not YES:
    while True:
        sys.stdout.write("Apply %d update(s)? [y/n] " % len(changes))
        sys.stdout.flush()
        answer = read_answer()
        if answer in ("y", "n"):
            break
    if answer == "n":
        print("No changes applied.")
        sys.exit(0)

for target, rel, content in changes:
    with open(target, "w") as fh:
        fh.write(content)
    os.chmod(target, 0o755)
    print("✅ Updated %s" % rel)

update_opts["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if not source:
    update_opts["repo"] = repo
    update_opts["ref"] = ref
options["update"] = update_opts
save_options(options)

print("Update complete. [%s]" % source_label)
