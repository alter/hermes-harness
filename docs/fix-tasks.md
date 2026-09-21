# Часть 1. Код харнесса: задачи, которые выполняются на любой машине

Вторая часть — всё, что можно сделать только на сервере с моделью, — в [server-tasks.md](server-tasks.md). Части независимы: эту можно выполнить целиком, не дожидаясь второй. Связей между ними три, все названы в разделе 1.

Источник: [research-and-fix-plan.md](research-and-fix-plan.md), его сверка [research-and-fix-plan-review-v2.md](research-and-fix-plan-review-v2.md) независимая проверка [research-and-fix-plan-verification.md](research-and-fix-plan-verification.md), её ответ [research-and-fix-plan-review-v2-response.md](research-and-fix-plan-review-v2-response.md) и итог [research-and-fix-plan-final.md](research-and-fix-plan-final.md). Здесь то же самое, но в виде работ, которые можно выполнять по одной, не понимая всей картины. Commit, от которого считаются номера строк: `6af3c16`.

Зачем всё это: локальная модель пишет код, Claude Code проверяет. Харнесс существует ради одного свойства — **слова исполнителя не могут сами закрыть задачу**. Каждая задача ниже закрывает путь, которым это свойство сейчас нарушается, либо путь, которым ночной прогон ломается сам.

## 0. Правила для исполнителя

Прочитай этот раздел целиком перед первой задачей. Он действует на все.

1. **Порядок.** Задачи выполняются строго по таблице из раздела 1, сверху вниз. Задачу нельзя начинать, пока не закрыты те, что стоят у неё в DEPENDS.
2. **Одна задача — одно изменение.** Трогай только файлы из её SCOPE. Строки с «−» в SCOPE — запрет. Если для работы нужно выйти за SCOPE, остановись и запиши это в заметки; не расширяй задачу сам.
3. **Сначала красный тест, потом код.** В каждой задаче шаги идут так: добавь проверки в `selftest.sh` → запусти `./selftest.sh` → **убедись, что новые проверки падают**, и сохрани эти строки `FAIL` в заметки → только потом меняй код → добейся `failed 0`. Проверка, которая была зелёной с первого запуска, ничего не доказала: значит, она написана неверно, перепиши её.
4. **Не ослабляй существующие проверки.** Менять можно только те старые проверки, которые задача называет поимённо. Любую другую упавшую старую проверку чини в коде, а не в тесте.
5. **Команда приёмки одна:** `./selftest.sh | tail -1` должна напечатать `passed N, failed 0`. N растёт от задачи к задаче; уменьшаться не может.
6. **Код.** Новые файлы начинаются со строки `# имя_файла`. Новых комментариев в код не добавляй, существующие не удаляй и не переписывай. Сообщения скриптов — на английском, в тоне уже существующих. Имена — английские. Ничего не переименовывай сверх указанного.
7. **Где вставлять проверки.** Новые проверки петель идут в раздел `== loops` файла `selftest.sh`; его создаёт задача T01, он стоит прямо перед строкой `echo "== config"`. Проверки `verdict.py` — в существующий раздел рядом с другими вызовами `verdict_of`. Проверки `tasks.py` — в раздел `== tasks.py`.
8. **Git.** Если тебя запускает `run.sh`, не коммить сам — это делает харнесс. Если работаешь вручную: один коммит на задачу после зелёного `selftest.sh`, файлы добавляй по именам (`git add run.sh selftest.sh`), не `git add -A`. Сообщение — одна строка по-английски о том, что изменилось по смыслу, как в `git log --oneline`. Ни слова о том, кто или что сделало изменение. Никаких `push`, `stash`, `reset --hard`, `clean`.
9. **Если работаешь под харнессом,** сторож путей откажет любой команде терминала, в тексте которой есть `labels.txt`, `task.txt`, `VERIFY.md` или `tasks/`. `./selftest.sh` запускать можно. Файлы читай инструментом чтения, а не `cat`/`grep` с такими словами в команде.
10. **Что писать в заметках по каждой задаче:** какие проверки добавил; их вывод в красном состоянии; что изменил (файл и функция); итоговую строку `passed N, failed 0`; что осталось нерешённым. Не пиши «всё сделано» — пиши, что запускал и что оно напечатало.
11. **Тебе не нужны** видеокарта, `llama-server`, модель, настоящий Hermes и настоящий Claude Code. Всё проверяется подставными программами `hermes` и `claude`, которые создаёт сам `selftest.sh`. Нужны только `bash`, `git`, `python3` с модулем `yaml` и `sha1sum` (на macOS — из coreutils). Если тебе кажется, что задача требует сервера или настоящего вызова модели, ты читаешь её неправильно: остановись и перечитай SCOPE.
12. **Чего не делать никогда:** не обновлять Hermes, llama.cpp и модель; не слать запросы на `:8080`; не менять `approvals`, хуки и список `disabled_toolsets` в `config.yaml`; не удалять `REVIEW.md`, `NOTES.md`, журналы.

Закреплённые версии, к которым относятся все утверждения ниже: Hermes Agent upstream `784d5c3f9c2cb77698d8a9d2e72b1d106a38ea88` (версия в пакете `0.21.3`), llama.cpp `5b59b83f4e2101ea173d4f853a0522d9971f48c6`, модель `Qwen3.8-27B-UD-Q6_K.gguf`, sha256 `c9c206812fbe4ac7b76a729e25928b63f2ae89d37f69da7a71c20aec763cd436`.

## 1. Карта задач

| № | Что закрывает | Файлы | DEPENDS | Кто |
| --- | --- | --- | --- | --- |
| T00 | selftest красный на macOS | `selftest.sh` | — | исполнитель |
| T01 | стенд для петель; Hermes без `--format` | `selftest.sh`, `run.sh`, `README.md` | T00 | исполнитель |
| T02 | ответ ревьюера с нарушенной структурой или противоречием; неизвестный вердикт | `verdict.py`, `review.sh`, `selftest.sh` | T01 | исполнитель |
| T03 | вызовы ревьюера не учтены; сбой вызова блокирует очередь | `verdict.py`, `review.sh`, `status.sh`, `selftest.sh` | T02 | исполнитель |
| T04 | `done` без `verify: passed` | `tasks.py`, `status.sh`, `selftest.sh` | T01 | исполнитель |
| T05 | устаревший замер; замер не переиспользуется | новый `snapshot.py`, `run.sh`, `review.sh`, `install.sh`, `selftest.sh` | T01 | исполнитель |
| T06 | автокоммит чужих файлов | `run.sh`, `selftest.sh` | T05 | исполнитель |
| T07 | `review` раньше коммита | `run.sh`, `selftest.sh` | T06 | исполнитель |
| T08 | ревью читает и проверяет код другой задачи | `review.sh`, `selftest.sh` | T05, T07 | исполнитель |
| T09 | ревью незакоммиченной работы при живой пишущей петле | `review.sh`, `run.sh`, `selftest.sh` | T08 | исполнитель |
| T10 | незаполненная форма уходит ревьюеру | `tasks.py`, `run.sh`, `selftest.sh` | T07 | исполнитель |
| T11 | в разрешениях ревьюера команды, умеющие писать, и весь `python3` | `review.sh`, `verdict.py`, `selftest.sh` | T05, T08 | исполнитель |
| T12 | журнал попытки затирается следующей | `run.sh`, `review.sh`, `selftest.sh` | T07 | исполнитель |
| T13 | размышления вырезаются из истории | `config.yaml`, `selftest.sh` | T01 | исполнитель |
| T14 | глубина размышлений зависит от версии Hermes | `config.yaml`, `selftest.sh` | T01 | исполнитель |
| D1 | неверные места в документах | `README.md`, `docs/operating.md`, `docs/model-serving.md` | T04, T13, T14 | исполнитель |

**Первая партия — T00–T09.** Только после неё можно гонять очередь ревью без присмотра. До T08 ревью задачи A читает и проверяет то, что лежит в рабочей копии сейчас, — а там уже может быть работа задачи B; до T09 то же самое возможно для незакоммиченной работы. T05 и T07 этого не закрывают: они делают честным оттиск и момент передачи, но не место, где идёт проверка.

**Если нужно работать раньше, чем готова вся первая партия** (после T00–T07): только по одной задаче. `HH_MAX_TASKS=1` для `run.sh`, затем `HH_REVIEW_ONLY=<эта задача>` для `review.sh`, и следующая задача не запускается, пока не вынесен вердикт по предыдущей. Никакие другие процессы рабочую копию в это время не меняют.

Вторая партия — T10–T12. Третья — T13, T14, D1.

**Связи со второй частью** ([server-tasks.md](server-tasks.md)):

1. T13 и T14 меняют только файл `config.yaml` в репозитории. Это можно и нужно написать сейчас: до выкатки на сервер эти строки ни на что не действуют. Попадут ли они на сервер, решает задача R4 второй части по фактам из R1 — не ты.
2. Две строки таблицы D1 (про MTP-голову и про `--cache-reuse`) зависят от фактов с сервера. Они помечены; остальные строки D1 пишутся сейчас.
3. Вторая часть начинает выкатку (R4) только после того, как здесь закрыты T00–T09 и изменения лежат в `origin/main`.

---

## T00. `selftest.sh` одинаково работает на macOS и Linux

**ROLE:** исполнитель. **DEPENDS:** —.

**GOAL.** Получить зелёную исходную точку. Сейчас на macOS: `passed 160, failed 1`.

**CONTEXT.** `selftest.sh:319` вызывает `sed -i '…' файл`. У BSD `sed` первый аргумент после `-i` — суффикс резервной копии, поэтому команда ломается, форма остаётся незаполненной, и проверка `a filled form is accepted` падает. Форма `sed -i.bak '…' файл` работает в обоих `sed`.

**SCOPE.**
+ `selftest.sh`, одна строка 319.
− любые другие строки и файлы.

**ШАГИ.**
1. Запусти `./selftest.sh | tail -1` и запиши результат и ОС (`uname -s`) в заметки. На Linux красного не будет — это нормально, так и запиши.
2. В строке 319 замени `sed -i '` на `sed -i.bak '`. Больше ничего.
3. Запусти снова.

**OUTCOME.** `selftest.sh` печатает `passed 161, failed 0` на macOS и на Linux.

**VERIFY.**
1. `./selftest.sh` заканчивается строкой `passed 161, failed 0`.
2. `git diff --stat` показывает один файл и одну изменённую строку.

---

## T01. Стенд для проверки петель и отказ при Hermes без `--format stream-json`

**ROLE:** исполнитель. **DEPENDS:** T00.

**GOAL.** (а) Дать `selftest.sh` способ по-настоящему запускать `run.sh` и `review.sh` с подставными `hermes` и `claude` — сейчас он эти скрипты не запускает ни разу, только ищет в их тексте подстроки. (б) Сделать так, чтобы `run.sh` сразу и понятно отказывал, если установленный Hermes не умеет `chat --format stream-json`.

**CONTEXT.** `run.sh:211–215` вызывает `hermes chat -Q --format stream-json …` и берёт `session_id` из строки `"type": "result"`. В теге релиза `v2026.9.14` этого флага нет, он появился в `main` позже; версия пакета в обоих случаях `0.21.3`. На Hermes без флага каждая попытка кончается `exit 2`, и задача после трёх попыток уходит в `blocked` без объяснения.

