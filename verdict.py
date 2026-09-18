# verdict.py
import json
import pathlib
import sys

envelope_path, task_dir, rc = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
test_cmd = sys.argv[4] if len(sys.argv) > 4 else ""
try:
    envelope = json.loads(envelope_path.read_text(encoding="utf-8"))
except Exception:
    envelope = {}
out = envelope.get("structured_output") or {}
denials = envelope.get("permission_denials") or []
verdict = str(out.get("verdict", ""))
evidence = out.get("evidence") or []
unmet = out.get("unmet") or []

why = []
if rc != "0" or envelope.get("is_error"):
    why.append(f"claude exited {rc}" + (f": {str(envelope.get('result'))[:200]}" if envelope.get("result") else ""))
if not verdict:
    why.append("the run produced no verdict")
# A refused command is not by itself a failed review: the reviewer reads the file
# instead and says so. It only ruins the review when the thing refused was the
# project's own check, which nothing else can stand in for — and matching that by
# the command's first word calls every refused `python3 ...` a refused test run.
denied_commands = [str(d.get("tool_input", {}).get("command", d.get("tool_name", "?"))) for d in denials]
if test_cmd:
    ran = any(test_cmd in str(e.get("command", "")) for e in evidence if isinstance(e, dict))
    refused = any(test_cmd in c for c in denied_commands)
    if refused and not ran:
        why.append(f"the project's own check ({test_cmd}) was refused, so nothing verified it")
if verdict == "passed" and not evidence:
    why.append("a passing verdict with no evidence behind it")

lines = [f"# Review — {verdict or 'no verdict'}", "",
         out.get("summary", "").strip() or "(no summary)", ""]
if unmet:
    lines += ["## Not met", ""] + [f"- {str(u).strip()}" for u in unmet] + [""]
if evidence:
    lines += ["## Evidence", ""]
    for item in evidence:
        if not isinstance(item, dict):
            continue
        lines.append(f"- {str(item.get('claim', '')).strip()}")
        if item.get("command"):
            lines.append(f"  - `{str(item['command']).strip()}`")
        if item.get("output"):
            body = str(item["output"]).strip().splitlines()[:12]
            lines += ["    ```"] + [f"    {line}" for line in body] + ["    ```"]
    lines.append("")
if denied_commands:
    lines += ["## Commands the reviewer was not allowed to run", ""] \
             + [f"- `{c[:200]}`" for c in denied_commands] + [""]
if out.get("next_step"):
    lines += ["## Next step", "", str(out["next_step"]).strip(), ""]
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
        fh.write(f"\n## review: not usable\n\n" + "\n".join(f"- {w}" for w in why) + "\n")
    else:
        fh.write(f"\n## review: {verdict}\n\n{out.get('summary', '').strip()}\n")

print(verdict or "none", len(denials), "no" if why else "yes")
