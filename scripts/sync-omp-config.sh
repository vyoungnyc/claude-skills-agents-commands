#!/bin/bash
# scripts/sync-omp-config.sh — convert this repo's Claude Code config
# (agents/, skills/, commands/, hooks/) into oh-my-pi (omp) format and sync it
# into the live omp config (default $HOME/.omp, override with OMP_HOME for
# testing or an alternate target).
#
# The conversion is done ON DEMAND into an ephemeral staging directory and
# then overlaid onto the target — nothing converted is ever committed to this
# repo. Only the original Claude files are tracked; this script is the single
# source of the omp-format translation.
#
# Dry run by default: prints what would change and exits 0 without touching
# anything. Pass --apply to actually write. Before modifying a live target
# directory, this script snapshots the WHOLE directory under
# <OMP_HOME>/backups/omp-sync-<timestamp>/ — a full-directory backup, so an
# unwanted apply rolls back with a single recursive copy.
#
# WHY a converter is needed (per-artifact):
#
#   agents/   — REQUIRES conversion. omp intentionally SKIPS ~/.claude/agents:
#               the Claude agent frontmatter schema (tools as Claude tool
#               names, model: opus|sonnet|haiku, memory/maxTurns/isolation/
#               permissionMode) is not the omp task-agent contract. This
#               script rewrites the frontmatter to omp's shape (name +
#               description required; tools translated to omp tool names;
#               Claude-only keys dropped) and lands them in
#               <OMP_HOME>/agent/agents/*.md, which omp DOES discover.
#
#   skills/   — no schema change. SKILL.md frontmatter (name + description) is
#               already omp-compatible; copied verbatim to
#               <OMP_HOME>/agent/skills/<name>/SKILL.md for native discovery.
#
#   commands/ — no schema change. Body template + description carry over; omp
#               ignores the extra model/args frontmatter keys harmlessly.
#               Copied verbatim to <OMP_HOME>/agent/commands/*.md.
#
#   hooks/    — REQUIRES conversion (paradigm change). Claude's settings.json
#               event matchers + shell scripts are not read by omp; omp hooks
#               are TS modules that default-export function(pi: HookAPI). This
#               script emits a single adapter, claude-compat.ts, that binds the
#               mappable Claude hook events to omp events and shells out to the
#               original .sh scripts (copied alongside). See the generated
#               file's header for the event map and known limitations
#               (PermissionRequest has no omp event; auto-format/auto-test
#               file_path recovery on the edit tool is best-effort). Skip with
#               --no-hooks.
#
# Claude tool name -> omp tool name mapping used for agents:
#   Read->read Write->write Edit/MultiEdit/NotebookEdit->edit Bash->bash
#   Grep->grep Glob->glob WebSearch/WebFetch->web_search Task/Agent->task
#   AskUserQuestion->ask TaskCreate/TaskList/TaskUpdate/TaskGet->todo
#   SendMessage->hub NotebookRead->read
#   LS and mcp__* and any unrecognized tool are dropped (omp exposes MCP tools
#   under different per-tool names, so a server-level mcp__ entry cannot map).
#   When an agent's translated tool list contains `task`, omp auto-enables
#   sub-spawning (spawns: *) via its own backward-compat rule, so no explicit
#   spawns key is emitted.
#
# model handling: dropped by default so converted agents inherit the parent/
#   default model and always resolve. Pass --map-models to instead emit omp
#   role aliases (opus->@good, haiku->@fast, sonnet omitted) and print the
#   modelRoles snippet to add to <OMP_HOME>/agent/config.yml.
#
# bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "sync-omp-config.sh: jq is required but was not found on PATH" >&2
  exit 1
}
command -v awk >/dev/null 2>&1 || {
  echo "sync-omp-config.sh: awk is required but was not found on PATH" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMP_HOME="${OMP_HOME:-$HOME/.omp}"
OMP_AGENT="$OMP_HOME/agent"

APPLY=0
MAP_MODELS=0
WITH_HOOKS=1
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --map-models) MAP_MODELS=1 ;;
    --no-hooks) WITH_HOOKS=0 ;;
    -h|--help)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "sync-omp-config.sh: unknown argument '$arg' (use --apply, --map-models, --no-hooks, -h)" >&2
      exit 2
      ;;
  esac