**SCOPE.**
+ `selftest.sh`: новый раздел `== loops` перед строкой `echo "== config"`.
+ `run.sh`: одна проверка сразу после строки 22 (`command -v hermes …`).
+ `README.md`: строка 10.
− `review.sh`, `tasks.py`, `verdict.py`.

**ШАГИ.**
1. Вставь в `selftest.sh` перед `echo "== config"` этот блок дословно. Он проверен на текущем коде: проводит задачу от `todo` до `done`.

```bash
echo "== loops"
LP="$TMP/loops"; mkdir -p "$LP/bin"
cat > "$LP/bin/hermes" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --help "*) printf '%s\n' "${STUB_HERMES_HELP:-  --format {text,stream-json}}"; exit 0 ;; esac
cat > /dev/null
[ -n "${STUB_HERMES_DO:-}" ] && eval "$STUB_HERMES_DO"
printf '{"type":"result","session_id":"stub-session","exit_code":0}\n'
exit "${STUB_HERMES_RC:-0}"
EOF
cat > "$LP/bin/claude" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --help "*) echo "--effort --fallback-model"; exit 0 ;; esac
[ -n "${STUB_CLAUDE_ARGS:-}" ] && printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
cat > "${STUB_CLAUDE_PROMPT:-/dev/null}"
[ -n "${STUB_CLAUDE_DO:-}" ] && eval "$STUB_CLAUDE_DO"
printf '%s\n' "${STUB_CLAUDE_REPLY:-{\}}"
exit "${STUB_CLAUDE_RC:-0}"
EOF
chmod +x "$LP/bin/hermes" "$LP/bin/claude"
new_project() {
  rm -rf "$1"; mkdir -p "$1/tasks/10-a/01-x"
  ( cd "$1" && git init -q . && git config user.email t@t && git config user.name t \
    && printf 'tasks/\n.hermes-harness/\n.hermes-notes/\n' > .gitignore && echo 1 > code.txt \
    && git add .gitignore code.txt && git commit -qm init )
  mk "$1/tasks/10-a/01-x" "x" "code.txt" "true" "AGENT"
  printf 'priority: P1\nstatus: todo\nverify: pending\nrole: AGENT\n' > "$1/tasks/10-a/01-x/labels.txt"
}
loop_run()    { ( cd "$1" && PATH="$LP/bin:$PATH" HH_HOME="$H" HH_MAX_TASKS=1 bash "$SRC/run.sh" "$1" 2>&1 ); }
loop_review() { ( cd "$1" && PATH="$LP/bin:$PATH" HH_HOME="$H" HH_REVIEW_MAX="${HH_REVIEW_MAX:-1}" bash "$SRC/review.sh" "$1" 2>&1 ); }
label() { grep "^$2:" "$1/tasks/10-a/01-x/labels.txt" | cut -d' ' -f2; }
FILL='echo 2 > code.txt; sed -e "s/(not checked)/ok/g" -e "s/(write here)/done/g" "$HH_NOTES_FILE" > "$HH_NOTES_FILE.new" && mv "$HH_NOTES_FILE.new" "$HH_NOTES_FILE"'
PASS='{"is_error":false,"total_cost_usd":0,"structured_output":{"verdict":"passed","summary":"ok","evidence":[{"claim":"read code.txt, it holds 2"}],"unmet":[]}}'

P="$LP/p-happy"; new_project "$P"
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
check "the writing loop hands a finished task to review" "$(label "$P" status)" '^review$'
STUB_CLAUDE_REPLY="$PASS" loop_review "$P" >/dev/null
check "the reviewer closes a passed task"                "$(label "$P" status) $(label "$P" verify)" '^done passed$'

P="$LP/p-oldhermes"; new_project "$P"
out=$(STUB_HERMES_HELP='  -Q, --quiet' loop_run "$P"); lrc=$?
check "a hermes without stream-json is refused by name"  "$out" 'stream-json'
check "the refusal is an error exit"                     "$lrc" '^1$'
check "and the task was not touched"                     "$(label "$P" status)" '^todo$'
```

2. Запусти `./selftest.sh`. Первые две проверки должны быть зелёными (это доказывает, что стенд работает), три последние — красными. Сохрани красные строки в заметки.
3. В `run.sh` сразу после строки `command -v hermes >/dev/null 2>&1 || …` добавь:

```bash
hermes ${PROFILE:+-p "$PROFILE"} chat --help 2>/dev/null | grep -q -- 'stream-json' \
  || { echo "this hermes has no 'chat --format stream-json'; the harness needs a build that has it (see README)" >&2; exit 1; }
```

4. В `README.md` строку 10 замени на: `Built against hermes-agent upstream commit \`784d5c3f\` (2026-09-16; the package reports \`0.21.3\`), read from the source rather than the README. The release tag \`v2026.9.14\` reports the same version and is not enough: it has no \`chat --format stream-json\`, which \`run.sh\` depends on and checks for at start.`
5. `./selftest.sh` → `failed 0`.

**OUTCOME.** В `selftest.sh` есть работающий стенд для петель; `run.sh` отказывает при Hermes без нужного флага, не трогая задачу; README называет правильную версию.

**VERIFY.**
1. `./selftest.sh` заканчивается строкой с `failed 0`, всего проверок стало 166.
2. В заметках есть три строки `FAIL` из шага 2.
3. Проверка `the writing loop hands a finished task to review` была зелёной уже на шаге 2.

---

## T02. Ответ ревьюера проверяется на собственной границе: структура, типы, согласованность

**ROLE:** исполнитель. **DEPENDS:** T01.

**GOAL.** `verdict.py` должен **отвергать** ответ, который не соответствует согласованной структуре или противоречит сам себе, — а не чинить его молча и не падать. `review.sh` не должен ни зацикливаться на одной задаче, ни умирать, если разбор ответа всё же завершился ошибкой.

**CONTEXT.** Схему ответа обеспечивает чужая программа (`claude --json-schema`). Своей проверки у харнесса нет, и на текущем коде воспроизводится:

| Ответ ревьюера | Что происходит сейчас |
| --- | --- |
| `passed`, `unmet: ["criterion not met"]`, `evidence: [{"claim": ""}]` | `passed 0 yes` → `done` |
| `passed`, `"evidence": "I read everything"` (строка вместо списка) | `passed 0 yes` → `done`, раздел Evidence пуст |
| `passed`, `evidence: [{"claim": 42}]` | `passed 0 yes` → `done` |
| `verdict: "banana"` | `banana 0 yes`; у `case` в `review.sh:341–369` нет ветки по умолчанию, счётчик раундов стёрт строкой 340, задача снова первая в очереди — без предела |
| `"summary": 42` | `AttributeError` в `verdict.py:37`; `review.sh` под `set -e` завершается с кодом 1, вызов не записан в `ledger.tsv` |
| `permission_denials: [{"tool_input": 42}]` | `AttributeError` в `verdict.py:27`, то же |

Главное правило задачи: **нарушение структуры — это причина негодности, а не повод привести значение к нужному типу и продолжить.** Если из `unmet: [42]` молча сделать `unmet: []`, противоречивый `passed` превратится в чистый. Приводить значение к безопасному виду можно только для того, чтобы напечатать его в `REVIEW.unusable.md`; решение о пригодности обязано помнить о нарушении.

**SCOPE.**
+ `verdict.py`: всё от строки 8 (разбор конверта) до строки 35 (конец списка `why`) и места, где значения печатаются в файл.
+ `review.sh`: вызов `verdict.py` (строка 307) и `case "$verdict"` (строки 341–369).
+ `selftest.sh`: новые проверки.
− формат вывода `verdict.py` (три слова через пробел) не менять.
− JSON-схему `SCHEMA` в `review.sh` не менять.
− ничего не «исправлять» в ответе: только принять или отвергнуть.

**Правила структуры.** Проверяются **до** первого обращения к полям (сейчас обращения начинаются на строке 12). Каждое нарушение — строка в `why`.

| Что проверяется | Требование | Текст причины |
| --- | --- | --- |
| конверт | JSON-объект | `the envelope is not a JSON object` |
| `structured_output` | объект, если присутствует | `not in the agreed shape: structured_output` |
| `verdict`, `summary`, `evidence`, `unmet` | присутствуют, если `structured_output` — непустой объект | `not in the agreed shape: <поле> is missing` |
| `verdict`, `summary`, `next_step` | строки | `not in the agreed shape: <поле>` |
| `evidence` | список | `not in the agreed shape: evidence` |
| каждый элемент `evidence` | объект | `not in the agreed shape: evidence[<номер с 1>]` |
| `claim` в элементе | строка, непустая после `strip()` | `evidence item <номер> has no claim` |
| `command`, `output` в элементе | строки, если присутствуют | `not in the agreed shape: evidence[<номер>].<поле>` |
| `unmet` | список | `not in the agreed shape: unmet` |
| каждый элемент `unmet` | строка | `not in the agreed shape: unmet[<номер>]` |
| `permission_denials` | список объектов, если присутствует; `tool_input` в элементе — объект, если присутствует | `permission_denials is not in the shape the CLI documents` |

Для печати в файл используй только значения, прошедшие проверку; вместо не прошедших — пустая строка, пустой список, а для отказанной команды — `?`. Вызывать `.strip()` и `.get()` на непроверенном значении нельзя.

**Правила согласованности** (после структуры):

| Правило | Текст причины |
| --- | --- |
| `verdict` непустой и не из `passed`, `failed`, `blocked` | `the verdict '<значение>' is not one the harness knows` |
| `passed` и в `unmet` есть непустая строка | `a passing verdict that lists unmet criteria` |
| `failed`, и пусты одновременно `unmet` и `next_step` | `a failing verdict that does not say what is missing` |

Существующие правила («нет вердикта», «`passed` без `evidence`», «проверке проекта отказано») остаются.

**ШАГИ.**
1. Добавь в `selftest.sh` рядом с другими вызовами `verdict_of` двенадцать проверок. Конверт для каждой пиши в `$env_file` так же, как соседние проверки; основа — конверт проверки `a supported pass is usable`, меняется одно поле. Ожидание у всех, кроме девятой, — `^<вердикт> <число> no$`, и в выводе нет слова `Traceback`:
   1. `"summary": 42` → `^passed 0 no$`
   2. `"evidence": "I read everything"` → `^passed 0 no$`
   3. `"evidence": [{"claim": 42}]` → `^passed 0 no$`
   4. `"evidence": [{"claim": "ran it", "command": 42}]` → `^passed 0 no$`
   5. `"unmet": [42]` → `^passed 0 no$`
   6. поле `unmet` отсутствует → `^passed 0 no$`
   7. `"permission_denials": [{"tool_name": "Bash", "tool_input": 42}]` → `^passed [01] no$` (второе слово — число отказов; считать ли повреждённую запись, решает реализация)
   8. `"structured_output": "passed"` (строка вместо объекта) → `^none 0 no$`
   9. в `$env_file` записано `[1,2,3]` → `^none 0 (no|infra)$` (после T03 третье слово станет `infra`, шаблон допускает оба)
   10. `passed`, `"unmet": ["criterion not met"]`, `"evidence": [{"claim": "read source"}]` → `^passed 0 no$`
   11. `"verdict": "banana"`, остальное корректно → `^banana 0 no$`
   12. `failed`, `"unmet": []`, `"evidence": []`, без `next_step` → `^failed 0 no$`
