/**
 * caveman — why use many token when few do trick.
 *
 * An omp (oh-my-pi) extension that compresses agent output while keeping full
 * technical accuracy. The machinery (session-persistent level, /caveman command,
 * animated status bar, before_agent_start injection) is ported from
 * jonjonrankin/pi-caveman; the injected RULES are NOT hardcoded here — they are
 * loaded at runtime from ../prompts/caveman.SKILL.md, a verbatim vendored copy of
 * skills/caveman/SKILL.md in https://github.com/JuliusBrussee/caveman. Refresh it
 * with scripts/update-caveman-prompt.sh so this extension tracks upstream.
 *
 * Commands:
 *   /caveman [level]  Toggle caveman mode or set intensity
 *   /caveman stop     Disable caveman mode (aliases: off, quit)
 *   /caveman config   Open settings dialog (default level, status bar toggle)
 */

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  BeforeAgentStartEventResult,
  ExtensionAPI,
  ExtensionContext,
} from "@oh-my-pi/pi-coding-agent";
import { getAgentDir, getSettingsListTheme } from "@oh-my-pi/pi-coding-agent";
import {
  Container,
  type SettingItem,
  SettingsList,
  Text,
} from "@oh-my-pi/pi-tui";

// ---------------------------------------------------------------------------
// Levels — mirror the upstream taxonomy (skills/caveman/SKILL.md "Intensity").
// ---------------------------------------------------------------------------

const LEVELS = [
  "off",
  "lite",
  "full",
  "ultra",
  "wenyan-lite",
  "wenyan-full",
  "wenyan-ultra",
] as const;
const STOP_ALIASES: Record<string, true> = {
  off: true,
  stop: true,
  quit: true,
};
type Level = (typeof LEVELS)[number];

const CAVEMAN_COMMAND_OPTIONS = [
  { value: "lite", label: "lite", description: "Professional, no fluff" },
  { value: "full", label: "full", description: "Classic caveman (default)" },
  { value: "ultra", label: "ultra", description: "Maximum compression" },
  {
    value: "wenyan-lite",
    label: "wenyan-lite",
    description: "Semi-classical Chinese",
  },
  { value: "wenyan-full", label: "wenyan-full", description: "Full 文言文" },
  {
    value: "wenyan-ultra",
    label: "wenyan-ultra",
    description: "Extreme 文言文",
  },
  { value: "off", label: "off", description: "Disable caveman mode" },
  { value: "stop", label: "stop", description: "Disable caveman mode" },
  { value: "quit", label: "quit", description: "Disable caveman mode" },
  { value: "config", label: "config", description: "Open settings dialog" },
] as const;

// ---------------------------------------------------------------------------
// Vendored prompt — loaded once from disk, frontmatter stripped, cached.
// ---------------------------------------------------------------------------

const PROMPT_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "prompts",
  "caveman.SKILL.md",
);
let promptCache: string | null = null;

/** Drop a leading YAML frontmatter block (--- ... ---) if present. */
function stripFrontmatter(md: string): string {
  if (!md.startsWith("---")) return md;
  const close = md.indexOf("\n---", 3);
  if (close === -1) return md;
  const bodyStart = md.indexOf("\n", close + 1);
  return bodyStart === -1 ? "" : md.slice(bodyStart + 1);
}

async function loadPrompt(): Promise<string> {
  if (promptCache !== null) return promptCache;
  const raw = await readFile(PROMPT_PATH, "utf8");
  promptCache = stripFrontmatter(raw).trim();
  return promptCache;
}

/** OMP passes ordered string[] blocks; upstream Pi passes one string. */
function appendSystemPrompt(
  systemPrompt: string | string[] | null | undefined,
  addition: string,
): string | string[] {
  if (Array.isArray(systemPrompt)) {
    return [...systemPrompt, addition];
  }
  const basePrompt =
    typeof systemPrompt === "string"
      ? systemPrompt
      : String(systemPrompt ?? "");
  return basePrompt ? `${basePrompt}\n\n${addition}` : addition;
}

// ---------------------------------------------------------------------------
// Persistent config (survives across sessions), stored in omp's agent dir.
// ---------------------------------------------------------------------------

interface CavemanConfig {
  /** Level to apply on new sessions. "off" means don't auto-enable. */
  defaultLevel: Level;
  /** Whether to show the animated footer status. */
  showStatus: boolean;
}

const CONFIG_PATH = join(getAgentDir(), "caveman.json");
const DEFAULT_CONFIG: CavemanConfig = {
  defaultLevel: "full",
  showStatus: true,
};
let saveConfigQueue: Promise<void> = Promise.resolve();