done

# Ephemeral staging tree; always cleaned up. Everything the converter produces
# lives here until (and only if) --apply overlays it onto the target.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/omp-sync.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$OMP_HOME/backups/omp-sync-$TIMESTAMP"
BACKED_UP=0
CHANGED=0

note() {
  # $1 = message describing a planned/applied change
  if [ "$APPLY" -eq 1 ]; then
    echo "  applied: $1"
  else
    echo "  would change: $1"
  fi
}

backup_dir_once() {
  # $1 = absolute path of a live category directory about to be modified.
  # Snapshots the ENTIRE directory (changed, unchanged, and live-only files)
  # once per run, mirroring its path under BACKUP_DIR relative to OMP_HOME, so
  # rolling back an unwanted apply is a single recursive restore. No-op if the
  # directory does not exist yet (a first-ever deploy has nothing to preserve)
  # or was already snapshotted this run.
  local lroot="$1" rel dest
  [ -d "$lroot" ] || return 0
  rel="${lroot#"$OMP_HOME"/}"
  dest="$BACKUP_DIR/$rel"
  [ -e "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")"
  cp -R "$lroot" "$dest"
  BACKED_UP=1
}

# --- agent frontmatter conversion --------------------------------------------
# Emits a single converted agent markdown file on stdout. Reads one Claude
# agent .md on stdin. Tool translation, key filtering, and model mapping all
# happen inside awk so the whole transform is one deterministic pass.
convert_agent() {
  awk -v map_models="$MAP_MODELS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { infm = 0; started = 0; body = ""; ntools = 0; model_out = "" }
    # Frontmatter is delimited by lines that are exactly --- ; the first must
    # be line 1. Anything before it (there should be nothing) is ignored.
    NR == 1 && $0 == "---" { infm = 1; started = 1; next }
    started == 1 && infm == 1 && $0 == "---" { infm = 0; next }
    infm == 1 {
      idx = index($0, ":")
      if (idx > 0) {
        key = trim(substr($0, 1, idx - 1))
        val = trim(substr($0, idx + 1))
        fm[key] = val
      }
      next
    }
    # Everything after the closing --- is body, preserved verbatim.
    started == 1 { body = body $0 "\n"; next }
    # A file with no leading frontmatter: treat the whole thing as body.
    { body = body $0 "\n" }

    END {
      name = fm["name"]
      desc = fm["description"]
      if (name == "" || desc == "") {
        # Signal failure: caller checks for the marker on stdout.
        print "__CONVERT_ERROR__ missing name or description"
        exit 0
      }

      # Translate the Claude tools CSV to omp tool names, de-duping while
      # preserving first-seen order. Unmappable entries are dropped.
      raw = fm["tools"]
      n = split(raw, parts, ",")
      for (i = 1; i <= n; i++) {
        t = trim(parts[i])
        if (t == "") continue
        o = ""
        if (t == "Read") o = "read"
        else if (t == "Write") o = "write"
        else if (t == "Edit" || t == "MultiEdit" || t == "NotebookEdit") o = "edit"
        else if (t == "Bash") o = "bash"
        else if (t == "Grep") o = "grep"
        else if (t == "Glob") o = "glob"
        else if (t == "WebSearch" || t == "WebFetch") o = "web_search"
        else if (t == "Task" || t == "Agent") o = "task"
        else if (t == "AskUserQuestion") o = "ask"
        else if (t == "TaskCreate" || t == "TaskList" || t == "TaskUpdate" || t == "TaskGet") o = "todo"
        else if (t == "SendMessage") o = "hub"
        else if (t == "NotebookRead") o = "read"
        else o = ""   # LS, mcp__*, unknown -> drop
        if (o == "") continue
        seen = 0
        for (j = 1; j <= ntools; j++) if (tools[j] == o) { seen = 1; break }
        if (!seen) { ntools++; tools[ntools] = o }
      }

      # model mapping (opt-in). Dropped otherwise.
      if (map_models == "1") {
        m = fm["model"]
        if (m == "opus") model_out = "@good"
        else if (m == "haiku") model_out = "@fast"
        else model_out = ""   # sonnet / unset -> inherit
      }

      print "---"
      print "name: " name
      print "description: " desc
      if (ntools > 0) {
        line = "tools: "
        for (j = 1; j <= ntools; j++) {
          line = line tools[j]
          if (j < ntools) line = line ", "
        }
        print line
      }
      if (model_out != "") print "model: " model_out
      print "---"
      printf "%s", body
    }
  '
}