2. Добавь в раздел `== loops`:

```bash
P="$LP/p-banana"; new_project "$P"
printf 'priority: P1\nstatus: review\nverify: pending\nrole: AGENT\n' > "$P/tasks/10-a/01-x/labels.txt"
BANANA='{"is_error":false,"total_cost_usd":0,"structured_output":{"verdict":"banana","summary":"s","evidence":[{"claim":"x"}],"unmet":[]}}'
out=$(STUB_CLAUDE_REPLY="$BANANA" HH_REVIEW_MAX=5 loop_review "$P")
check "an unknown verdict is reviewed twice, not forever" "$out" 'reviewed: 2,'
check "and then a human is called"                         "$(label "$P" status)" '^blocked$'

P="$LP/p-string-evidence"; new_project "$P"
printf 'priority: P1\nstatus: review\nverify: pending\nrole: AGENT\n' > "$P/tasks/10-a/01-x/labels.txt"
STRINGY='{"is_error":false,"total_cost_usd":0,"structured_output":{"verdict":"passed","summary":"s","evidence":"I read everything","unmet":[]}}'
STUB_CLAUDE_REPLY="$STRINGY" loop_review "$P" >/dev/null
check "a pass whose evidence is not a list closes nothing" "$(label "$P" status) $(label "$P" verify)" '^review pending$'
```

3. Запусти `./selftest.sh`, сохрани красные строки (должно быть пятнадцать: двенадцать из шага 1 и три из шага 2).
4. Измени `verdict.py`: сначала правила структуры, затем правила согласованности.
5. `review.sh`, строка 307: разбор не должен ронять петлю. Замени на

```bash
  outcome=$(python3 "$HARNESS/verdict.py" "$LOGS/$name.review.json" "$task" "$rc" "$TEST_CMD") || {
    echo "   the verdict could not be parsed (verdict.py failed); counted as an unusable review" >&2
    outcome="none 0 no"
  }
```

6. В `case "$verdict" in` после ветки `blocked)` добавь:

```bash
    *)
      tasks set "$task" status blocked --as reviewer
      ledger "$name" reviewer review blocked "verdict '$verdict' is not one the harness knows" "$cost"
      echo "   -> blocked: '$verdict' is not a verdict"
      judged=$((judged + 1)) ;;
```

7. `./selftest.sh` → `failed 0`.

Шаги 5 и 6 — страховка: после шага 4 исправный `verdict.py` не упадёт на этих входах и не пропустит неизвестный вердикт как годный, поэтому из теста эти ветки недостижимы. Отдельных проверок у них нет — так и запиши в заметках, не выдумывай тест.

**OUTCOME.** Любое JSON-значение и повреждённый JSON на входе `verdict.py` дают три слова на выходе, а не исключение; ответ с нарушенной структурой или противоречием — негодное ревью с названной причиной; ни одно нарушение не исчезает при разборе; задача с таким ответом после двух раундов уходит в `blocked`, а не в `done` и не в бесконечный цикл.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. Существующая проверка `a supported pass is usable` по-прежнему зелёная и не изменена.
3. В заметках пятнадцать строк `FAIL` из шага 3.
4. `d=$(mktemp -d); echo 'not json at all' > "$d/e.json"; python3 verdict.py "$d/e.json" "$d" 0 ''` печатает три слова и не печатает `Traceback`.

**Чего эта задача не обещает.** Ошибки чтения и записи файлов, нехватку места, сбой самого Python `verdict.py` не перехватывает — на этот случай и нужен шаг 5. Учёт вызова, который не должен теряться ни при каком исходе разбора, делает T03.

---

## T03. Каждый вызов ревьюера учтён; сбой вызова — не ревью и не приговор задаче

**ROLE:** исполнитель. **DEPENDS:** T02.

**GOAL.** Три вещи. (а) Каждое обращение к `claude` оставляет ровно одну запись с тем, что о нём известно, — до разбора вердикта и независимо от него. (б) Когда `claude` не смог отработать (исчерпан лимит подписки, нет сети, авария CLI), это не засчитывается как раунд ревью и никого не блокирует. (в) Задача, на которой вызов падает раз за разом, не держит очередь вечно — и при этом **не объявляется виновной**.

**CONTEXT.** Ревьюер работает по подписке: упор в лимит — штатное событие. Сейчас `verdict.py:19` считает любой ненулевой выход и любой `is_error` негодным ревью; `review.sh:319–337` после двух негодных подряд ставит `blocked` и берёт следующую задачу. Воспроизведено: три задачи в `review` уходят в `blocked` за две секунды, в `ledger.tsv` написано `2 unusable reviews`.

Почему нельзя решать «кто виноват». По ответу CLI общий сбой (лимит, сеть) не отличить от сбоя, вызванного одной задачей. Кажется, что отличить можно так: «на задаче A вызов упал, на задаче B тут же прошёл — значит, дело в A». **Это неверно, и так делать нельзя:** между двумя вызовами меняется не только задача, но и время — лимит мог сброситься, сеть вернуться. Проверено: три общих сбоя подряд, затем восстановление — такое правило блокирует исправную A. Поэтому харнесс не делает выводов о причине. Он записывает наблюдение, откладывает задачу и идёт дальше; блокировать по сбоям вызова может только человек.

Почему нельзя считать вызовы по `ledger.tsv`. Строка журнала — это переход статуса, а не вызов: бывают переходы без вызова и (после аварии разбора) вызовы без перехода. Нужен отдельный журнал вызовов.

Исключение из «сбой вызова — не ревью»: три документированных исхода, когда `claude` сам остановился по собственному потолку, — поле `subtype` конверта равно `error_max_turns`, `error_max_budget_usd` или `error_max_structured_output_retries`. Попытка состоялась и кончилась ничем; она засчитывается как негодное ревью, как и раньше. Причина в файле — наблюдение («the review stopped at its own limit: …»), а не вывод о задаче. Любой другой `subtype` при ненулевом выходе — сбой вызова; сравнивай с этими тремя строками точно, не по префиксу.

**SCOPE.**
+ `verdict.py`: ранний выход до записи любых файлов.
+ `review.sh`: журнал вызовов, обработка третьего слова `infra`, выбор задачи из очереди.
+ `status.sh`: разделы `== reviews` и новый `== reviewer failures`.
+ `selftest.sh`.
− при сбое вызова не менять `status`, `verify`, счётчик раундов и не писать ничего в каталог задачи.
− никакой логики вида «другая задача прошла → эта виновата».

**ШАГИ.**
1. В `selftest.sh` найди проверку `a run that produced nothing is refused` (конверт `{"is_error": false, "permission_denials": [], "result": "credit balance too low"}`, код выхода 1). Это и есть сбой вызова. Измени её ожидание с `^none 0 no$` на `^none 0 infra$`.
2. Следующую за ней проверку `the reason names the exit code` замени: запиши конверт `{"is_error": true, "subtype": "error_max_turns", "permission_denials": [], "result": "hit the turn limit"}`, вызови `verdict_of 1 ''`, ожидай `^none 0 no$`; второй проверкой — что `$vd/REVIEW.unusable.md` содержит `its own limit`.
3. Добавь две проверки: конверт с `"subtype": "error_max_something_new"` и кодом 1 → `^none 0 infra$` (неизвестный потолок — не основание считать раунд); после вызова из шага 1 файла `$vd/REVIEW.unusable.md` нет (удали его перед вызовом, проверь `empty` после).
4. Добавь в `== loops`:

```bash
review_runs() { for _ in $(seq "$1"); do loop_review "$P" >/dev/null; done; }
calls() { wc -l < "$P/.hermes-harness/calls.tsv" 2>/dev/null | tr -d ' '; }
two_in_review() {
  new_project "$P"; mkdir -p "$P/tasks/10-a/02-y"; mk "$P/tasks/10-a/02-y" "y" "code.txt" "true" "AGENT"
  for t in 01-x 02-y; do printf 'priority: P1\nstatus: review\nverify: pending\nrole: AGENT\n' > "$P/tasks/10-a/$t/labels.txt"; done
}
status_y() { grep '^status:' "$P/tasks/10-a/02-y/labels.txt" | cut -d' ' -f2; }
DOWN='{"is_error":true,"total_cost_usd":0.1,"result":"usage limit reached"}'

P="$LP/p-infra"; two_in_review
out=$(STUB_CLAUDE_RC=1 STUB_CLAUDE_REPLY="$DOWN" HH_REVIEW_MAX=0 loop_review "$P"); lrc=$?
check "an unavailable reviewer stops the loop with exit 75" "$lrc" '^75$'
check "it blocks nothing"          "$(label "$P" status) $(status_y)" '^review review$'
check "it counts no review round"  "$(ls "$P/.hermes-harness/review-rounds" 2>/dev/null | wc -l | tr -d ' ')" '^0$'
check "the call is on record with what the CLI said it cost" "$(cat "$P/.hermes-harness/calls.tsv")" '0\.1'
STUB_CLAUDE_RC=1 STUB_CLAUDE_REPLY="$DOWN" HH_REVIEW_INFRA_MAX=2 HH_REVIEW_MAX=0 review_runs 3
check "an outage that lasts blocks nothing either" "$(label "$P" status) $(status_y)" '^review review$'
check "one failing call per run, each on record"   "$(calls)" '^4$'

P="$LP/p-recover"; two_in_review; rm -f "$LP/n.txt"
RECOVER="n=\$(( \$(cat $LP/n.txt 2>/dev/null || echo 0) + 1 )); echo \$n > $LP/n.txt; [ \$n -le 3 ] && { echo '{\"is_error\":true,\"result\":\"temporary outage\"}'; exit 1; }"
STUB_CLAUDE_DO="$RECOVER" STUB_CLAUDE_REPLY="$PASS" HH_REVIEW_INFRA_MAX=3 HH_REVIEW_MAX=0 review_runs 4
check "after an outage ends the task that met it is not blamed" "$(label "$P" status)" '^review$'
check "and the queue moved on meanwhile"                        "$(status_y)" '^done$'
STUB_CLAUDE_DO="$RECOVER" STUB_CLAUDE_REPLY="$PASS" HH_REVIEW_INFRA_DEFER=0 HH_REVIEW_MAX=0 review_runs 1
check "once it is tried again it passes like any other"        "$(label "$P" status) $(label "$P" verify)" '^done passed$'
check "five calls were made and five are on record"            "$(calls)" '^5$'
st=$(cd "$P" && HH_HOME="$H" bash "$SRC/status.sh" "$P" 2>&1 || true)
check "status.sh counts calls, not ledger lines"               "$st" 'reviewer calls: +5'

P="$LP/p-poison"; two_in_review
POISON='grep -q "TASK: x" "$STUB_CLAUDE_PROMPT" && { echo "{\"is_error\":true,\"result\":\"boom\"}"; exit 1; }'
STUB_CLAUDE_PROMPT="$LP/poison-prompt.txt" STUB_CLAUDE_DO="$POISON" STUB_CLAUDE_REPLY="$PASS" HH_REVIEW_INFRA_MAX=2 HH_REVIEW_MAX=0 review_runs 3
check "a task the reviewer keeps failing on does not hold the queue" "$(status_y)" '^done$'
check "and is put off, not blocked"                                   "$(label "$P" status)" '^review$'
st=$(cd "$P" && HH_HOME="$H" bash "$SRC/status.sh" "$P" 2>&1 || true)
check "status.sh shows it to a human"                                 "$st" '10-a-01-x +2 in a row'
```

   Как читать сценарии. `p-recover`: подставной `claude` падает на первых трёх вызовах **независимо от задачи**, потом работает. Запуски 1–3: `01-x` получает три сбоя и откладывается. Запуск 4: `01-x` отложена, `02-y` проходит. `01-x` при этом остаётся в `review` — её никто не обвиняет. Пятый запуск с `HH_REVIEW_INFRA_DEFER=0` пробует её снова, и она проходит. `p-poison`: `claude` падает, только когда в prompt есть `TASK: x`; очередь всё равно доходит до `02-y`, а `01-x` остаётся в `review` и видна в `status.sh`.
