# verdict.py
import json
import pathlib
import sys

envelope_path, task_dir, rc = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
test_cmd = sys.argv[4] if len(sys.argv) > 4 else ""

why = []
try:
    envelope = json.loads(envelope_path.read_text(encoding="utf-8"))
except Exception:
    envelope = {}
if not isinstance(envelope, dict):
    why.append("the envelope is not a JSON object")
    envelope = {}

raw_out = envelope.get("structured_output")
if raw_out is None:
    out = {}
elif not isinstance(raw_out, dict):
    why.append("not in the agreed shape: structured_output")
    out = {}
else:
    out = raw_out
if out:
    why += [f"not in the agreed shape: {name} is missing"
            for name in ("verdict", "summary", "evidence", "unmet") if name not in out]


def as_text(name: str) -> str:
    value = out.get(name, "")
    if isinstance(value, str):
        return value
    why.append(f"not in the agreed shape: {name}")
    return ""


def as_list(name: str) -> list:
    value = out.get(name, [])
    if isinstance(value, list):
        return value
    why.append(f"not in the agreed shape: {name}")
    return []


verdict, summary, next_step = as_text("verdict"), as_text("summary"), as_text("next_step")

evidence = []
for number, item in enumerate(as_list("evidence"), 1):
    if not isinstance(item, dict):
        why.append(f"not in the agreed shape: evidence[{number}]")
        continue
    clean = {}
    for field in ("claim", "command", "output"):
        if field in item and not isinstance(item[field], str):
            why.append(f"not in the agreed shape: evidence[{number}].{field}")
        else:
            clean[field] = item.get(field, "")
    if not clean.get("claim", "").strip():
        why.append(f"evidence item {number} has no claim")
    evidence.append(clean)

unmet = []
for number, item in enumerate(as_list("unmet"), 1):
    if isinstance(item, str):
        unmet.append(item)
    else:
        why.append(f"not in the agreed shape: unmet[{number}]")
unmet = [u for u in unmet if u.strip()]

raw_denials = envelope.get("permission_denials", [])
denials, denied_commands = [], []
malformed_denials = not isinstance(raw_denials, list) or any(
    not isinstance(d, dict) or not isinstance(d.get("tool_input", {}), dict) for d in raw_denials
)
if malformed_denials:
    why.append("permission_denials is not in the shape the CLI documents")
else:
    denials = raw_denials
    # A refused command is not by itself a failed review: the reviewer reads the file
    # instead and says so. It only ruins the review when the thing refused was the
    # project's own check, which nothing else can stand in for — and matching that by
    # the command's first word calls every refused `python3 ...` a refused test run.
    denied_commands = [str(d.get("tool_input", {}).get("command", d.get("tool_name", "?"))) for d in denials]

if rc != "0" or envelope.get("is_error"):
    why.append(f"claude exited {rc}" + (f": {str(envelope.get('result'))[:200]}" if envelope.get("result") else ""))
if not verdict:
    why.append("the run produced no verdict")
elif verdict not in ("passed", "failed", "blocked"):
    why.append(f"the verdict '{verdict}' is not one the harness knows")
if test_cmd:
    ran = any(test_cmd in e.get("command", "") for e in evidence)
    refused = any(test_cmd in c for c in denied_commands)
    if refused and not ran:
        why.append(f"the project's own check ({test_cmd}) was refused, so nothing verified it")
if verdict == "passed" and not evidence:
    why.append("a passing verdict with no evidence behind it")
if verdict == "passed" and unmet:
    why.append("a passing verdict that lists unmet criteria")
if verdict == "failed" and not unmet and not next_step.strip():
    why.append("a failing verdict that does not say what is missing")

lines = [f"# Review — {verdict or 'no verdict'}", "", summary.strip() or "(no summary)", ""]
if unmet:
    lines += ["## Not met", ""] + [f"- {u.strip()}" for u in unmet] + [""]
if evidence:
    lines += ["## Evidence", ""]
    for item in evidence:
        lines.append(f"- {item.get('claim', '').strip()}")
        if item.get("command"):
            lines.append(f"  - `{item['command'].strip()}`")
        if item.get("output"):
            body = item["output"].strip().splitlines()[:12]
            lines += ["    ```"] + [f"    {line}" for line in body] + ["    ```"]
    lines.append("")
if denied_commands:
    lines += ["## Commands the reviewer was not allowed to run", ""] \
             + [f"- `{c[:200]}`" for c in denied_commands] + [""]
if next_step:
    lines += ["## Next step", "", next_step.strip(), ""]
if why:
    lines += ["## This review is not usable", ""] + [f"- {w}" for w in why] + [""]
# A review that verified nothing must not overwrite one that did. The last
# usable verdict is what the next run reads, and losing it to a failed attempt
# is worse than having no attempt at all.
target = task_dir / ("REVIEW.unusable.md" if why else "REVIEW.md")
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
if not why:
    (task_dir / "REVIEW.unusable.md").unlink(missing_ok=True)
    # A reader has now looked at the change, so the gate's note is the older word.
    (task_dir / "CHECK.md").unlink(missing_ok=True)

with (task_dir / "NOTES.md").open("a", encoding="utf-8") as fh:
    if why:
        fh.write("\n## review: not usable\n\n" + "\n".join(f"- {w}" for w in why) + "\n")
    else:
        fh.write(f"\n## review: {verdict}\n\n{summary.strip()}\n")

print(verdict or "none", len(denials), "no" if why else "yes")