echo "Target: $OMP_AGENT"
echo "Mode:   $([ "$APPLY" -eq 1 ] && echo APPLY || echo 'dry run (pass --apply to write)')"
echo

# ============================ CONVERT (into $STAGE) ==========================

# --- agents: Claude frontmatter -> omp frontmatter ---
mkdir -p "$STAGE/agents"
if [ -d "$REPO_ROOT/agents" ]; then
  for src in "$REPO_ROOT"/agents/*.md; do
    [ -e "$src" ] || continue
    base="$(basename "$src")"
    out="$STAGE/agents/$base"
    convert_agent < "$src" > "$out"
    if head -n1 "$out" | grep -q "__CONVERT_ERROR__"; then
      echo "  WARNING: skipping $base — $(head -n1 "$out" | sed 's/__CONVERT_ERROR__ //')" >&2
      rm -f "$out"
    fi
  done
fi

# --- skills: verbatim ---
if [ -d "$REPO_ROOT/skills" ]; then
  mkdir -p "$STAGE/skills"
  # Copy the whole skills tree (each <name>/SKILL.md plus any sibling assets).
  ( cd "$REPO_ROOT/skills" && find . -type f -print0 ) | \
  while IFS= read -r -d '' rel; do
    mkdir -p "$STAGE/skills/$(dirname "$rel")"
    cp "$REPO_ROOT/skills/$rel" "$STAGE/skills/$rel"
  done
fi

# --- commands: verbatim ---
if [ -d "$REPO_ROOT/commands" ]; then
  mkdir -p "$STAGE/commands"
  for src in "$REPO_ROOT"/commands/*.md; do
    [ -e "$src" ] || continue
    cp "$src" "$STAGE/commands/$(basename "$src")"
  done
fi

# --- hooks: emit TS adapter + copy runtime .sh (never *.test.sh) ---
if [ "$WITH_HOOKS" -eq 1 ] && [ -d "$REPO_ROOT/hooks" ]; then
  mkdir -p "$STAGE/hooks/scripts" "$STAGE/hooks/pre"
  for src in "$REPO_ROOT"/hooks/*.sh; do
    [ -e "$src" ] || continue
    case "$src" in
      *.test.sh) continue ;;
    esac
    cp "$src" "$STAGE/hooks/scripts/$(basename "$src")"
  done
  # The adapter is written here, not tracked in the repo. Its layout
  # assumption: it sits at <hooks>/pre/claude-compat.ts and the scripts sit at
  # <hooks>/scripts/*.sh (i.e. ../scripts relative to itself).
  cat > "$STAGE/hooks/pre/claude-compat.ts" <<'TS'
// claude-compat.ts — generated by scripts/sync-omp-config.sh. Do not edit by
// hand; regenerate from the source hooks/*.sh via that script.
//
// Bridges the repo's Claude Code hooks to the omp HookAPI by shelling out to
// the original shell scripts (in ../scripts) and translating their I/O.
//
// Event map (Claude hook -> omp event):
//   UserPromptSubmit  response-style.sh          -> before_agent_start
//   PostCompact       plan-context.sh            -> session.compacting
//   PreToolUse Bash   enforce-git-conventions.sh -> tool_call (bash)
//   PostToolUse Edit/Write auto-format.sh,
//                          auto-test-runner.sh   -> tool_result (write/edit)
//
// Known limitations:
//   - PermissionRequest (auto-approve-safe-ops.sh) has NO omp hook event and
//     is intentionally NOT wired. Express that policy through omp's approval /
//     allowlist settings instead.
//   - pr-merge-sync-reminder.sh is wired ONLY in the project-scoped
//     hooks/settings.json (PostToolUse Bash(gh *)), never the global
//     settings.json: it is meaningful only inside this repo (it points the
//     user at this repo's sync-claude-config.sh after a squash merge). This
//     adapter deploys at omp USER scope, so it mirrors the GLOBAL hook set and
//     intentionally does NOT wire it — a global wiring would emit an invalid
//     sync prompt after squash merges in unrelated projects.
//   - The shell scripts consume Claude's hook stdin schema
//     ({tool_input:{command|file_path}}) and CLAUDE_PROJECT_DIR; this adapter
//     reconstructs that shape from omp event data.
//   - auto-test-runner runs detached (fire-and-forget); Claude delivered its
//     result on the next turn, which this cannot replicate synchronously.
//   - The omp edit tool's input is a patch DSL, not a discrete file_path, so
//     file_path is recovered best-effort from the first [PATH#TAG] header;
//     the write tool's `path` is used directly.

import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";
import { spawnSync, spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPTS = join(dirname(fileURLToPath(import.meta.url)), "..", "scripts");

type ShResult = { code: number; stdout: string; stderr: string };

function runScript(name: string, stdin: string, cwd: string): ShResult {
  const r = spawnSync("bash", [join(SCRIPTS, name)], {
    input: stdin,
    cwd,
    env: { ...process.env, CLAUDE_PROJECT_DIR: cwd },
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  return {
    code: r.status ?? 1,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
  };
}

// Claude hooks emit either plain text or a JSON envelope on stdout. Parse the
// envelope when present, else fall back to the raw text.
function parseHookStdout(out: string): { json: any | null; text: string } {
  const text = out.trim();
  if (text.startsWith("{")) {
    try {
      return { json: JSON.parse(text), text };
    } catch {
      /* not JSON after all */
    }
  }
  return { json: null, text };
}