5. Запусти, сохрани красные строки.
6. `verdict.py`. Сразу после проверки, что конверт — объект (из T02), до любой записи файлов:

```python
OWN_LIMITS = {"error_max_turns", "error_max_budget_usd", "error_max_structured_output_retries"}
subtype = envelope.get("subtype") if isinstance(envelope.get("subtype"), str) else ""
call_failed = rc != "0" or not envelope or bool(envelope.get("is_error"))
if call_failed and subtype not in OWN_LIMITS:
    print("none", 0, "infra")
    sys.exit(0)
```

   Для случая `subtype in OWN_LIMITS` добавь в `why` строку `the review stopped at its own limit: <subtype>`.
7. `review.sh`, настройки в начале: `INFRA_MAX=${HH_REVIEW_INFRA_MAX:-3}` и `INFRA_DEFER=${HH_REVIEW_INFRA_DEFER:-3600}`; в `mkdir -p` добавь `"$STATE/review-infra"`. После функции `ledger` добавь три функции:

```bash
log_call() {
  python3 - "$LOGS/$1.review.json" "$1" "$2" >> "$STATE/calls.tsv" <<'PY'
import datetime, json, sys
path, name, rc = sys.argv[1:4]
try:
    env = json.load(open(path, encoding="utf-8"))
except Exception:
    env = None
env = env if isinstance(env, dict) else {}
usage = env.get("usage") if isinstance(env.get("usage"), dict) else {}
num = lambda v: str(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else "?"
print("\t".join([datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), name, rc,
                 num(env.get("total_cost_usd")), num(env.get("num_turns")),
                 num(usage.get("input_tokens")), num(usage.get("output_tokens")),
                 env.get("subtype") if isinstance(env.get("subtype"), str) else "?"]))
PY
}

is_deferred() {
  local count=0 at=0
  [ -f "$STATE/review-infra/$1" ] || return 1
  read -r count at < "$STATE/review-infra/$1" || true
  [ "${count:-0}" -ge "$INFRA_MAX" ] && [ $(( $(date +%s) - ${at:-0} )) -lt "$INFRA_DEFER" ]
}

next_in_queue() {
  local t
  while IFS= read -r t; do
    is_deferred "$(slug "$t")" || { printf '%s\n' "$t"; return 0; }
  done < <(tasks queue review || true)
  return 1
}
```

   Колонки `calls.tsv`: время, задача, код выхода, расчётная стоимость, ходы, входные токены, выходные токены, `subtype`. Неизвестное значение — `?`, **не ноль**.
8. `review.sh`, выбор задачи. Строку с `tasks queue review | head -n 1` замени на:

```bash
    task=$(next_in_queue) || {
      if tasks queue review >/dev/null; then
        echo "== everything waiting in review is put off after repeated reviewer failures; see status.sh"
        exit 75
      fi
      echo "== nothing waiting in review"; break
    }
```

   Режим `HH_REVIEW_ONLY` отсрочку не учитывает: человек назвал задачу сам.
9. `review.sh`, сразу после вызова `claude` и строки `rc=$?` (до проверки на прерывание и до `verdict.py`): `log_call "$name" "$rc"`. Блок вычисления `cost=` перенеси выше — сразу после `log_call`, чтобы стоимость была известна во всех ветках.
10. `review.sh`, сразу после строки `read -r verdict denied usable <<<"$outcome"`:

```bash
  if [ "$usable" = "infra" ]; then
    infra=$(( $(cut -d' ' -f1 "$STATE/review-infra/$name" 2>/dev/null || echo 0) + 1 ))
    printf '%s %s\n' "$infra" "$(date +%s)" > "$STATE/review-infra/$name"
    echo "   the reviewer call failed (claude exited $rc); nothing is counted and nothing is blocked"
    [ -s "$LOGS/$name.review.err" ] && tail -n 5 "$LOGS/$name.review.err" | sed 's/^/     /'
    ledger "$name" reviewer review review "reviewer call failed (exit $rc), $infra in a row for this task" "$cost"
    [ "$infra" -ge "$INFRA_MAX" ] && echo "   $infra in a row: $name is put off for ${INFRA_DEFER}s so the queue can move; it stays in review"
    exit 75
  fi
  rm -f "$STATE/review-infra/$name"
```

11. `status.sh`, раздел `== reviews`. Читай `calls.tsv` (если файла нет — нули). Напечатай: `reviewer calls: <число строк>`; `calls that returned no answer: <строк с кодом выхода не 0>`; `tokens in/out where the CLI reported them: <сумма>/<сумма>, unknown for <число строк с ?> call(s)`. Строку `spent on reviews: … USD` замени на `computed cost of reviews: … USD (a figure the CLI reports; on a subscription it is not a charge), unknown for <N> call(s)` — сумму бери из `calls.tsv`, а не из `ledger.tsv`. Счётчик `verdicts` по `ledger.tsv` оставь, но исключи из него строки, где причина начинается с `reviewer call failed`.
12. `status.sh`, новый раздел `== reviewer failures` после `== reviews`: для каждого файла в `.hermes-harness/review-infra/` строка `   <имя файла> <число> in a row, last <время в UTC>`. Если файлов нет — раздел не печатать.
13. `./selftest.sh` → `failed 0`.

**OUTCOME.** У каждого вызова `claude` есть строка в `.hermes-harness/calls.tsv`, записанная до разбора вердикта. Сбой вызова останавливает `review.sh` с кодом 75, не меняет ни один статус и не засчитывает раунд. Задача с `HH_REVIEW_INFRA_MAX` сбоями подряд откладывается на `HH_REVIEW_INFRA_DEFER` секунд и не мешает очереди; по сбоям вызова харнесс никого не блокирует и ни о чьей вине не пишет. `status.sh` считает вызовы по журналу вызовов и показывает отложенные задачи.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. `grep -n 'works on others\|fails on this task' review.sh` ничего не находит.
3. В сценарии `p-recover` задача `01-x` ни в какой момент не получает `blocked`.
4. Старые проверки, изменённые в шагах 1–2, названы в заметках поимённо; других старых проверок не тронуто.

**Что остаётся человеку.** Отложенная задача видна в `status.sh` с числом сбоев и временем последнего. Решение «это задача такая» принимает человек, посмотрев `logs/<задача>.review.err` и `calls.tsv`; поставить `blocked` он может сам. Настоящий ответ CLI при исчерпании подписки ещё не получен (R3 в `server-tasks.md`); когда появится, шаг 6 надо сверить с ним.

---

## T04. `done` считается закрытием только вместе с `verify: passed`

**ROLE:** исполнитель. **DEPENDS:** T01.

**GOAL.** Зависимая задача не должна стартовать, пока предшественник не принят ревьюером. Роль `agent` не должна уметь записать `status: done`.

**CONTEXT.** `tasks.py:57–65` (`depends_met`) смотрит только на `status == "done"`. `tasks.py:10` разрешает роли `agent` писать `status` с любым значением. Воспроизведено: задача `a` со `status: done`, `verify: pending` открывает зависимую `b`; `tasks.py set <b> status done` без `--as` выходит с кодом 0. Такая задача исчезает из обеих очередей, её никто не проверит. `run.sh` пишет от роли `agent` только `in_progress`, `review`, `blocked`; `done` ставит только `review.sh` с `--as reviewer`.

**SCOPE.**
+ `tasks.py`: `write_label`, `depends_met`.
+ `status.sh`: новый раздел.
+ `selftest.sh`: раздел `== tasks.py`.
− `run.sh`, `review.sh` не трогать: им изменение не мешает.

**ШАГИ.**
1. В `selftest.sh`, раздел `== tasks.py`, измени поимённо эти места:
   - строку `tp set "$T/10-a/01-first" status done >/dev/null` замени на `tp set "$T/10-a/01-first" status done --as reviewer >/dev/null`;
   - сразу после проверки `status can be written` добавь две новые: `check "done without a passed verify releases nothing" "$(tp list)" 'is done but verify is pending'` и `check "the agent may not write status: done" "$(tp set "$T/10-a/02-second" status done)" "reviewer's to write"`;
   - затем строку `tp set "$T/10-a/01-first" verify passed --as reviewer >/dev/null`, и уже после неё остаётся существующая проверка `a met dependency releases the next task`;
   - проверки `verify: is refused` и `verify: is still pending` перенеси **выше**, перед добавленной строкой с `verify passed`, иначе вторая станет ложной;
   - строку `tp set "$T/10-a/02-second" status done >/dev/null` дополни `--as reviewer`;
   - строку `tp set "$T/20-b/01-human" status done >/dev/null` замени двумя: `status done --as reviewer` и `verify passed --as reviewer`.
2. Добавь проверку `status.sh`: в дереве `$T` создай задачу со `status: done`, `verify: pending`, запусти `status.sh` так же, как это делает существующая проверка `status.sh reads a tree with no ledger yet`, и проверь, что вывод содержит `done without verify: passed`.
3. Запусти, сохрани красные строки.
4. `tasks.py`:
   - рядом с `WRITABLE_LABELS` добавь `AGENT_STATUSES = {"todo", "in_progress", "review", "blocked"}`;
   - в `write_label` после проверки `key not in allowed`: если `role == "agent"`, `key == "status"` и `value not in AGENT_STATUSES` — `raise ValueError(f"status: {value} is the reviewer's to write, not the agent's")`;
   - в `depends_met`: прочитай метки зависимости один раз; если `status != "done"` — прежнее сообщение; иначе если `verify != "passed"` — верни `False, f"depends {dep} is done but verify is {verify or 'unset'}, not passed"`.
5. `status.sh`: после раздела `== tree` напечатай раздел `== labels that disagree` со списком задач, у которых `status: done` и `verify` не `passed`, по строке `   done without verify: passed   <путь>`. Если таких нет — раздел не печатать.
6. `./selftest.sh` → `failed 0`.

**OUTCOME.** Зависимость считается выполненной только при `status: done` и `verify: passed`; роль `agent` получает отказ на `status: done`; `status.sh` показывает несогласованные метки.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. `python3 tasks.py --root <дерево> set <задача> status done` печатает отказ и выходит с кодом 2.
3. В заметках перечислены изменённые старые проверки.

**Последствие, о котором надо написать в заметках:** в существующих деревьях задачи, закрытые человеком вручную без `verify: passed`, перестанут открывать зависимые. Человек исправляет это командой `tasks.py --root <дерево> set <задача> verify passed --as reviewer`. Исполнитель чужие деревья не правит.

---

## T05. Замер привязан к содержимому дерева и к команде

