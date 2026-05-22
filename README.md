# zac

A coding agent that lives in your terminal.

zac talks to the [Vercel AI Gateway](https://vercel.com/docs/ai-gateway) directly — one HTTPS endpoint, one streaming protocol, no SDK in between. The full binary is a few megabytes of Zig and zero runtime dependencies. The whole thing runs inline (no alt-screen takeover), pipes cleanly, and gets out of your way.

It is intentionally small. It is intentionally opinionated. It is **not** trying to be Cursor or opencode or Claude Code; it's trying to be the smallest agent you can actually live inside.

```
~3,600 LoC of Zig                  · 28 unit tests passing
8 tools · 11 prompt modes          · 6 MB debug / ~1–2 MB release
.env loader · auto-context         · per-turn auto-compaction
sandbox by default on macOS        · path guard refuses writes outside cwd
```

## What makes zac different

| | |
|---|---|
| **Inline only** | No alt-screen. No raw mode. Output flows through your terminal scrollback like any other tool. Pipe it, redirect it, `tee` it. |
| **Stale-context refresh** | zac tracks the mtime of every file it has read. Before each turn, files that changed on disk are re-read silently. Your edits stop the agent from working on a stale snapshot. |
| **Diff-aware re-reads** | When the agent re-reads a file it already has in context, only the diff since last read is sent — saves a lot of tokens on large files. |
| **Cost projection** | Each prompt shows an estimated cost *before* you hit enter, based on the current conversation size. No surprise $5 turns. |
| **Snapshots** | `/snapshot` checkpoints both the conversation *and* the files it touched. `/restore` rolls back both. Conversational undo. |
| **Per-turn git commits** | When zac touches files in a git repo, each turn becomes a real commit. Your history shows what the agent did, atomically. |

## Install

You need **Zig 0.14.x** (0.15+ has stdlib breaks; not yet supported) and a Vercel AI Gateway key.

```bash
git clone https://github.com/YuktiKholiwal/zac.git
cd zac
zig build -Doptimize=ReleaseSmall
./zig-out/bin/zac --help
```

## Configure

Pick one:

```bash
# Option A — .env file (gitignored by default)
cp .env.example .env
# then edit .env and paste your Gateway key

# Option B — shell env vars (override .env)
export AI_GATEWAY_API_KEY="vck_..."
export AI_GATEWAY_MODEL="anthropic/claude-sonnet-4-5"
```

The default model is Sonnet 4.5. Any model the Gateway routes to (`openai/gpt-4o`, `google/gemini-2.0-flash`, etc.) works.

## Use

```bash
zac                                  # interactive REPL
zac "explain this codebase"          # bare-arg one-shot
zac -p "fix the failing test"        # explicit one-shot
zac -c                               # continue last session
zac -m plan                          # start in plan mode
zac --yolo                           # auto-allow every tool
zac --allow-outside                  # permit writes outside cwd
zac --no-sandbox                     # disable macOS bash sandbox
zac --no-color                       # plain output (also auto when piped)
```

In the REPL:

```
> /mode debug              switch system prompt mode
> /model openai/gpt-4o     swap model mid-session
> /reasoning off           hide the dim reasoning stream
> /usage                   running token totals
> /squash                  manually compact history
> /snapshot <name>         checkpoint conversation + files
> /restore <name>          roll back to a snapshot
> /reset                   clear conversation history
> /help                    full command list
Ctrl-D                    quit cleanly
Ctrl-C                    cancel current turn (stays in REPL)
\ at end of line           continue input on the next line
```

## Tools

| Tool | What it does |
|---|---|
| `read` | Fetch a file with 1-indexed line numbers (`offset`/`limit` for paging). |
| `write` | Save content to a file. Refuses paths outside cwd unless `--allow-outside`. |
| `edit` | Substitute an exact span; falls back to whitespace-tolerant matching; suggests nearby lines on miss. |
| `bash` | Run a shell command. Wrapped in `sandbox-exec` on macOS by default. |
| `grep` | Substring search through files (`.gitignore`-aware). |
| `find` | Glob file discovery — `*`, `**`, `?` (`.gitignore`-aware). |
| `ls` | List a single directory's entries with type tag + size. |
| `plan` | Record a visible multi-step checklist; replaces the prior plan each call. |

Read-only tools (`read`, `grep`, `find`, `ls`, `plan`) auto-allow. The other three prompt with:

```
[y]es  [t]rust tool  [p]attern 'git '  [N]o
```

`[p]` pre-approves a prefix (e.g. `git ` after seeing `git status`), so subsequent `git diff`/`git log`/etc. don't re-prompt.

## Prompt modes

`-m <name>` at launch or `/mode <name>` mid-session:

`default · code · plan · ask · review · debug · simplify · brainstorm · write-prompt · frontend-design · review-security`

The mode swaps the system prompt; the conversation continues.

## Project context auto-loading

On startup, zac reads the first of these it finds in cwd and appends to the system prompt:

```
AGENTS.md  →  CLAUDE.md  →  .zac/AGENTS.md  →  .cursor/rules
```

Drop your project conventions in any of them; zac picks them up automatically each session.

## Architecture

```
src/main.zig         REPL, argv parsing, slash commands, session lifecycle
src/agent.zig        multi-turn streaming loop, tool-call accumulation
src/gateway.zig      HTTPS request builder, 1× retry on 5xx
src/sse.zig          Server-Sent Events parser → typed events
src/messages.zig     OpenAI chat-completions JSON shapes
src/ui.zig           inline ANSI renderer (markdown, tool icons, hyperlinks)
src/tools/*.zig      eight tool implementations
src/permission.zig   yolo / once / trust / pattern allowlists
src/session.zig      save/load to ~/.zac/last_session.json
src/compaction.zig   auto-summarise history at 100k prompt tokens
src/context.zig      AGENTS.md / CLAUDE.md auto-loader
src/gitignore.zig    small .gitignore matcher for grep + find
src/env.zig          .env file loader
src/cancel.zig       SIGINT handler for cancelling in-flight turns
src/path_guard.zig   refuse writes outside cwd unless --allow-outside
src/sandbox.zig      macOS sandbox-exec wrapper for `bash`
src/prompt.zig       11 embedded prompt modes
src/prompts/*.md     the actual mode files
```

## Build from source

```bash
zig build                              # debug
zig build -Doptimize=ReleaseSmall      # tiny release
zig build test --summary all           # 28 unit tests
zig build run -- --help                # build + run with args
```

## What zac deliberately doesn't do

- **No TUI.** No alt-screen, no mouse, no scrollback widget. The terminal already does those.
- **No MCP / ACP.** Out of scope until the upstream protocols settle and there's a real need.
- **No multi-provider abstraction.** The Gateway is the abstraction; rolling another inside zac would be redundant.
- **No syntax highlighting.** Models output unstyled code; rendering it costs more than it's worth.

## Credits

Design loosely inspired by [zerostack](https://github.com/gi-dellav/zerostack) (GPL-3.0). zac is an independent reimplementation in Zig with a different architecture (no `rig`, no `crossterm`, no alt-screen) and different feature set (`.env`, snapshots, stale-context refresh, diff-aware re-reads, per-turn git commits).

## License

Not yet decided. Until a `LICENSE` file lands, treat the source as "available for personal use, not yet relicensable."