function firstEditPath(input: Record<string, unknown>): string {
  // write tool: explicit path. edit tool: recover from the first hashline
  // header [some/path.ts#1A2B].
  if (typeof input.path === "string") return input.path;
  const patch = typeof input.input === "string" ? input.input : "";
  const m = patch.match(/^\s*\[([^\]#]+)#[0-9A-Fa-f]{4}\]/m);
  return m ? m[1] : "";
}

export default function claudeCompat(pi: HookAPI): void {
  // UserPromptSubmit -> reinject the response-style reminder each turn.
  pi.on("before_agent_start", async (_event, ctx) => {
    const r = runScript("response-style.sh", "", ctx.cwd);
    const text = r.stdout.trim();
    if (!text) return;
    return {
      message: {
        customType: "claude-compat-response-style",
        content: [{ type: "text", text }],
        display: false,
        details: {},
      },
    };
  });

  // PostCompact -> re-surface active plan state after compaction.
  pi.on("session.compacting", async (_event, ctx) => {
    const r = runScript("plan-context.sh", "", ctx.cwd);
    const text = r.stdout.trim();
    if (!text) return;
    return { context: [text] };
  });

  // PreToolUse Bash(git *) -> block on convention violations.
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const command = String(event.input.command ?? "");
    const stdin = JSON.stringify({ tool_name: "Bash", tool_input: { command } });
    const r = runScript("enforce-git-conventions.sh", stdin, ctx.cwd);
    const { json } = parseHookStdout(r.stdout);
    const hso = json?.hookSpecificOutput;
    if (hso?.permissionDecision === "deny") {
      return {
        block: true,
        reason: String(hso.permissionDecisionReason ?? "blocked by git conventions"),
      };
    }
  });

  // PostToolUse Edit|Write -> auto-format + fire-and-forget test runner.
  pi.on("tool_result", async (event, ctx) => {
    const notes: string[] = [];

    if (event.toolName === "write" || event.toolName === "edit") {
      const filePath = firstEditPath(event.input);
      if (filePath) {
        const stdin = JSON.stringify({ tool_input: { file_path: filePath } });
        const { json } = parseHookStdout(
          runScript("auto-format.sh", stdin, ctx.cwd).stdout,
        );
        const msg = json?.hookSpecificOutput?.systemMessage;
        if (msg) notes.push(String(msg));

        // Fire-and-forget: the test runner is long-running and self-coalescing.
        try {
          const child = spawn("bash", [join(SCRIPTS, "auto-test-runner.sh")], {
            cwd: ctx.cwd,
            env: { ...process.env, CLAUDE_PROJECT_DIR: ctx.cwd },
            stdio: ["pipe", "ignore", "ignore"],
            detached: true,
          });
          child.stdin?.end(stdin);
          child.unref();
        } catch {
          /* best-effort */
        }
      }
    }

    if (notes.length > 0) {
      return {
        content: [...event.content, { type: "text", text: notes.join("\n") }],
      };
    }
  });
}
TS
fi

# ============================ SYNC (overlay onto target) =====================

# Overlay one staged tree onto a live tree: add/update only, never delete.
# Snapshots the whole live directory (once) before its first change.
overlay_tree() {
  # $1 = staged root, $2 = live root, $3 = label
  local sroot="$1" lroot="$2" label="$3" f rel dst preexisted=0
  [ -d "$sroot" ] || return 0
  # Snapshot only a dir that existed BEFORE this run — a first-ever deploy that
  # creates the dir has nothing to preserve, and the snapshot must capture the
  # pristine pre-run state (taken before the first overwrite below).
  [ -d "$lroot" ] && preexisted=1
  while IFS= read -r -d '' f; do
    rel="${f#"$sroot"/}"
    dst="$lroot/$rel"
    if [ ! -f "$dst" ] || ! cmp -s "$f" "$dst"; then
      note "$label/$rel"
      CHANGED=$((CHANGED + 1))
      if [ "$APPLY" -eq 1 ]; then
        [ "$preexisted" -eq 1 ] && backup_dir_once "$lroot"
        mkdir -p "$(dirname "$dst")"
        cp "$f" "$dst"
      fi
    fi
  done < <(find "$sroot" -type f -print0)
}

echo "agents:"
overlay_tree "$STAGE/agents" "$OMP_AGENT/agents" "agents"
echo "skills:"
overlay_tree "$STAGE/skills" "$OMP_AGENT/skills" "skills"
echo "commands:"
overlay_tree "$STAGE/commands" "$OMP_AGENT/commands" "commands"
if [ "$WITH_HOOKS" -eq 1 ]; then
  echo "hooks:"
  overlay_tree "$STAGE/hooks" "$OMP_AGENT/hooks" "hooks"
fi

echo
if [ "$CHANGED" -eq 0 ]; then
  echo "Already in sync — nothing to do."
  exit 0
fi

if [ "$APPLY" -eq 1 ]; then
  echo "Applied $CHANGED change(s) to $OMP_AGENT."
  [ "$BACKED_UP" -eq 1 ] && echo "Backup (full snapshot of modified dirs): $BACKUP_DIR"
  if [ "$WITH_HOOKS" -eq 1 ]; then
    echo
    echo "HOOKS: wrote $OMP_AGENT/hooks/pre/claude-compat.ts + scripts/. If omp"
    echo "does not auto-discover user hooks there, register the module in"
    echo "$OMP_AGENT/config.yml. PermissionRequest (auto-approve-safe-ops.sh)"
    echo "has no omp hook event — use omp approval/allowlist settings instead."
  fi
  if [ "$MAP_MODELS" -eq 1 ]; then
    echo
    echo "MODEL ROLES: --map-models emitted @good/@fast aliases. Add to"
    echo "$OMP_AGENT/config.yml:"
    echo "  modelRoles:"
    echo "    good: <your-strong-model-selector>"
    echo "    fast: <your-fast-model-selector>"
  fi
else
  echo "$CHANGED change(s) pending. Re-run with --apply to write them."
fi