**ROLE:** исполнитель. **DEPENDS:** T01.

**GOAL.** Результат `HH_TEST_COMMAND` можно переиспользовать тогда и только тогда, когда он получен на том же содержимом файлов той же командой. Сейчас оба направления сломаны.

**CONTEXT.**
- `work_fingerprint` (`run.sh:84`, `review.sh:71`) хеширует `git diff HEAD` и неотслеживаемые файлы. У любого чистого дерева оттиск один — sha1 пустой строки `da39a3ee…`. Воспроизведено: после смены чистого коммита и команды ревьюер получил старый вывод с текстом «has already been run against exactly this working tree», задача ушла в `done`.
- При `HH_PREGATE=0` файл `.check.out` уходит в prompt вообще без проверки (`review.sh:288–289`).
- При `HH_COMMIT=1` (по умолчанию) `measure` (`run.sh:294`) снимает оттиск до коммита, ревью считает его после — они никогда не совпадают, и проверка проекта гонится второй раз.
- Команда, которой получен вывод, нигде не сверяется.

Решение: идентификатор содержимого — git-дерево рабочей копии, посчитанное через **временный** индекс. Он одинаков до и после коммита того же содержимого, меняется при любой правке, смене режима файла или цели ссылки, и не трогает индекс пользователя. Проверено на обычном репозитории и на sparse-worktree.

**SCOPE.**
+ новый файл `snapshot.py`.
+ `install.sh`: одна строка `put`.
+ `run.sh`: функции `work_fingerprint`, `measure`; `review.sh`: `work_fingerprint`, блок строк 212–244 и 288–289.
+ `selftest.sh`.
− `pregate.py`, `baseline_check` не трогать.
− переменные `before`/`after` в `run.sh` (сравнение «дерево изменилось или нет») должны продолжать работать.

**ШАГИ.**
1. Создай `snapshot.py` дословно:

```python
# snapshot.py
import os
import shutil
import subprocess
import sys
import tempfile


def git(workdir, *args, env=None):
    done = subprocess.run(["git", *args], cwd=workdir, env=env, check=True, capture_output=True, text=True)
    return done.stdout.strip()


def worktree_tree(workdir, excludes):
    index = git(workdir, "rev-parse", "--git-path", "index")
    if not os.path.isabs(index):
        index = os.path.join(workdir, index)
    handle, scratch = tempfile.mkstemp(prefix="hh-index.")
    os.close(handle)
    try:
        if os.path.exists(index):
            shutil.copyfile(index, scratch)
        else:
            os.unlink(scratch)
        env = dict(os.environ, GIT_INDEX_FILE=scratch)
        spec = [".", ":!.hermes-notes"] + [f":!{name}" for name in excludes if name]
        git(workdir, "add", "-A", "--", *spec, env=env)
        return git(workdir, "write-tree", env=env)
    finally:
        if os.path.exists(scratch):
            os.unlink(scratch)


def main():
    try:
        print(worktree_tree(sys.argv[1], sys.argv[2:]))
    except Exception:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

2. В `install.sh` после строки `put "$SRC/pregate.py" "$HARNESS/pregate.py"` добавь `put "$SRC/snapshot.py" "$HARNESS/snapshot.py"`.
3. В `selftest.sh` добавь проверки `snapshot.py` (раздел `== loops`, после стенда):

```bash
P="$LP/p-snap"; new_project "$P"
snap() { python3 "$H/snapshot.py" "$P" tasks 2>/dev/null; }
clean_a=$(snap)
check "a clean tree's snapshot is its HEAD tree" "$clean_a" "^$(cd "$P" && git rev-parse 'HEAD^{tree}')\$"
( cd "$P" && echo 2 > code.txt ); dirty=$(snap)
[ "$dirty" != "$clean_a" ] && ok "an edit moves the snapshot" || bad "an edit moves the snapshot" "$dirty"
empty "taking a snapshot stages nothing" "$(cd "$P" && git diff --cached --name-only)"
( cd "$P" && git commit -qam work )
check "the same content has the same snapshot after the commit" "$(snap)" "^$dirty\$"
( cd "$P" && echo 3 > code.txt && git commit -qam other )
[ "$(snap)" != "$dirty" ] && ok "two clean commits have different snapshots" || bad "two clean commits have different snapshots" "$(snap)"
empty "outside a repository the snapshot is empty" "$(python3 "$H/snapshot.py" "$TMP" 2>/dev/null)"
```

4. Добавь сценарии петель:

```bash
P="$LP/p-reuse"; new_project "$P"; : > "$LP/count.txt"
STUB_HERMES_DO="$FILL" HH_TEST_COMMAND="echo run >> $LP/count.txt" loop_run "$P" >/dev/null
STUB_CLAUDE_REPLY="$PASS" HH_TEST_COMMAND="echo run >> $LP/count.txt" loop_review "$P" >/dev/null
check "a measurement taken before the commit is reused after it" "$(wc -l < "$LP/count.txt" | tr -d ' ')" '^2$'

P="$LP/p-stale"; new_project "$P"
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
L="$P/.hermes-harness/logs/10-a-01-x"
stale() { echo STALE-MARK > "$L.check.out"; printf 0 > "$L.check.rc"
          for s in fp snap; do printf da39a3ee5e6b4b0d3255bfef95601890afd80709 > "$L.check.$s"; done
          printf 'echo OLD' > "$L.check.cmd"; }
stale
STUB_CLAUDE_PROMPT="$LP/prompt1.txt" STUB_CLAUDE_REPLY="$PASS" HH_TEST_COMMAND='echo NEW-MARK' loop_review "$P" >/dev/null
check "a measurement of another tree is taken again" "$(cat "$L.check.out")" 'NEW-MARK'
check "and the stale output never reaches the reviewer" "$(grep -c STALE-MARK "$LP/prompt1.txt" || true)" '^0$'
printf 'priority: P1\nstatus: review\nverify: pending\nrole: AGENT\n' > "$P/tasks/10-a/01-x/labels.txt"; stale
STUB_CLAUDE_PROMPT="$LP/prompt2.txt" STUB_CLAUDE_REPLY="$PASS" HH_PREGATE=0 HH_TEST_COMMAND='echo NEW-MARK' loop_review "$P" >/dev/null
check "with the gate off a stale output is not passed on either" "$(grep -c STALE-MARK "$LP/prompt2.txt" || true)" '^0$'
```

   Пояснение к числу 2 в первом сценарии: команда выполняется один раз в `measure` и один раз при замере основания во временной копии. Без исправления — 3.
5. Запусти, сохрани красные строки. Проверки `snapshot.py` будут красными, потому что файла ещё нет — это ожидаемо; создай файл (шаг 1) и убедись, что они позеленели, а сценарии петель остались красными.
6. `run.sh` и `review.sh`. В обоих скриптах замени функцию `work_fingerprint` на три функции. В `review.sh` перед ними добавь строку `guard_root=${HH_PROTECTED_ROOT:-$(basename "$ROOT")}` (в `run.sh` она уже есть, строка 50; перенеси определение функций ниже неё).

```bash
snapshot_id() { python3 "$HARNESS/snapshot.py" "$WORKDIR" "$guard_root" 2>/dev/null || true; }

record_check() {
  printf '%s' "$2" > "$LOGS/$1.check.rc"
  snapshot_id > "$LOGS/$1.check.snap"
  printf '%s' "$TEST_CMD" > "$LOGS/$1.check.cmd"
}

check_is_fresh() {
  local snap; snap=$(snapshot_id)
  [ -n "$snap" ] && [ -f "$LOGS/$1.check.out" ] && [ -f "$LOGS/$1.check.rc" ] \
    && [ "$(cat "$LOGS/$1.check.snap" 2>/dev/null)" = "$snap" ] \
    && [ "$(cat "$LOGS/$1.check.cmd" 2>/dev/null)" = "$TEST_CMD" ]
}
```

7. `run.sh`: `before=$(work_fingerprint)` и `after=$(work_fingerprint)` замени на `snapshot_id`. В `measure` две строки, пишущие `.check.rc` и `.check.fp`, замени на `record_check "$name" "$rc"`.
8. `review.sh`, блок pregate: условие переиспользования (строки 218–219) замени на `if check_is_fresh "$name"; then`; в ветке `else` две строки записи замени на `record_check "$name" "$work_rc"`. Введи переменную `fresh=0` перед блоком `if [ "$PREGATE" = "1" ] …` и ставь `fresh=1` в обеих ветках (переиспользовали или только что измерили).
9. `review.sh`, строка `[ -s "$check_out" ] && check_arg=(…)`: замени условие на `[ "$fresh" = "1" ] && [ -s "$check_out" ]`. Если шлюз выключен, но замер свежий — тоже передавай: перед этой строкой добавь `[ "$fresh" = "0" ] && [ -n "$TEST_CMD" ] && check_is_fresh "$name" && fresh=1 || true`.
10. В `selftest.sh` две старые текстовые проверки поменяй поимённо: в `the measurement is kept for the reviewer to reuse` шаблон `check\.fp` → `check\.snap`. Проверку `the reviewer reuses a measurement of the same tree` оставь как есть, сообщение `reusing it` в `review.sh` сохрани.
11. `./selftest.sh` → `failed 0`.

**OUTCOME.** Замер переиспользуется после коммита того же содержимого; замер другого дерева или другой командой не переиспользуется ни при включённом, ни при выключенном шлюзе; если идентификатор вычислить не удалось, замер считается несвежим.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. `grep -c work_fingerprint run.sh review.sh` — нули.
3. В заметках: красные строки шага 5 и значение `count.txt` до исправления.

---

## T06. Автокоммит берёт только работу этой задачи

**ROLE:** исполнитель. **DEPENDS:** T05.

**GOAL.** В коммит задачи не должны попадать файлы, которые лежали в рабочей копии до неё, и файлы дерева задач, даже если они уже были в индексе.

**CONTEXT.** `run.sh:315–316`: `git add -- . ":!$guard_root" ':!.hermes-notes'`, затем `git commit` без pathspec — коммитится весь индекс. Воспроизведено: в коммит вошли заранее staged `tasks/labels.txt` и посторонний `stranger.txt`. Проверено: `git commit -m … -- . ':!tasks'` оставляет staged-файл задач вне коммита и не трогает его в индексе.

Правило владения: работа считается принадлежащей задаче, если рабочая копия была чистой перед её первой попыткой, и между попытками в ней никто ничего не менял. Иначе харнесс не коммитит, работа остаётся как есть, ревью получает её как незакоммиченную.

**SCOPE.**
+ `run.sh`: начало попытки, конец попытки, блок коммита.
+ `selftest.sh`.
− чужие файлы не удалять, индекс пользователя не чистить, `git stash`/`reset` не использовать.

**ШАГИ.**
1. Добавь в `== loops`:

```bash
P="$LP/p-stranger"; new_project "$P"; echo stranger > "$P/stranger.txt"
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
check "a copy that was dirty before the task is not committed" "$(cd "$P" && git log --oneline | wc -l | tr -d ' ')" '^1$'
check "the task still reaches review"                          "$(label "$P" status)" '^review$'
check "as uncommitted work"                                    "$(cat "$P/.hermes-harness/review/10-a-01-x")" '^worktree$'
check "the stranger's file is still there"                     "$(cat "$P/stranger.txt")" '^stranger$'

