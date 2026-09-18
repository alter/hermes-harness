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
./selftest.sh          # 78 checks on this checkout, installs nothing
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
   whose `depends:` are all `done`.
2. The loop sets `status: in_progress`, makes a notes directory inside the working directory, and hands Hermes
   the task body plus the rules for the run, including where to write `NOTES.md` and `BLOCKED.md`.
3. `hermes chat -Q --format stream-json` runs it headless with approvals off. The transcript lands in
   `.hermes-harness/logs/<task>.ndjson`.
4. Afterwards the loop moves the agent's notes into the task directory and records what changed: how many files
   the agent touched, and — only when `VERIFY` contains a shell command in backticks — what that command
   printed and exited with.
5. Exit 0 with something changed or recorded → `status: review` and a commit of the code (never of `tasks/`).
   Nothing changed and nothing written, or a non-zero exit → the task stays open with a note saying which.
6. `BLOCKED.md` written by the agent, or `HH_MAX_ATTEMPTS` (3) attempts without progress → `status: blocked`.
   Putting the task back to `todo` clears its attempt counter, so a reset really is a reset.

**A task that stays open resumes its session; it does not start over.** Hermes ends a turn the moment the model
answers with prose instead of an action, so an agent that is halfway through a diagnosis simply stops, exit 0,
mid-sentence. Its Stop-hook analogue (`pre_verify`) only fires on a turn that ran `write_file` or `patch`, so a
turn spent reading and running commands gets no nudge at all. Starting the next attempt from scratch throws away
a warm cache — in one measured run 452k of the 499k tokens were cache reads — and repeats the same
investigation. The loop records the `session_id` from the run and the next attempt continues it with a short
prompt to pick up where it stopped and to leave notes this time. The session id is cleared when the task reaches
`review` or `blocked`, or when someone resets it to `todo`.

**The loop does not decide whether the work is any good, and that is deliberate.** In a real tree `OUTCOME`
describes what must become true and `VERIFY` lists criteria a human reviewer judges — neither is a path to stat
or a command to run. A loop that guesses a path out of prose does not fail loudly; it silently throws away work
that was done. So the loop records evidence and hands over. `review` means "the agent ran and left something
behind"; only the reviewer turns that into `done` / `verify: passed`, and the loop never writes either.

Only one loop may work a task tree at a time: the second is refused with the first one's pid, because two
loops share the attempt counters, the status field and the log file names, and the mess that makes is not
obvious while it is happening. A lock left by a dead process is taken over with a note.

Knobs: `HH_MAX_TASKS` — how many tasks to **attempt** before stopping, 0 for until nothing is ready; `HH_MAX_ATTEMPTS` — how many runs one task gets before it is blocked (the counter lives in `.hermes-harness/attempts/` and is cleared when someone puts the task back to `todo`); `HH_RUN_VERIFY=0` to skip the check,
`HH_PROFILE`, `HH_TASK_ROOT`, and `HH_WORKDIR` — the directory the agent works in, when it should not be the
one holding the task tree (see below).

## What the harness does not put its name on

A commit the loop makes carries the repository's own configured identity — the same author as any other commit
there. It does not stamp the tool into the author field, the email or the message, and it refuses to commit at
all rather than invent an identity when git has none configured. What made a change is the owner's to disclose,
wherever a project asks for it; a tool that announces itself in every log line takes that choice away.

The same holds for what the agent writes. `NOTES.md` records what was done and measured, not what produced it.

## What stops the agent touching `verify:`

`hooks/guard-paths.py` on `pre_tool_call`, `fail_closed: true`, matching `write_file|patch|terminal`. The whole
`tasks/` tree is refused except `NOTES.md` and `BLOCKED.md`: a path in `write_file`, every `*** Update File:`
header in a V4A patch, and any shell command that names a path in the tree — with a mutator or a redirect, or at
all. Malformed input blocks too, because `fail_closed` means a crashed guard is a closed door. Underneath it,
`approvals.deny` globs block the same paths before `--yolo`, `/yolo` and `approvals.mode: off` are even consulted
— that floor is the only rule in Hermes that survives yolo.

Through the shell the rule is blunt on purpose: **no terminal command may name a path in the tree or a file
belonging to it** — not to write, not to read, not to `git add`. On top of that, an interpreter (`python`,
`perl`, `node`, a nested `sh -c`) handed code that mentions the tree and writes is refused even when the path is
assembled from pieces at run time. The selftest carries the bypasses it is known to stop, including the one a
27B model found on the first try.

**Where this stops being a guarantee, plainly.** A guard that reads command text cannot see what a program does.
Two examples it will not catch: a path decoded from base64 inside the interpreter, and — trivially — a helper
script written to `/tmp` (legal, outside the tree) and then run by a command that mentions nothing protected.
`terminal` runs as your user; `approvals.deny` is a string policy, not a sandbox. Layers make it hard, not
impossible, and an agent that wants through will get through.

**The fix that is a guarantee: do not hand it the file.** Point the agent at a working directory that has no
task tree in it, and there is nothing left to defend:

```bash
git -C /path/to/project worktree add --no-checkout /home/you/project-work agent/work
cd /home/you/project-work
git sparse-checkout init --no-cone
git sparse-checkout set '/*' '!/tasks/'        # the name the tree has IN THAT COMMIT
git checkout
HH_WORKDIR=/home/you/project-work ~/.hermes/harness/run.sh /path/to/project
```

Check it: `ls` in the worktree must not show the tree under any name. An uncommitted rename is the trap —
sparse-checkout excludes the name the *commit* uses, not the name your working copy shows, so a tree renamed but
not yet committed stays fully checked out under its old name and the isolation silently does nothing. `run.sh`
warns on startup when it finds the tree inside the working directory, and exports `HH_PROTECTED_ROOT` so the
guard defends the directory the tree is actually called rather than a name baked in at install time.

The loop keeps reading the tree from the real checkout, the agent never sees it, and the work lands on its own
branch. `run.sh` says so on every start while the tree is still inside the agent's working directory. Stronger
still, and orthogonal: run Hermes as another user, or in a container with the tree bind-mounted read-only.

The quieter half of the defence is that the agent gains nothing by going there. The loop injects the task into
the prompt and derives status from evidence, so a forged `status: done` changes nothing except the moment
someone notices.

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