async function loadConfig(): Promise<CavemanConfig> {
  try {
    const raw = await readFile(CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return {
      defaultLevel: LEVELS.includes(parsed.defaultLevel)
        ? parsed.defaultLevel
        : DEFAULT_CONFIG.defaultLevel,
      showStatus:
        typeof parsed.showStatus === "boolean"
          ? parsed.showStatus
          : DEFAULT_CONFIG.showStatus,
    };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

async function saveConfig(config: CavemanConfig): Promise<void> {
  const snapshot = JSON.stringify(config, null, 2) + "\n";
  saveConfigQueue = saveConfigQueue.then(async () => {
    await mkdir(getAgentDir(), { recursive: true });
    await writeFile(CONFIG_PATH, snapshot, "utf8");
  });
  return saveConfigQueue;
}

// ---------------------------------------------------------------------------
// Animated status bar — campfire with 256-color fire palette
// ---------------------------------------------------------------------------

interface Animation {
  frames: string[];
  label: string;
  /** ms between frames */
  interval: number;
}

const R = "\x1b[38;5;196m"; // red
const O = "\x1b[38;5;208m"; // orange
const Y = "\x1b[38;5;220m"; // yellow
const W = "\x1b[38;5;230m"; // white-hot
const E = "\x1b[38;5;52m"; // ember (dark red)
const X = "\x1b[0m"; // reset

const FIRE_FRAMES = [
  `${R}⠠${O}⠄${X}`,
  `${O}⠔${Y}⠂${X}`,
  `${Y}⠊${W}⠑${X}`,
  `${W}⠑${Y}⠊${X}`,
  `${Y}⠂${O}⠔${X}`,
  `${O}⠄${R}⠠${X}`,
  `${R}⠠${E}⠄${X}`,
  `${E}⠔${R}⠂${X}`,
];

const ANIMATIONS: Record<Exclude<Level, "off">, Animation> = {
  lite: { frames: FIRE_FRAMES, label: "LITE", interval: 300 },
  full: { frames: FIRE_FRAMES, label: "FULL", interval: 200 },
  ultra: { frames: FIRE_FRAMES, label: "ULTRA", interval: 100 },
  "wenyan-lite": { frames: FIRE_FRAMES, label: "文言", interval: 300 },
  "wenyan-full": { frames: FIRE_FRAMES, label: "文言文", interval: 200 },
  "wenyan-ultra": { frames: FIRE_FRAMES, label: "文言文極", interval: 100 },
};

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function caveman(pi: ExtensionAPI) {
  let level: Level = "off";
  let config: CavemanConfig = { ...DEFAULT_CONFIG };
  let timer: ReturnType<typeof setInterval> | null = null;
  let frameIndex = 0;
  let isActive = false;
  let configLoadPromise: Promise<void> | null = null;

  const ensureConfigLoaded = async () => {
    if (!configLoadPromise) {
      configLoadPromise = (async () => {
        config = await loadConfig();
        if (level === "off" && config.defaultLevel !== "off") {
          level = config.defaultLevel;
        }
      })();
    }
    await configLoadPromise;
  };

  // -- Animation helpers --

  function stopAnimation() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    frameIndex = 0;
  }

  function syncStatus(ctx: Pick<ExtensionContext, "ui">) {
    stopAnimation();
    const theme = ctx.ui.theme;

    if (level === "off" || !config.showStatus) {
      ctx.ui.setStatus("caveman", "");
      return;
    }

    const anim = ANIMATIONS[level];
    const setFrame = (frame: string) => {
      ctx.ui.setStatus(
        "caveman",
        frame +
          " " +
          theme.fg("muted", "caveman level: ") +
          theme.fg("text", anim.label),
      );
    };

    if (!isActive) {
      setFrame(anim.frames[0]!);
      return;
    }

    const renderFrame = () => {
      setFrame(anim.frames[frameIndex % anim.frames.length]!);
      frameIndex++;
    };

    renderFrame();
    timer = setInterval(renderFrame, anim.interval);
  }

  // -- Restore state on session load --

  pi.on("session_start", async (_event, ctx) => {
    await ensureConfigLoaded();

    // Check for session-level override first (resuming a session)
    let sessionLevel: Level | null = null;
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && entry.customType === "caveman-level") {
        const data = entry.data;
        if (data && typeof data === "object" && "level" in data) {
          const candidate = data.level;
          if (
            typeof candidate === "string" &&
            (LEVELS as readonly string[]).includes(candidate)
          ) {
            sessionLevel = candidate as Level;
          }
        }
      }
    }

    if (sessionLevel !== null) {
      // Resuming — use session state
      level = sessionLevel;
    } else if (config.defaultLevel !== "off") {
      // New session — apply default from config
      level = config.defaultLevel;
      pi.appendEntry("caveman-level", { level });
    }

    syncStatus(ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    isActive = true;
    syncStatus(ctx);
  });

  pi.on("agent_end", async (_event, ctx) => {
    isActive = false;
    syncStatus(ctx);
  });

  pi.on("session_shutdown", async () => {
    stopAnimation();
    isActive = false;
  });

  // -- /caveman command --

  pi.registerCommand("caveman", {
    description:
      "Toggle caveman mode, set level, use stop/off/quit to disable, or 'config' to open settings",
    getArgumentCompletions: (prefix: string) => {
      const normalized = prefix.trim().toLowerCase();
      const items = CAVEMAN_COMMAND_OPTIONS.filter((item) =>
        item.value.startsWith(normalized),
      );
      return items.length > 0 ? items : null;
    },
    handler: async (args, ctx) => {
      const arg = args?.trim().toLowerCase();

      // Open config dialog
      if (arg === "config") {
        await openConfig(ctx);
        return;
      }

      if (!arg) {
        level = level === "off" ? "full" : "off";
      } else if (STOP_ALIASES[arg]) {
        level = "off";
      } else if (LEVELS.includes(arg as Level)) {
        level = arg as Level;
      } else {
        ctx.ui.notify(
          `Unknown: "${arg}". Use: ${LEVELS.join(", ")}, stop, quit, or config`,
          "error",
        );
        return;
      }

      pi.appendEntry("caveman-level", { level });
      syncStatus(ctx);

      ctx.ui.notify(
        level === "off"
          ? "Caveman mode off."
          : `Caveman: ${ANIMATIONS[level].label}`,
        "info",
      );
    },
  });

  // -- /caveman config: interactive SettingsList --

  async function openConfig(ctx: ExtensionContext) {
    await ensureConfigLoaded();

    await ctx.ui.custom((_tui, theme, _kb, done) => {
      const items: SettingItem[] = [
        {
          id: "defaultLevel",
          label: "Default level for new sessions",
          currentValue: config.defaultLevel,
          values: [...LEVELS],
        },
        {
          id: "showStatus",
          label: "Show animated status bar",
          currentValue: config.showStatus ? "on" : "off",
          values: ["on", "off"],
        },
      ];

      const container = new Container();
      container.addChild(
        new Text(theme.fg("accent", theme.bold(" Caveman Config")), 0, 0),
      );
      container.addChild(
        new Text(theme.fg("dim", ` Saved to ${CONFIG_PATH}`), 0, 0),
      );
      container.addChild(
        new Text(
          theme.fg("dim", " Default level applies to future sessions."),
          0,
          0,
        ),
      );
      container.addChild(new Text("", 0, 0));

      const applySettingChange = (id: string, newValue: string) => {
        if (id === "defaultLevel" && LEVELS.includes(newValue as Level)) {
          config.defaultLevel = newValue as Level;
        } else if (id === "showStatus") {
          config.showStatus = newValue === "on";
        }
        saveConfig(config);
        syncStatus(ctx);
      };

      const settingsList = new SettingsList(
        items,
        Math.min(items.length + 2, 10),
        getSettingsListTheme(),
        applySettingChange,
        () => done(undefined),
      );

      container.addChild(settingsList);
      container.addChild(
        new Text(
          theme.fg("dim", " ←→/hl/tab change • ↑↓/jk move • esc close"),
          0,
          0,
        ),
      );

      const cycleSelectedValue = (direction: -1 | 1) => {
        // SettingsList has no public selected-index getter; read its internal field.
        const listInternals = settingsList as unknown as {
          selectedIndex: number;
        };
        const selectedIndex = listInternals.selectedIndex;
        const item = items[selectedIndex];
        if (!item?.values?.length) return;

        const currentIndex = item.values.indexOf(item.currentValue);
        const nextIndex =
          (currentIndex + direction + item.values.length) % item.values.length;
        const newValue = item.values[nextIndex]!;
        item.currentValue = newValue;
        settingsList.updateValue(item.id, newValue);
        applySettingChange(item.id, newValue);
      };

      return {
        render: (w: number) => container.render(w),
        invalidate: () => container.invalidate(),
        handleInput: (data: string) => {
          if (data === "j") data = "\u001b[B";
          else if (data === "k") data = "\u001b[A";
          else if (data === "h") {
            cycleSelectedValue(-1);
            _tui.requestRender();
            return;
          } else if (data === "l" || data === "\u001b[C" || data === "\t") {
            cycleSelectedValue(1);
            _tui.requestRender();
            return;
          } else if (data === "\u001b[D") {
            cycleSelectedValue(-1);
            _tui.requestRender();
            return;
          }

          settingsList.handleInput?.(data);
          _tui.requestRender();
        },
      };
    });
  }

  // -- Inject caveman rules (from the vendored upstream SKILL.md) --

  pi.on("before_agent_start", async (event) => {
    await ensureConfigLoaded();
    if (level === "off") return;
    const body = await loadPrompt();
    const addition = `${body}\n\nActive caveman level: **${level}**. Apply the "${level}" row of the Intensity table above for every response this session.`;
    return {
      systemPrompt: appendSystemPrompt(
        event.systemPrompt as string | string[] | null | undefined,
        addition,
      ),
    } as unknown as BeforeAgentStartEventResult;
  });
}