P="$LP/p-staged"; new_project "$P"
( cd "$P" && printf '.hermes-harness/\n.hermes-notes/\n' > .gitignore && git add -A && git commit -qm "tree tracked" \
  && echo 'milestone: M1' >> tasks/10-a/01-x/labels.txt && git add tasks/10-a/01-x/labels.txt )
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
check "the task's own work is committed"            "$(cd "$P" && git show --name-only --format= HEAD)" 'code.txt'
check "a task file staged beforehand is left out"   "$(cd "$P" && git show --name-only --format= HEAD | grep -c '^tasks/' || true)" '^0$'
```

2. Запусти, сохрани красные строки.
3. `run.sh`, после функций из T05 добавь:

```bash
tree_is_clean() { [ -z "$(cd "$WORKDIR" && git status --porcelain -- . ':!.hermes-notes' ":!$guard_root" 2>/dev/null)" ]; }
```

   В `mkdir -p` в начале скрипта добавь каталог `"$STATE/own"`.
4. В теле цикла, сразу после строки `before=$(snapshot_id)`:

```bash
  own_file="$STATE/own/$name"
  if tree_is_clean; then
    printf '%s' "$before" > "$own_file"
  elif [ ! -s "$own_file" ] || [ "$(cat "$own_file")" != "$before" ]; then
    rm -f "$own_file"
  fi
```

5. Сразу после строки `after=$(snapshot_id)`: `[ -f "$own_file" ] && printf '%s' "$after" > "$own_file"`.
6. Везде, где удаляются `"$attempts_file"` и `"$session_file"` при переходе в `review`, `blocked` или сбросе в `todo`, удаляй и `"$STATE/own/$name"`. **Исключение:** в ветке перехода в `review` удаляй его только **после** блока коммита.
7. В блоке коммита: между проверкой `git config user.email` и `git add` добавь ветку — если `[ ! -s "$own_file" ]`, то не коммитить: `echo "   not committing: the working copy already held changes that are not this task's"` и `note "$task" "harness: not committed — the working copy held changes from before this task; the work is left uncommitted for review"`.
8. В `git commit` добавь pathspec: `git commit -m "…" -- . ":!$guard_root" ':!.hermes-notes'`.
9. `./selftest.sh` → `failed 0`.

**OUTCOME.** Автокоммит происходит только при чистом старте задачи и содержит только пути вне дерева задач и вне `.hermes-notes`; в остальных случаях работа остаётся незакоммиченной, задача всё равно идёт в `review` с пометкой `worktree`, чужие файлы целы.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. Сценарий `p-happy` из T01 по-прежнему заканчивается коммитом: `cat .hermes-harness/review/10-a-01-x` начинается с `commit `.

---

## T07. Задача попадает в `review` только после того, как её результат зафиксирован

**ROLE:** исполнитель. **DEPENDS:** T06.

**GOAL.** Убрать окно, в котором `review.sh` может забрать задачу, у которой ещё нет коммита и записи о нём.

**CONTEXT.** `run.sh:297–302` пишет `worktree` в `.hermes-harness/review/<задача>`, ставит `status: review`, и только потом (строки 308–325) коммитит и переписывает запись на `commit <sha>`. У `review.sh` свой замок, он может стартовать в этом промежутке.

**SCOPE.**
+ `run.sh`: порядок строк 294–325.
+ `selftest.sh`.
− логику коммита из T06 не менять, только её место.

**ШАГИ.**
1. Добавь в `== loops`:

```bash
P="$LP/p-order"; new_project "$P"; mkdir -p "$P/.git/hooks"
printf '#!/bin/sh\ngrep "^status:" "%s/tasks/10-a/01-x/labels.txt" > "%s/status-at-commit"\n' "$P" "$LP" > "$P/.git/hooks/pre-commit"
chmod +x "$P/.git/hooks/pre-commit"
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
check "a task is not offered for review before its commit exists" "$(cat "$LP/status-at-commit")" 'in_progress'
```

2. Запусти, сохрани красную строку (сейчас там `review`).
3. Переставь блоки так: `measure` → запись `worktree` в `$STATE/review/$name` → **весь блок коммита** (он при успехе переписывает запись на `commit <sha>`) → `note … handed to review` → `tasks set "$task" status review` → `ledger … review` → удаление `attempts_file`, `session_file`, `own`-файла → `finished=$((finished + 1))`.
4. `./selftest.sh` → `failed 0`.

**OUTCOME.** В момент, когда метка становится `review`, файл `.hermes-harness/review/<задача>` уже содержит окончательное значение.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. В `run.sh` строка `tasks set "$task" status review` стоит ниже строки с `git commit`.

---

## T08. Ревью коммита идёт в отдельной копии этого коммита

**ROLE:** исполнитель. **DEPENDS:** T05, T07.

**GOAL.** Ревью задачи A должно читать и проверять код задачи A, даже если в рабочей копии уже лежит работа задачи B.

**Чем эта задача не является.** Временная копия — не граница записи. Она делит `.git` с основной копией и лежит в каталоге, куда пользователь может писать; команда с абсолютным путём пишет куда угодно. Задача решает одно: ревьюер и проверка проекта видят код того коммита, который ревьюится. Не пиши в заметках и сообщениях, что ревьюер «изолирован» или «не может писать».

**CONTEXT.** `capture_diff` показывает сохранённый коммит, но проверка проекта и сам `claude` работают в `$WORKDIR`, где к этому моменту может быть что угодно. `baseline_check` уже умеет делать временную копию через `git worktree add --detach` — используем тот же приём.

**SCOPE.**
+ `review.sh`.
+ `selftest.sh`.
− ревью незакоммиченной работы (`worktree`) и диапазонов (`range …`) остаётся в `$WORKDIR` — это задача T09.
− `baseline_check` не менять.

**ШАГИ.**
1. Добавь в `== loops`:

```bash
P="$LP/p-isolated"; new_project "$P"
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
( cd "$P" && echo BROKEN-BY-A-LATER-TASK > code.txt && git commit -qam later )
STUB_CLAUDE_DO="cat code.txt > $LP/seen.txt" STUB_CLAUDE_REPLY="$PASS" HH_TEST_COMMAND='cat code.txt' loop_review "$P" >/dev/null
check "the reviewer stands in the commit under review"  "$(cat "$LP/seen.txt")" '^2$'
check "the project's check ran there too"               "$(cat "$P/.hermes-harness/logs/10-a-01-x.check.out")" '^2$'
check "the temporary copy is gone afterwards"           "$(cd "$P" && git worktree list | wc -l | tr -d ' ')" '^1$'
```

2. Запусти, сохрани красные строки.
3. `review.sh`. Добавь переменную `review_dir=""` и функцию:

```bash
drop_review_dir() {
  [ -n "$review_dir" ] && ( cd "$WORKDIR" && git worktree remove --force "$review_dir" ) >/dev/null 2>&1
  review_dir=""
}
```

   Вызови `drop_review_dir` первой строкой тела цикла `while :` и добавь его в `release_lock` и `interrupted`, чтобы копия убиралась при любом выходе.
4. После `capture_diff` определи место работы:

```bash
  where=$WORKDIR
  ref_line=$(cat "$STATE/review/$name" 2>/dev/null || echo worktree)
  case "$ref_line" in
    commit\ *)
      review_dir=$(mktemp -d "${TMPDIR:-/tmp}/hh-review.XXXXXX")
      if ! ( cd "$WORKDIR" && git worktree add --detach "$review_dir" "${ref_line#commit }" ) >/dev/null 2>&1; then
        rmdir "$review_dir" 2>/dev/null || true; review_dir=""
        echo "   a copy of ${ref_line#commit } could not be made; the task stays in review" >&2
        exit 1
      fi
      where=$review_dir ;;
  esac
```

5. Сделай так, чтобы `snapshot_id` принимал каталог: `snapshot_id() { python3 "$HARNESS/snapshot.py" "${1:-$WORKDIR}" "$guard_root" 2>/dev/null || true; }`; в `check_is_fresh` и `record_check` вызывай `snapshot_id "$where"`. Для коммита это даёт дерево коммита, то есть тот же идентификатор, что записал `measure` до коммита, — переиспользование из T05 сохраняется.
6. Замени `$WORKDIR` на `$where` в трёх местах: `run_check "$WORKDIR" "$check_out"`, аргумент `--workdir "$WORKDIR"` у `tasks review-prompt`, и `cd "$WORKDIR" && claude -p`. В тексте `CHECK.md` (`run in %s`) тоже подставь `$where`.
7. `./selftest.sh` → `failed 0`. Убедись, что сценарий `p-reuse` из T05 по-прежнему даёт `2`.

**OUTCOME.** Для задач с записью `commit <sha>` проверка проекта и ревьюер работают во временной копии этого коммита; копия удаляется после ревью и при прерывании.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. После любого прогона `review.sh` команда `git worktree list` в проекте показывает столько же строк, сколько до него.

---

## T09. Незакоммиченную работу не ревьюят, пока жива пишущая петля, и наоборот

**ROLE:** исполнитель. **DEPENDS:** T08.

**GOAL.** Для задач с записью `worktree` или `range …` ревью идёт в общей рабочей копии. В это время её никто не должен менять.

**SCOPE.**
+ `review.sh`, `run.sh`, `selftest.sh`.
− существующие `run.lock` и `review.lock` не менять.

**ШАГИ.**
1. Добавь в `== loops` (`$$` здесь — pid самого `selftest.sh`, он заведомо жив):

```bash
P="$LP/p-busy-writer"; new_project "$P"; mkdir -p "$P/.hermes-harness"
printf 'priority: P1\nstatus: review\nverify: pending\nrole: AGENT\n' > "$P/tasks/10-a/01-x/labels.txt"
printf '%s %s\n' "$$" now > "$P/.hermes-harness/run.lock"
out=$(STUB_CLAUDE_REPLY="$PASS" loop_review "$P"); lrc=$?
check "uncommitted work is not reviewed while the writing loop is alive" "$lrc" '^75$'
check "the refusal says who holds the copy"                               "$out" 'the writing loop'
check "and the task keeps its status"                                     "$(label "$P" status)" '^review$'

