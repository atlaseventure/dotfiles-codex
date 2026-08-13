/**
 * GPT Responses Fix
 *
 * For models whose id contains "gpt-5" and use the OpenAI Responses API
 * (`openai-responses`), apply small request rewrites some gateways need.
 *
 * 1) instructions-fix (default: on)
 *    pi normally puts the system prompt in `input` as a single `developer`
 *    (or `system`) message. Some gateways behave better when that text lives
 *    in the top-level `instructions` field instead (Codex-style).
 *    Moves the first developer/system string in `input` to `instructions`
 *    and drops those role entries from `input`.
 *
 * 2) max-tokens-fix (default: on)
 *    pi always sends `max_output_tokens` from model.maxTokens. Some gateways
 *    (e.g. Micu gpt-5.6-*) reject any `max_output_tokens` with upstream 400.
 *    Strips `max_output_tokens` from the outbound payload.
 *
 * Toggles:
 *   /gpt-responses-fix [status]
 *   /gpt-responses-fix instructions [on|off|status]  (bare = toggle)
 *   /gpt-responses-fix max-tokens [on|off|status]    (bare = toggle)
 *
 * Status bar (only while active model id contains "gpt-5"):
 *   `instructions-fix:on/off max-tokens-fix:on/off`
 *
 * State is in-memory only (resets each pi start).
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Rec = Record<string, unknown>;

interface ModelLike {
    api?: string;
    id?: string;
}

function modelIdHasGpt5(model: ModelLike | undefined | null): boolean {
    if (!model?.id) return false;
    return model.id.toLowerCase().includes("gpt-5");
}

function isSystemRole(role: unknown): boolean {
    return role === "developer" || role === "system";
}

function extractInstructionsFromInput(input: Rec[]): { instructions: string; rest: Rec[] } | null {
    let instructions: string | undefined;
    const rest: Rec[] = [];

    for (const item of input) {
        if (!instructions && isSystemRole(item.role)) {
            const content = item.content;
            if (typeof content === "string" && content.length > 0) {
                instructions = content;
                continue;
            }
        }
        rest.push(item);
    }

    if (!instructions) return null;
    return { instructions, rest };
}

function parseToggleArg(raw: string): "on" | "off" | "status" | "toggle" | "bad" {
    const arg = raw.trim().toLowerCase();
    if (arg === "") return "toggle";
    if (arg === "on" || arg === "off" || arg === "status") return arg;
    return "bad";
}

export default function gptResponsesFix(pi: ExtensionAPI) {
    let instructionsFixEnabled = true;
    let maxTokensFixEnabled = true;

    function statusLine(): string {
        const instr = instructionsFixEnabled ? "on" : "off";
        const maxTok = maxTokensFixEnabled ? "on" : "off";
        return `instructions-fix:${instr} max-tokens-fix:${maxTok}`;
    }

    function updateStatus(ctx: ExtensionContext, modelOverride?: ModelLike): void {
        const m = modelOverride ?? ctx.model;
        const theme = ctx.ui.theme;
        if (modelIdHasGpt5(m)) {
            const anyOn = instructionsFixEnabled || maxTokensFixEnabled;
            const txt = statusLine();
            ctx.ui.setStatus(
                "gpt-responses-fix",
                anyOn ? theme.fg("success", txt) : theme.fg("muted", txt),
            );
        } else {
            ctx.ui.setStatus("gpt-responses-fix", undefined);
        }
    }

    function applyToggle(
        which: "instructions" | "max-tokens",
        mode: "on" | "off" | "status" | "toggle",
        ctx: ExtensionContext,
    ): void {
        const label = which === "instructions" ? "instructions-fix" : "max-tokens-fix";
        const get = () => (which === "instructions" ? instructionsFixEnabled : maxTokensFixEnabled);
        const set = (v: boolean) => {
            if (which === "instructions") instructionsFixEnabled = v;
            else maxTokensFixEnabled = v;
        };

        if (mode === "status") {
            ctx.ui.notify(`${label}: ${get() ? "ON" : "OFF"}`, "info");
            return;
        }
        if (mode === "on") set(true);
        else if (mode === "off") set(false);
        else set(!get());

        ctx.ui.notify(`${label}: ${get() ? "ON" : "OFF"}`, "info");
        updateStatus(ctx);
    }

    pi.on("before_provider_request", async (event, ctx) => {
        if (!instructionsFixEnabled && !maxTokensFixEnabled) return undefined;

        const model = ctx.model;
        if (!modelIdHasGpt5(model)) return undefined;
        if (model?.api !== "openai-responses") return undefined;

        const payload = event.payload as Rec | undefined;
        if (!payload) return undefined;

        let next: Rec | undefined;
        let changed = false;

        if (instructionsFixEnabled && Array.isArray(payload.input)) {
            const extracted = extractInstructionsFromInput(payload.input as Rec[]);
            if (extracted) {
                next = {
                    ...(next ?? payload),
                    instructions: extracted.instructions,
                    input: extracted.rest,
                };
                changed = true;
            }
        }

        if (maxTokensFixEnabled) {
            const src = next ?? payload;
            if ("max_output_tokens" in src) {
                next = { ...src };
                delete next.max_output_tokens;
                changed = true;
            }
        }

        return changed ? next : undefined;
    });

    pi.registerCommand("gpt-responses-fix", {
        description:
            "GPT Responses rewrites for gpt-5* (instructions / max-tokens). Usage: /gpt-responses-fix [status|instructions|max-tokens] [on|off|status]",
        getArgumentCompletions: (prefix: string) => {
            const parts = prefix.trim().split(/\s+/).filter(Boolean);

            // Completing first token
            if (parts.length === 0 || (parts.length === 1 && !prefix.endsWith(" "))) {
                const opts = ["status", "instructions", "max-tokens"];
                return opts
                    .filter((o) => o.startsWith(parts[0]?.toLowerCase() ?? ""))
                    .map((o) => ({ value: o, label: o }));
            }

            // Completing second token for a path
            const path = parts[0]?.toLowerCase();
            if (path === "instructions" || path === "max-tokens") {
                const second = parts.length >= 2 && !prefix.endsWith(" ") ? parts[1].toLowerCase() : "";
                const opts = ["on", "off", "status"];
                return opts
                    .filter((o) => o.startsWith(second))
                    .map((o) => ({ value: `${path} ${o}`, label: o }));
            }

            return [];
        },
        handler: async (args: string, ctx) => {
            const raw = args.trim();
            if (raw === "" || raw.toLowerCase() === "status") {
                ctx.ui.notify(
                    `gpt-responses-fix: instructions=${instructionsFixEnabled ? "ON" : "OFF"}, max-tokens=${maxTokensFixEnabled ? "ON" : "OFF"}`,
                    "info",
                );
                return;
            }

            const [path, ...rest] = raw.split(/\s+/);
            const pathKey = path.toLowerCase();
            const restArg = rest.join(" ");

            if (pathKey === "instructions") {
                const mode = parseToggleArg(restArg);
                if (mode === "bad") {
                    ctx.ui.notify("Usage: /gpt-responses-fix instructions [on|off|status]", "error");
                    return;
                }
                applyToggle("instructions", mode, ctx);
                return;
            }

            if (pathKey === "max-tokens") {
                const mode = parseToggleArg(restArg);
                if (mode === "bad") {
                    ctx.ui.notify("Usage: /gpt-responses-fix max-tokens [on|off|status]", "error");
                    return;
                }
                applyToggle("max-tokens", mode, ctx);
                return;
            }

            ctx.ui.notify(
                "Usage: /gpt-responses-fix [status|instructions|max-tokens] [on|off|status]",
                "error",
            );
        },
    });

    pi.on("session_start", async (_event, ctx) => {
        updateStatus(ctx);
    });

    pi.on("model_select", async (event, ctx) => {
        updateStatus(ctx, event.model);
    });
}
