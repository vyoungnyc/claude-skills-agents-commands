# caveman (omp extension)

**Why use many token when few do trick.**

An [omp](https://github.com/oh-my-pi) (oh-my-pi) extension that compresses agent
output while keeping full technical accuracy. It injects the caveman
communication rules into the system prompt, adds a `/caveman` command and an
animated status bar, and can auto-activate on every session.

## What tracks upstream

The injected **rules are not hardcoded**. They live in
[`prompts/caveman.SKILL.md`](./prompts/caveman.SKILL.md) — a verbatim vendored
copy of `skills/caveman/SKILL.md` from
[JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) (the canonical
caveman skill). The extension reads that file at runtime, strips the YAML
frontmatter, injects the body, and appends the active level.

Stay in sync with upstream with one command (from the repo root):

```bash
scripts/update-caveman-prompt.sh          # fetch upstream, write if changed
scripts/update-caveman-prompt.sh --check  # CI: exit 3 if the vendored copy is stale
```

The command machinery (session-persistent level, status bar, config dialog,
`before_agent_start` injection) is ported from
[jonjonrankin/pi-caveman](https://github.com/jonjonrankin/pi-caveman); only the
imports (`@oh-my-pi/*`), the config path (`getAgentDir()`), and the prompt
source (vendored `SKILL.md` instead of inline strings) differ.

## Install

Deployed by the repo's omp sync script into `~/.omp/agent/extensions/caveman/`,
which omp auto-discovers:

```bash
scripts/sync-omp-config.sh          # dry run
scripts/sync-omp-config.sh --apply  # install
```

The shared default settings ([`caveman.default.json`](./caveman.default.json):
`defaultLevel: full`, `showStatus: true`) seed `~/.omp/agent/caveman.json` on
first apply if it does not exist yet — so a fresh install starts in caveman mode
on every session, and your own later edits are never clobbered.

## Usage

```
/caveman              Toggle on (full) / off
/caveman lite         Professional, no fluff
/caveman full         Classic caveman (default)
/caveman ultra        Maximum compression
/caveman wenyan-lite  Semi-classical Chinese
/caveman wenyan-full  Full 文言文
/caveman wenyan-ultra Extreme 文言文
/caveman config       Open settings dialog (default level, status bar)
/caveman off          Disable (aliases: stop, quit)
```

Levels mirror the upstream `SKILL.md` Intensity table. Config persists to
`~/.omp/agent/caveman.json`.

## License

MIT. The vendored prompt is MIT + BSL-1.1 dual-licensed by upstream; the skill
text used here is the MIT skill file.