P="$LP/p-busy-reviewer"; new_project "$P"; mkdir -p "$P/.hermes-harness"
printf '%s\n' "$$" > "$P/.hermes-harness/workdir.busy"
out=$(HH_BUSY_WAIT=1 STUB_HERMES_DO="$FILL" loop_run "$P"); lrc=$?
check "the writing loop waits for a review of the same copy, then gives up" "$lrc" '^75$'
check "without touching the task"                                           "$(label "$P" status)" '^todo$'
```

2. Запусти, сохрани красные строки.
3. `review.sh`, в ветке `*)` того же `case "$ref_line"` из T08: если `$STATE/run.lock` существует и его pid жив (`kill -0`) — `echo "   $name is uncommitted work and the writing loop (pid …) is using that working copy; try again when it stops"` и `exit 75`. Иначе запиши `$$` в `$STATE/workdir.busy`. Удаляй этот файл в `drop_review_dir`.
4. `run.sh`, в начале каждой итерации цикла, до `tasks next`: пока `$STATE/workdir.busy` существует и его pid жив — жди, но в сумме не дольше `HH_BUSY_WAIT` секунд (по умолчанию 3600): каждый шаг ожидания — `sleep` на меньшее из 10 секунд и остатка до срока. По истечении срока — сообщение со словами `a review is using this working copy` и `exit 75`. Файл с мёртвым pid удаляй и продолжай.
5. `./selftest.sh` → `failed 0`.

**OUTCOME.** Ревью незакоммиченной работы и пишущая петля не работают с одной копией одновременно; отказ — это код 75 без изменения статусов.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. После обоих сценариев ни одна метка не изменилась.

---

## T10. Незаполненная форма не уходит ревьюеру

**ROLE:** исполнитель. **DEPENDS:** T07.

**GOAL.** Каждый вызов ревьюера расходует лимит подписки. Пакет, в котором форма `NOTES.md` осталась с `(not checked)` или `(write here)`, должен вернуться исполнителю без вызова `claude`.

**CONTEXT.** Сейчас для передачи в `review` достаточно `exit 0` и любого изменения дерева или формы (`run.sh:281–301`). Форму проверяет только хук `guard-notes.py`, а он срабатывает лишь на ходах с `write_file`/`patch` и ограничен восемью напоминаниями; контроллер не перепроверяет.

**SCOPE.**
+ `tasks.py`: подкоманда `notes-check`.
+ `run.sh`: одна ветка перед передачей.
+ `selftest.sh`.
− `hooks/guard-notes.py` не менять.
− не требовать дифа: заполненная форма без изменений кода («требование уже выполнялось») по-прежнему идёт в `review`.

**ШАГИ.**
1. Проверки `tasks.py`: `notes-check` на заготовке из `tasks.py scaffold` → код 1, в выводе имя критерия; на заполненной форме → код 0, пустой вывод; на несуществующем файле → код 1.
2. Сценарий:

```bash
P="$LP/p-unfilled"; new_project "$P"
STUB_HERMES_DO='echo 2 > code.txt' loop_run "$P" >/dev/null
check "changed code with an unfilled form is not handed to review" "$(label "$P" status)" '^in_progress$'
check "the notes say which rows are missing" "$(cat "$P/tasks/10-a/01-x/NOTES.md")" 'unfilled'
```

3. Запусти, сохрани красные строки.
4. `tasks.py`: функция `unfilled_rows(text: str) -> list[str]` — строки таблицы (начинаются с `|`), содержащие `NOT_CHECKED`, дают имя первой ячейки; если в тексте есть `WRITE_HERE`, добавляется `a section still reading (write here)`. Подкоманда `notes-check <файл>`: печатает строки по одной, код 1 если список непуст или файла нет, иначе 0.
5. `run.sh`, после ветки «дерево не изменилось и форма не тронута», перед вычислением `touched`:

```bash
  if ! missing=$(tasks notes-check "$notes_dir/NOTES.md"); then
    echo "   the notes form is unfilled -> stays open"
    ledger "$name" worker in_progress in_progress "notes form unfilled"
    note "$task" "harness: the run ended with the notes form unfilled: $(printf '%s' "$missing" | tr '\n' ';')"
    continue
  fi
```

   Файл сессии при этом не удаляется — следующая попытка продолжит сессию с уже существующим напоминанием заполнить форму.
6. `./selftest.sh` → `failed 0`.

**OUTCOME.** В `review` попадают только попытки с полностью заполненной формой; остальные остаются открытыми с записью, каких строк не хватает.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. В сценарии `p-unfilled` подставной `claude` не вызывался (он и не мог: `review.sh` не запускался, статус `in_progress`).

---

## T11. Ревьюеру разрешены точная проверка проекта и чтение; всё, что умеет писать, из списка убрано

**ROLE:** исполнитель. **DEPENDS:** T05, T08.

**GOAL.** Сузить список разрешений ревьюера до команд, которые не умеют создавать файлы, и до проверки проекта ровно в том виде, в каком её задал владелец. Это **сужение разрешений**, а не изоляция: гарантию «ревьюер не может писать» дают только права среды, и в этот файл задач она не входит.

**CONTEXT.**
- `review.sh:281`: `allowed+=("Bash(${TEST_CMD%% *}:*)")` — берётся первое слово команды. При `HH_TEST_COMMAND='python3 -m pytest -q'` это `Bash(python3:*)`: по документации Claude Code `Bash(x:*)` равносильно `Bash(x *)`, то есть любой запуск `python3`.
- Проверено запуском: `sed -n 'w файл' вход` и `git diff --output=файл` создают файлы. Опцию `--output` понимают также `git show` и `git log`. Все четыре команды разрешены сейчас по префиксу (`review.sh:278–280`). Пропустит ли их движок разрешений настоящего Claude Code, не проверено; задача не ждёт этой проверки, а убирает сами правила.
- Диф ревьюеру от этого не нужен через `git`: контроллер уже строит его сам (`capture_diff`). Достаточно положить полный диф файлом туда, где ревьюер может его прочитать инструментом Read. Каталог `.hermes-notes/` в рабочей копии исключён из оттисков, дифов и коммитов — подходит.
- Правило с хвостом `Bash($TEST_CMD *)` тоже не годится: дополнительные аргументы — это не «более узкий набор тестов», а что угодно: плагины, пути вывода, конфигурация. После T05 ревьюер получает свежий замер от харнесса, так что повторный запуск ему обычно не нужен.
- Связанное место: `verdict.py` считает ревью негодным, если проверке проекта отказали и её нет в `evidence`. Когда харнесс сам передал свежий замер, отказ в запуске ревью не портит.

**SCOPE.**
+ `review.sh`: массив `allowed` (строки 278–281), функция `capture_diff`, вызов `verdict.py`.
+ `verdict.py`: пятый аргумент.
+ `selftest.sh`.
− `tasks.py` не менять.

**ШАГИ.**
1. Сценарий:

```bash
P="$LP/p-perms"; new_project "$P"
STUB_HERMES_DO="$FILL" loop_run "$P" >/dev/null
STUB_CLAUDE_ARGS="$LP/args.txt" STUB_CLAUDE_DO="cp .hermes-notes/under-review.diff $LP/seen.diff" STUB_CLAUDE_REPLY="$PASS" \
  HH_TEST_COMMAND='cat code.txt' loop_review "$P" >/dev/null
check "the reviewer may run the project's check exactly as written" "$(cat "$LP/args.txt")" '^Bash\(cat code\.txt\)$'
check "and nothing that merely starts like it"  "$(grep -cE '^Bash\(cat( code\.txt \*|:\*)\)$' "$LP/args.txt" || true)" '^0$'
check "nothing on the list can write a file"    "$(grep -cE '^Bash\((sed|git diff|git show|git log)' "$LP/args.txt" || true)" '^0$'
check "the whole change is left where the reviewer can read it" "$(cat "$LP/seen.diff" 2>/dev/null)" 'code\.txt'
```

2. Проверки `verdict.py`: измени помощник на `verdict_of() { python3 "$H/verdict.py" "$env_file" "$vd" "$1" "$2" "${3:-0}" 2>&1; }`. Возьми конверт существующей проверки `refusing the project's own check does ruin the review` и добавь вторую: тот же конверт, третий аргумент `1` → `^passed 1 yes$`.
3. Запусти, сохрани красные строки.
4. `review.sh`, массив `allowed`: оставь `Read Grep Glob`, `"Bash(git status:*)"`, `"Bash(git ls-files:*)"`, `"Bash(rg:*)"`, `"Bash(wc:*)"`, `"Bash(ls:*)"`. Убери `"Bash(git diff:*)"`, `"Bash(git show:*)"`, `"Bash(git log:*)"`, `"Bash(sed -n:*)"`. Строку 281 замени на `[ -n "$TEST_CMD" ] && allowed+=("Bash($TEST_CMD)") || true`.
5. `capture_diff`: перед усечением сохрани полный диф — `cp "$out" "$out.full"` сразу после его построения. Текст об усечении замени на `# ... truncated at %s characters. The whole change is in .hermes-notes/under-review.diff`.
6. После того как в T08 определена переменная `where`: `mkdir -p "$where/.hermes-notes" && cp "$diff_file.full" "$where/.hermes-notes/under-review.diff"`.
7. В вызов `verdict.py` добавь пятый аргумент `"$fresh"` (переменная из T05).
8. `verdict.py`: `measured = len(sys.argv) > 5 and sys.argv[5] == "1"`; правило про отказ в проверке проекта применяй только при `not measured`.
9. `./selftest.sh` → `failed 0`. Если старая текстовая проверка в `selftest.sh` искала в `review.sh` одно из убранных правил, назови её в заметках и приведи к новому списку.

**OUTCOME.** В списке разрешений ревьюера нет ни одной команды, про которую известно, что она создаёт файлы, и нет разрешений по первому слову; проверка проекта разрешена дословно; полный диф лежит в `.hermes-notes/under-review.diff` рабочего места ревьюера; отказ в запуске не портит ревью, если харнесс передал свежий замер.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. `grep -n 'TEST_CMD%%\|sed -n:\|git diff:\|git show:\|git log:' review.sh` ничего не находит.

**Чего эта задача не даёт, и это надо оставить в заметках.** Проверка проекта исполняет произвольный код проекта с правами пользователя. `rg`, `ls`, `wc` и `git status` файлов не создают, но это свойство команд, а не запрет среды. Ни одно слово из «изолирован», «не может писать», «read-only» в заметках и сообщениях не употребляй.

---

## T12. Журналы попыток и ревью не затираются

**ROLE:** исполнитель. **DEPENDS:** T07.

**GOAL.** Сохранять транскрипт каждой попытки и конверт каждого ревью, чтобы можно было восстановить, на что ушёл лимит и почему задача вернулась.

**CONTEXT.** `run.sh:212`, `:215` пишут `> "$LOGS/$name.ndjson"` — следующая попытка затирает предыдущую. `review.sh:285` хранит одно прошлое поколение.

**SCOPE.**
+ `run.sh`, `review.sh`, `selftest.sh`.
− имена `$LOGS/$name.ndjson`, `$name.review.json`, `$name.review.previous.json` остаются и значат «последний».

**ШАГИ.**
1. Сценарий: `new_project`, два запуска `STUB_HERMES_RC=1 loop_run` подряд → в `$P/.hermes-harness/logs/history/` два файла `10-a-01-x.*.ndjson`. Затем ревью → там же один `*.review.json`.
2. Запусти, сохрани красные строки.
3. `run.sh`: после вычисления `rc` скопируй `$LOGS/$name.ndjson` и `$LOGS/$name.err` в `$LOGS/history/$name.$(date -u +%Y%m%dT%H%M%SZ).a$((attempts + 1)).ndjson` / `.err`.
4. `review.sh`: после вызова `claude` скопируй `$LOGS/$name.review.json` в `$LOGS/history/$name.<та же форма метки времени>.review.json`.
5. Хранение: после копирования оставляй по каждой задаче не больше `HH_LOG_KEEP` (по умолчанию 20) самых новых файлов каждого вида, остальные удаляй.
6. `./selftest.sh` → `failed 0`.

**OUTCOME.** Каждая попытка и каждое ревью оставляют свой файл в `logs/history/`.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.

---

## T13. Размышления прошлых ходов возвращаются в историю

**ROLE:** исполнитель. **DEPENDS:** T01. Задача меняет только шаблон конфигурации в репозитории; на сервер строка попадёт или не попадёт по решению задачи R4 второй части.

