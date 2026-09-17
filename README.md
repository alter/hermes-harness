# hermes-harness

A harness that makes [Hermes Agent](https://github.com/NousResearch/hermes-agent) work a task tree on disk on its
own, overnight, against a local model — and that never lets it grade its own work.

Two hands, one tree. Hermes writes code and records what it did. A reviewer running elsewhere — in this setup
Claude Code on Sonnet/Opus — owns the `verify:` field and decides whether a task is really finished. Neither can
do the other's job, and the split is enforced, not requested.

Built against hermes-agent `0.21.3` (tag `v2026.9.14`), read from the source rather than the README.

## The two gates

Nothing else matters until both hold.

1. **Your server must emit native `tool_calls`.** Hermes has no text or XML fallback on the chat-completions
   path — a `<tool_call>` block in the reply text is stripped and thrown away (`agent/agent_runtime_helpers.py`).
   The agent then looks busy and does nothing. In practice: llama.cpp `--jinja`, vLLM
   `--enable-auto-tool-choice --tool-call-parser hermes`, SGLang `--tool-call-parser qwen`.
2. **The served context must be at least 64,000 tokens**, or the agent refuses to start
   (`MINIMUM_CONTEXT_LENGTH = 64_000`, `agent/model_metadata.py`). Auto-detection will not save you: an unknown
   `qwen*` id is assumed to be 131,072 whatever the server actually serves, so pin `model.context_length` to the
   truth.

Check both before installing anything:

```bash
curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"<id>","messages":[{"role":"user","content":"List the files here."}],
  "tools":[{"type":"function","function":{"name":"terminal","description":"run a shell command",
    "parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}]}' \
  | python3 -m json.tool | grep -A3 tool_calls
```

If that last line prints nothing, stop and fix the server. Everything downstream depends on it.

## Install

```bash
pip install pyyaml
./selftest.sh          # 58 checks on this checkout, installs nothing
./install.sh           # merges into ~/.hermes/config.yaml, copies the harness to ~/.hermes/harness
./selftest.sh ~/.hermes
```

`install.sh [profile]` installs into `~/.hermes/profiles/<profile>/` instead, so the harness can live beside a
profile you use by hand. The merge keeps your own keys and other people's hooks, prints every value it changes,
and does not duplicate a hook on a second run. `uninstall.sh <backup>` puts it all back; the backup remembers
which target it came from.

Then set the model, which the installer deliberately leaves as a placeholder:

```bash
hermes config set model.default '<the id your server reports>'
hermes config set model.base_url 'http://127.0.0.1:8080/v1'
```

In a project, copy the contract and let the task tree come from wherever you plan tasks:

```bash
cp ~/.hermes/harness/../harness/project-template/AGENTS.md .      # or from this checkout
```

Hermes reads `.hermes.md` → `AGENTS.override.md` → `AGENTS.md` → `CLAUDE.md`, first match only, merged up the
git tree from the root to the working directory. One contract, in the file the project already uses.

## Running

```bash
~/.hermes/harness/run.sh [project]
```

One loop, one task at a time:

1. `tasks.py next` picks the highest-priority task whose `status:` is open, whose `role:` is not `HUMAN`, and
   whose `depends:` is `done`.
2. The loop sets `status: in_progress` and hands Hermes the task body with the rules for the run.
3. `hermes chat -Q --format stream-json` runs it headless with approvals off. The transcript lands in
   `.hermes-harness/logs/<task>.ndjson`.
4. The loop then judges by evidence, not by the model's report: does the `OUTCOME` artefact exist at its path,
   and does the `VERIFY` command exit 0?
5. Both true → `status: review`, a line in `NOTES.md`, and a commit of the code (never of `tasks/`).
   Otherwise the task stays open with a note saying which of the two failed.
6. `BLOCKED.md` written by the agent, or `HH_MAX_ATTEMPTS` (3) attempts without progress → `status: blocked`.

The loop never writes `status: done` and never touches `verify:`. `review` means "a machine thinks this is
finished"; only the external reviewer turns that into `done` / `verify: passed`.

Knobs: `HH_MAX_TASKS` (0 = until nothing is ready), `HH_MAX_ATTEMPTS`, `HH_RUN_VERIFY=0` to skip the check,
`HH_PROFILE`, `HH_TASK_ROOT`.

## What stops the agent touching `verify:`

`hooks/guard-paths.py` on `pre_tool_call`, `fail_closed: true`, matching `write_file|patch|terminal`. The whole
`tasks/` tree is refused except `NOTES.md` and `BLOCKED.md`: a path in `write_file`, every `*** Update File:`
header in a V4A patch, and any shell command that names a path in the tree — with a mutator or a redirect, or at
all. Malformed input blocks too, because `fail_closed` means a crashed guard is a closed door. Underneath it,
`approvals.deny` globs block the same paths before `--yolo`, `/yolo` and `approvals.mode: off` are even consulted
— that floor is the only rule in Hermes that survives yolo.

**Honestly, about its limits.** `terminal` runs as your user; `approvals.deny` is a command-string policy, not a
sandbox, and the guard reads the command text, not the syscalls. A determined program — an interpreter fed a
path it builds at runtime — is not something either layer can see. Two layers make it hard, not impossible. If
you need a guarantee rather than a strong obstacle, move the tree behind file-system permissions or a read-only
bind mount; the hook stays useful either way.

The second half of the defence is that the agent has no reason to go there. The loop injects the task into the
prompt, and status is derived from evidence, so writing to the tree buys nothing.

## What we use of Hermes, and what we left alone

| Used | Why |
|---|---|
| `hermes chat -Q --format stream-json` | the only headless form that takes budget flags and emits parsable progress |
| `approvals.mode: off` + `single_query_mode: approve` | one without the other is not enough on the `-q` path |
| `approvals.deny` | the only floor that survives yolo |
| `pre_tool_call` shell hooks | the only event that can actually block a tool call |
| `AGENTS.md` | shipped contract, read automatically, merged up the git tree |
| `checkpoints.enabled` | one shadow-git snapshot per directory per turn; a coarse undo, better than none |

| Left alone | Why |
|---|---|
| Kanban | a real dispatcher with dependencies, retries and heartbeats — but SQLite is its only source of truth and nothing syncs it with files. Worth revisiting if the file loop turns out to be the weak part |
| `/goal`, `/loop`, heartbeat | they only run in the interactive REPL; `-q` and `-z` never drain the queue that drives them |
| cron | needs the gateway daemon and gives a fresh session per fire with no project context by default |
| `pre_verify` | Hermes's Stop analogue, but it fires only on a turn that edited a file and is capped by `max_verify_nudges`. With a per-task loop outside the agent, the loop re-invokes and the cap stops mattering. Raised to 8 anyway |
| `batch_runner.py` | a training-trajectory generator: it samples toolsets at random per prompt and filters samples out. Wrong tool for repeatable work |
| delegation | subagents inherit the parent's toolsets and cannot be narrowed except from a Python plugin. Depth pinned to 1 |
| memory, curator | both mutate state between runs. Off, so that two runs of the same task are the same run |

## Tuning for a small local model

`toolsets: [coding]` plus a long `disabled_toolsets` list, because the whole schema set is sent on every call and
prefill is what a local server pays for. Measure yours with `hermes prompt-size`. `tool_search` is off: it hides
MCP tools behind a search the model has to write well, which is the opposite of what a weak model wants.
`tool_use_enforcement`, `execution_guidance` and `intent_ack_continuation` are forced on rather than left at
`auto` — the first two would switch themselves on for a `qwen` id, the third would not.

Compression triggers at 75% for any window under 512k, whatever `compression.threshold` says.
`micro_compact` stays off: it rewrites the sent history every turn and destroys the prefix cache, which is the
main thing keeping a local model quick.

## Limits worth knowing before you trust it

- The loop's verdict is only as good as `OUTCOME` and `VERIFY` in the task. A task whose OUTCOME names no path
  will be marked `review` on any run that exits 0.
- There is no guard that catches the same failing command being repeated. Hermes's `stall_guards` appends a
  notice after three identical calls with identical results; it never blocks.
- `subagent_stop` cannot block, so a subagent's claim cannot be checked against its transcript the way it can in
  the Claude Code harness. Delegation is left near-off for that reason.
- A failed run leaves `status: in_progress`. That is deliberate: the tree should show that work was attempted.

## License

MIT. See `LICENSE`.
