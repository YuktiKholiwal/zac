# zac

A minimal CLI coding agent in Zig, talking to the [Vercel AI Gateway](https://vercel.com/docs/ai-gateway) directly over HTTPS+SSE. No SDK, no provider abstractions — one HTTP endpoint, one streaming protocol, one binary.

```
2,909 LoC Zig across 23 files
  557 lines of embedded prompt modes
   28 unit tests passing
  5.9 MB debug binary (~1–2 MB with -Doptimize=ReleaseSmall)
    0 runtime dependencies
```

Inspired by [zerostack](https://github.com/gi-dellav/zerostack) (Rust, 9.4k LoC), but ~28% the size by skipping the TUI and leaning on the Gateway for multi-provider routing.

---

## Install

Requires **Zig 0.14.x** (won't compile on 0.15+ yet) and a [Vercel AI Gateway](https://vercel.com/ai-gateway) account.

```bash
git clone https://github.com/YuktiKholiwal/zac.git
cd zac
zig build -Doptimize=ReleaseSmall
./zig-out/bin/zac --help
```

## Configure

Copy the example env and fill in your key:

```bash
cp .env.example .env
# Edit .env, paste your Gateway key
```

Or use shell env vars (they override `.env`):

```bash
export AI_GATEWAY_API_KEY="vck_..."
export AI_GATEWAY_MODEL="anthropic/claude-sonnet-4-5"   # optional
export AI_GATEWAY_BASE_URL="https://ai-gateway.vercel.sh/v1"  # optional
```

## Use it

```bash
zac                                     # interactive REPL
zac -p "explain this codebase"          # one-shot, exit after one turn
zac -c                                  # continue last session
zac -m plan                             # start in plan mode
zac --yolo                              # auto-allow every tool call
zac --allow-outside                     # permit write/edit outside cwd
```

In the REPL:

```
> /prompt debug          # switch mode mid-session
> /model openai/gpt-4o   # swap model mid-session
> /reasoning off         # hide the dim reasoning stream
> /reset                 # clear conversation history
> /help                  # full command list
> Ctrl-D                 # exit (or /exit, /quit)
> Ctrl-C                 # cancel current turn, stay in REPL
```

Multi-line input: end a line with `\` to continue.

## Tools the agent has

| Tool | What it does |
|---|---|
| `read` | Read a file with 1-indexed line numbers (offset/limit) |
| `write` | Create/overwrite a file (creates parent dirs) |
| `edit` | Replace exact text with diff context; suggests nearby lines if not found |
| `bash` | Run a shell command via `/bin/sh -c` |
| `grep` | Substring search across files, `.gitignore`-aware |
| `find_files` | Glob file discovery (`*`, `**`, `?`), `.gitignore`-aware |
| `list_dir` | List directory entries |
| `write_todo_list` | Maintain a visible task list for multi-step work |

`read`, `grep`, `find_files`, `list_dir`, `write_todo_list` auto-allow. `bash`, `write`, `edit` prompt for permission with options:

```
[y]es / [a]lways for this tool / [p]attern 'git ' / [N]o
```

Pattern allowlist means `git status` once, all subsequent `git ...` calls auto-allow.

## Prompt modes

Switch with `-m <name>` at launch or `/prompt <name>` mid-session:

| Mode | When to use |
|---|---|
| `code` (default) | General coding work, TDD-friendly |
| `plan` | Explore and produce a plan without writing code |
| `ask` | Q&A about code or systems, no tool spam |
| `review` | Correctness, design, tests, blast radius |
| `debug` | Track down a bug step-by-step |
| `simplify` | Reduce, dedupe, collapse abstractions |
| `brainstorm` | Generate options, weigh trade-offs |
| `write-prompt` | Help you write a system prompt |
| `frontend-design` | UI/UX-oriented coding |
| `review-security` | Security-focused review |
| `default` | Generic baseline |

## Project context auto-loading

On startup, zac reads the first of these it finds in cwd and appends to the system prompt:

```
AGENTS.md → CLAUDE.md → .zac/AGENTS.md → .cursor/rules
```

Drop project conventions or current-task notes in one of those and the agent picks them up automatically.

## Build from source

```bash
zig build                       # debug build
zig build -Doptimize=ReleaseSmall   # tiny release binary
zig build test --summary all    # run unit tests
zig build run -- --help         # build + run with args
```

## Architecture

```
src/main.zig         — REPL, argv parsing, slash commands, session lifecycle
src/agent.zig        — multi-turn streaming loop, tool-call accumulation
src/gateway.zig      — HTTPS request builder for /chat/completions
src/sse.zig          — Server-Sent Events parser → typed events
src/messages.zig     — OpenAI chat-completions message/tool JSON shapes
src/tools/*.zig      — eight tool implementations
src/permission.zig   — yolo / ask / session / pattern allowlist
src/session.zig      — save/load history to ~/.zac/last_session.json
src/compaction.zig   — auto-summarise history at 100k prompt tokens
src/context.zig      — AGENTS.md / CLAUDE.md auto-loader
src/gitignore.zig    — minimal gitignore parser for grep/find_files
src/env.zig          — .env file loader
src/cancel.zig       — SIGINT handler for in-flight cancellation
src/path_guard.zig   — refuse writes outside cwd unless --allow-outside
src/prompt.zig       — 11 embedded prompt modes
src/prompts/*.md     — the actual mode files
```

## What's intentionally missing

Compared to zerostack and similar tools, zac skips:

- **Full TUI** (mouse, scrollback, markdown rendering) — half their LoC; the plain-stdin REPL is small and good enough.
- **MCP / ACP** — external tool servers and editor protocols. Add later if you actually need them.
- **Sandbox** — permission prompts already gate the dangerous tools.
- **Multi-provider abstraction** — the Vercel AI Gateway is that abstraction.

## License

Not yet chosen. Open an issue if you have a preference.