**GOAL.** Вернуть модель в штатный режим, в котором её мерил производитель.

**CONTEXT.** Официальный шаблон Qwen3.8 по умолчанию рендерит `<think>…</think>` для **каждого** прошлого хода ассистента (`preserve_thinking` включён; карточка: «especially beneficial for agent scenarios… It also improves KV cache utilization»). Hermes при `model.reasoning_echo: false` (умолчание, `hermes_cli/config_defaults.py:250`) вырезает `reasoning_content` из истории (`agent/message_sanitization.py:522`). Итог сейчас: каждый прошлый ход уходит на сервер с пустым `<think>`, и prompt на каждом ходу расходится с тем, что сервер держит в кэше.

**SCOPE.**
+ `config.yaml`: одна строка в разделе `model:`.
+ `selftest.sh`: одна проверка в `== config`.
− остальной `config.yaml`.

**ШАГИ.**
1. Проверка: `check "earlier reasoning is replayed to the model" "$cfg" 'reasoning_echo: true'`. Запусти, сохрани красную строку.
2. В `config.yaml` после строки `context_length: 131072` добавь `  reasoning_echo: true`.
3. `./selftest.sh` → `failed 0`.

**OUTCOME.** Шаблон конфигурации включает воспроизведение размышлений.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. `python3 -c "import yaml; print(yaml.safe_load(open('config.yaml'))['model']['reasoning_echo'])"` печатает `True`.

**Что остаётся второй части (R5 в `server-tasks.md`):** включить на сервере и сравнить на одной и той же задаче с `false`: число сжатий контекста, время до `review`, вердикты. Сохранённые мысли ускоряют рост контекста, сжатие на 98 304 токенах наступит раньше — это цена, её надо увидеть числом.

---

## T14. Уровень размышлений задан явно, а не оставлен умолчаниям

**ROLE:** исполнитель. **DEPENDS:** T01. Задача меняет только шаблон конфигурации в репозитории. Условия, при которых эту строку можно выкатывать на сервер, проверяет задача R4 второй части; здесь их проверять нечем и не нужно.

**GOAL.** Сделать так, чтобы глубина размышлений модели не зависела от версии Hermes.

**CONTEXT.** Сейчас уровень нигде не задан. На закреплённом Hermes `784d5c3f` при незаданном `agent.reasoning_effort` поле в запрос не попадает, и действует умолчание шаблона Qwen3.8 — `xhigh`. Более новый Hermes (проверено на `6182078`) при тех же условиях — custom-провайдер, chat completions, уровень не задан — сам отправляет `reasoning_effort: medium`; `llama-server` на `5b59b83` передаёт поле запроса в шаблон (`tools/server/server-common.cpp:1346–1353`). Один и тот же `config.yaml` после обновления Hermes даст другую глубину размышлений, и в журналах харнесса этого не будет видно.

Проверено по исходникам `784d5c3f`: явное `agent.reasoning_effort: xhigh` превращается в поле верхнего уровня `reasoning_effort: xhigh` (`plugins/model-providers/custom/__init__.py:45–53`, допустимые значения — `agent/reasoning_effort.py:28`). Шаблон при `xhigh` рендерит ту же инструкцию, что и по умолчанию, то есть prompt не меняется. Hermes допускает и `high`, но шаблон Qwen3.8 принимает только `xhigh`, `medium`, `low` и на остальное бросает исключение — поэтому значение именно `xhigh`.

**SCOPE.**
+ `config.yaml`: одна строка в разделе `agent:`.
+ `selftest.sh`: одна проверка в `== config`.
− остальной `config.yaml`.

**ШАГИ.**
1. Проверка: `check "the reasoning effort is pinned, not left to defaults" "$cfg" 'reasoning_effort: xhigh'`. Запусти, сохрани красную строку.
2. В `config.yaml` в разделе `agent:` после строки `max_verify_nudges: 8` добавь `  reasoning_effort: xhigh`.
3. `./selftest.sh` → `failed 0`.

**OUTCOME.** Шаблон конфигурации задаёт уровень размышлений явно.

**VERIFY.**
1. `./selftest.sh` — `failed 0`.
2. `python3 -c "import yaml; print(yaml.safe_load(open('config.yaml'))['agent']['reasoning_effort'])"` печатает `xhigh`.

**Что остаётся второй части (R6 в `server-tasks.md`).** Убедиться по фактическому запросу, что поле уходит и равно `xhigh` (хук `pre_api_request` отдаёт тело запроса; либо журнал `llama-server` с `--verbose` на одном запросе). Исходники показывают, как строятся параметры, а не то, что установленная копия их отправила.

---

## D1. Документы: убрать утверждения, которые не подтвердились

**ROLE:** исполнитель. **DEPENDS:** T04, T13, T14. Код не трогать. Две строки, помеченные «после R1», пиши только когда в репозитории появится `docs/server-facts.md`; если его нет — оставь эти два места в документах как есть и запиши это в заметках. Тон и язык каждого документа сохранить (README — английский, `docs/` — русский). Менять только названные места.

| Файл и место | Что не так | Что написать |
| --- | --- | --- |
| `README.md:25–27`, «Auto-detection will not save you…» | Hermes читает `n_ctx` из `/props` llama.cpp; таблица `qwen → 131072` — последний шаг, а не первый | Explicit `model.context_length` wins over detection, so a wrong pin is still possible; keep it pinned for reproducibility and keep it equal to the server's `-c`. Without the pin Hermes reads the running `n_ctx` from llama.cpp `/props`. |
| `README.md:102–105`, «Hermes ends a turn the moment…» | слишком общо: при `intent_ack_continuation: true` и `stall_guards` Hermes до двух раз за ход возвращает модель к действию | сказать, что после двух таких возвратов ход всё равно заканчивается прозой, и поэтому внешнее продолжение сессии остаётся нужным |
| `README.md:262–264`, «a forged `status: done` changes nothing…» | до T04 это было неверно | A `done` without `verify: passed` releases nothing: dependents wait for the reviewer's `verify: passed`, the agent role cannot write `status: done`, and `status.sh` lists labels that disagree. |
| `README.md:295`, «Compression triggers at 75%… whatever `compression.threshold` says» | неполно | порог — `max(compression.threshold, 0.75)` для окон меньше 512k; при 131072 и незаданном `max_tokens` это 98 304 токена (заданный `max_tokens` вычитается из окна до умножения); есть абсолютный предел `compression.threshold_tokens` |
| `README.md`, раздел Reviewing, про `--permission-mode dontAsk` | после T11 список разрешений другой | одна фраза: проверка проекта разрешена дословно и с дополнительными аргументами, первое слово команды больше не разрешение |
| `docs/operating.md` §2, пункт про `context_length` | «Hermes не спрашивает сервер» | то же, что для README:25 |
| `docs/operating.md` §2, пункт про `compression.threshold` | «сжатие около 65k»; ссылка на «драйверный обрыв» | при 131k сжатие срабатывает на 98 304 токенах; фразу про обрыв скорости удалить целиком |
| `docs/operating.md` §5, таблица, `HH_REVIEW_BUDGET` | «долларов на один разбор» | расчётная величина CLI; ревьюер работает по подписке, это не списание, а потолок на один разбор |
| `docs/operating.md` §6 и §8 | нет исходов T03, T04, T10 | добавить строки: «сбой вызова ревьюера → без изменений, `review.sh` выходит с кодом 75»; «форма не заполнена → остаётся открытой»; в §8 — «задачи, закрытые вручную, требуют `verify: passed`» |
| `docs/model-serving.md` §0, пункт 5 списка «Сделано» | предупреждение по версии драйвера | версию драйвера записывать как часть окружения, без выводов по её номеру; замер на ~30k, ~60k и ~90k токенов контекста, отдельно скорость обработки запроса (prefill) и отдельно скорость декодирования — по таймингам журнала сервера, а не делением токенов на полное время запроса |
| `docs/model-serving.md` §4, абзац «Про пункт 5» | диагноз «драйверный» отозван автором issue 27623: ошибка метрики, обрыв не воспроизводится | удалить абзац; вместо него одна фраза: если декодирование на 90k падает в разы относительно 30k — это находка для отчёта, а не повод менять драйвер |
| `docs/model-serving.md` §2, `hf download … --include "*Q6_K*"` | маска захватывает четыре файла, ≈ 95 ГБ | `hf download unsloth/Qwen3.8-27B-GGUF Qwen3.8-27B-UD-Q6_K.gguf --revision 4ca720788d1e01f1bff70c033e0d0028fd02e502 --local-dir /models/qwen3.8-27b`; рядом размер 21 983 677 344 байт и sha256 `c9c206812fbe4ac7b76a729e25928b63f2ae89d37f69da7a71c20aec763cd436` |
| `docs/operating.md` §2, после абзаца про `context_length` | нет предупреждения об обновлении Hermes | добавить: Hermes закреплён на upstream `784d5c3f`. При незаданном `agent.reasoning_effort`, custom-провайдере на chat completions и официальном шаблоне модели переход с `784d5c3f` на исследованный `6182078` может заменить умолчание шаблона `xhigh` явным `medium`: новый Hermes сам подставляет это значение, а `llama-server` передаёт поле запроса в шаблон. Поэтому уровень задан в `config.yaml` явно (T14), а обновлять Hermes — только как отдельный эксперимент между двумя закреплёнными SHA, со сверкой фактического запроса в обоих плечах |
| **после R1:** `docs/model-serving.md` §3, про `--cache-reuse` | «с MTP не сочетается и отключается сам» | в коде llama.cpp условия про MTP нет: reuse отключается при мультимодальности или если память контекста не умеет сдвиг; что происходит на этой модели, видно по строке журнала (см. `server-facts.md`) |
| `docs/model-serving.md` §6 | нет оговорки про `--reasoning-effort` | шаблон модели принимает только `xhigh`, `medium`, `low` и бросает исключение на остальное; уровень — это фраза в системном сообщении, его смена сбрасывает весь кэш префикса |
| **после R1:** `docs/model-serving.md` §1, «несёт тензоры MTP-головы» | не подтверждено | оставить как есть, если `server-facts.md` п.4 показал строки с `nextn`; иначе заменить на «MTP-голова лежит отдельным файлом `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`» |

**VERIFY.**
1. `./selftest.sh` — `failed 0` (документы проверок не ломают).
2. `grep -n '591\|580\.x\|65k\|65 тыс' README.md docs/operating.md docs/model-serving.md` ничего не находит (другие файлы в `docs/` эти строки содержат законно — их не трогать).
3. `git diff --stat` показывает только три файла документации.

---

## Что сюда сознательно не вошло

- Изоляция исполнителя правами ОС (отдельный пользователь или контейнер, дефект F5). Это решение о модели угроз, его принимает человек.
- Идентификатор тестового окружения в ключе baseline и устойчивые к коллизиям имена задач вместо `tr '/' '-'` (остаток F8).
- Эксперименты E2–E6 из исходного отчёта: уровень и бюджет размышлений, глубина MTP, порог сжатия, более новый Hermes. Они имеют смысл только после T00–T08, когда измерениям и вердиктам можно верить, и по одному изменяемому фактору за раз.
- Миграция на Kanban и `hermes --worktree`: последний удаляет рабочее дерево при выходе, если в нём нет неопубликованных коммитов, то есть уничтожает незакоммиченный результат.
