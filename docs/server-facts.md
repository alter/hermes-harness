# R1. Факты об установке

Собрано на сервере с RTX 5090. Каждый раздел — команда и её вывод дословно.

## 1. Команда запуска `llama-server`

Команда:

```
ps -o args= -C llama-server
```

Вывод:

```
./build/bin/llama-server -m /home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf -c 131072 -ctk q8_0 -ctv q8_0 -fa on -ngl 99 -b 4096 -ub 1024 --parallel 1 --spec-type draft-mtp --spec-draft-n-max 2 --jinja --reasoning-format deepseek --reasoning on --reasoning-budget 8192 --ctx-checkpoints 32 --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --presence-penalty 0.0 --host 127.0.0.1 --port 8080
```

Рабочий каталог процесса (`readlink /proc/<pid>/cwd`): `/home/alter/qwen/llama.cpp-new`.

## 2. Журнал сервера

Файл журнала найден через файловые дескрипторы процесса (`ls -la /proc/<pid>/fd`, дескрипторы 1 и 2 указывают на `/home/alter/qwen/models-new/server.log`). Процесс запущен в 15:27, журнал целиком — 16 строк, запросов на модель после этого старта ещё не поступало.

Команда:

```
cat /home/alter/qwen/models-new/server.log
```

Вывод (дословно, целиком):

```
0.00.122.715 I cmn  common_param: common_params_print_info: verbosity = 3 (adjust with the `-lv N` CLI arg)
0.00.123.096 W srv  llama_server: -----------------
0.00.123.120 W srv  llama_server: CORS is set to allow all origins ('*') and no API key is set
0.00.123.120 W srv  llama_server: this can be a security risk (cross-origin attacks)
0.00.123.121 W srv  llama_server: more info: https://github.com/ggml-org/llama.cpp/pull/25655
0.00.123.121 W srv  llama_server: -----------------
0.00.124.543 I srv    load_model: loading model '/home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf'
0.14.954.720 I cmn          init: llama threadpool init, n_threads = 12
0.15.061.244 I common_speculative_init_result: creating MTP draft context against the target model '/home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf'
0.15.444.396 I srv    load_model: initializing, n_slots = 1, n_ctx_slot = 131072, kv_unified = 'false'
0.15.796.751 W srv          init: chat template supports preserving reasoning, it is enabled by default (may use more tokens, disable via --no-reasoning-preserve)
0.15.796.827 I srv  llama_server: model loaded
0.15.796.854 I srv  llama_server: listening on http://127.0.0.1:8080
0.15.796.855 W srv  llama_server: NOTICE: server default port will be changed to :9931 in a future release
0.15.796.855 W srv  llama_server:         ref: https://github.com/ggml-org/llama.cpp/pull/26508
```

Строка со словом `mtp`: строка 9 (`creating MTP draft context against the target model`).
Строка `cache_reuse is not supported`: отсутствует в журнале.
Строка с долей принятых черновиков после длинного ответа: отсутствует — ни один запрос ещё не обработан этим процессом.
Строки про checkpoint при обработке запроса: отсутствуют — тот же повод.
Строка о размере KV-кэша: буквальной строки о размере KV-кэша в байтах нет; единственная относящаяся к слоту/контексту строка — строка 10 (`n_slots = 1, n_ctx_slot = 131072, kv_unified = 'false'`).

## 3. Шаблон и окно (`/props`)

Команда:

```bash
curl -s http://127.0.0.1:8080/props | python3 -c "
import json,sys,hashlib
d=json.load(sys.stdin); t=d.get('chat_template','')
print('n_ctx', d['default_generation_settings'].get('n_ctx'))
print('template chars', len(t), 'sha256', hashlib.sha256(t.encode()).hexdigest())
for word in ('preserve_thinking','reasoning_effort','xhigh'): print(word, word in t)"
```

Вывод:

```
n_ctx 131072
template chars 9993 sha256 12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce
preserve_thinking True
reasoning_effort True
xhigh True
```

Для сравнения sha256 официального шаблона `Qwen/Qwen3.8-27B` в задаче — `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`. Вычисленный на сервере sha256 (`12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce`) с ним не совпадает.

## 4. MTP-голова в GGUF

Команда:

```bash
python3 /home/alter/qwen/llama.cpp-new/gguf-py/gguf/scripts/gguf_dump.py /home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf | grep -c nextn
```

Вывод:

```
5
```

Команда:

```bash
python3 /home/alter/qwen/llama.cpp-new/gguf-py/gguf/scripts/gguf_dump.py /home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf | grep -i "blk.64.nextn.eh_proj.weight"
```

Вывод:

```
    862:   52428800 | 10240,  5120,     1,     1 | Q6_K    | blk.64.nextn.eh_proj.weight
```

`gguf_dump.py` запущен из `/home/alter/qwen/llama.cpp-new` — это каталог, в котором собран запущенный `llama-server` (см. раздел 1; `git rev-parse HEAD` там же — раздел 6).

## 5. Слитая конфигурация Hermes

Команда:

```bash
grep -n 'reasoning\|threshold\|context_length\|max_tokens\|default:' ~/.hermes/config.yaml
```

Вывод:

```
2:  default: Qwen3.8-27B-Uncensored-Cyber-IQ4_XS-imatrix-fromq8.gguf
6:  context_length: 262144
16:  reasoning_effort: medium
70:  threshold: 0.5
91:  show_reasoning: true
217:  denial_breaker_threshold: 0
```

## 6. Что на самом деле исполняется

Команда:

```bash
diff -rq /mnt/c/claude/artifacts/repos/hermes-harness ~/.hermes/harness
```

Вывод:

```
Only in /mnt/c/claude/artifacts/repos/hermes-harness: .git
Only in /mnt/c/claude/artifacts/repos/hermes-harness: .gitignore
Only in /mnt/c/claude/artifacts/repos/hermes-harness: LICENSE
Only in /mnt/c/claude/artifacts/repos/hermes-harness: README.md
Files /mnt/c/claude/artifacts/repos/hermes-harness/__pycache__/tasks.cpython-314.pyc and /home/alter/.hermes/harness/__pycache__/tasks.cpython-314.pyc differ
Only in /mnt/c/claude/artifacts/repos/hermes-harness: config.yaml
Only in /mnt/c/claude/artifacts/repos/hermes-harness: docs
Files /mnt/c/claude/artifacts/repos/hermes-harness/hooks/guard-notes.py and /home/alter/.hermes/harness/hooks/guard-notes.py differ
Only in /mnt/c/claude/artifacts/repos/hermes-harness: install.sh
Only in /mnt/c/claude/artifacts/repos/hermes-harness: project-template
Files /mnt/c/claude/artifacts/repos/hermes-harness/review.sh and /home/alter/.hermes/harness/review.sh differ
Files /mnt/c/claude/artifacts/repos/hermes-harness/run.sh and /home/alter/.hermes/harness/run.sh differ
Only in /mnt/c/claude/artifacts/repos/hermes-harness: selftest.sh
Only in /mnt/c/claude/artifacts/repos/hermes-harness: snapshot.py
Only in /mnt/c/claude/artifacts/repos/hermes-harness: status.sh
Files /mnt/c/claude/artifacts/repos/hermes-harness/tasks.py and /home/alter/.hermes/harness/tasks.py differ
Only in /mnt/c/claude/artifacts/repos/hermes-harness: uninstall.sh
Files /mnt/c/claude/artifacts/repos/hermes-harness/verdict.py and /home/alter/.hermes/harness/verdict.py differ
```

Команда:

```bash
git -C /mnt/c/claude/artifacts/repos/hermes-harness log --oneline -1
```

Вывод:

```
7456543 README: update the check count, stale after this session's additions
```

## 7. `hermes`: путь и версия установки

Команда:

```bash
command -v hermes
```

Вывод:

```
/home/alter/.local/bin/hermes
```

Содержимое `/home/alter/.local/bin/hermes`:

```
#!/usr/bin/env bash
unset PYTHONPATH
unset PYTHONHOME
exec "/home/alter/.hermes/hermes-agent/venv/bin/python" "/home/alter/.hermes/hermes-agent/hermes" "$@"
```

Каталог установки Hermes — `/home/alter/.hermes/hermes-agent`.

Команда:

```bash
git -C /home/alter/.hermes/hermes-agent rev-parse HEAD
```

Вывод:

```
784d5c3f9c2cb77698d8a9d2e72b1d106a38ea88
```

Команда:

```bash
git -C /home/alter/.hermes/hermes-agent status --short | head -40
```

Вывод: пусто (нет незакоммиченных правок).

Дополнительно, версия по CLI:

```bash
hermes --version
```

Вывод:

```
Hermes Agent v0.21.3 (2026.9.14) · upstream 784d5c3f
Install directory: /home/alter/.hermes/hermes-agent
Install method: git
Python: 3.13.15
OpenAI SDK: 2.24.0
Update available: 3497 commits behind — run 'hermes update'
```

## 8. `claude`: путь и версия

Команда:

```bash
command -v claude
```

Вывод:

```
/home/alter/.local/bin/claude
```

Команда:

```bash
claude --version
```

Вывод:

```
2.1.278 (Claude Code)
```

## 9. GPU

Команда:

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv
```

Вывод:

```
name, driver_version, memory.total [MiB], memory.used [MiB]
NVIDIA GeForce RTX 5090, 616.56, 32607 MiB, 28900 MiB
```

# После выкатки (R4)

Условие начала проверено: `6af3c16` (версия, которую нельзя было нести на сервер) — предок текущего `HEAD`, т.е. T00–T09 и T13/T14 первой части уже в `origin/main`, идти дальше можно.

## Шаг 1–2: `git pull`, `./selftest.sh`

`run.lock`/`review.lock` не найдены нигде под `/home/alter` и под клонами (`/home/alter/hh-sandbox/.hermes-harness`, `/mnt/c/claude/artifacts/repos/hft/.hermes-harness`) — до и после каждого шага R4.

```bash
git pull
```
```
Already up to date.
```

```bash
./selftest.sh | tail -1
```
```
passed 243, failed 0
```

## Шаг 3: ворота для двух строк `config.yaml`

`model.reasoning_echo: true` (T13): в шаблоне на сервере есть `preserve_thinking` (`docs/server-facts.md`, раздел 3: `preserve_thinking True`) — строка остаётся без изменений.

`agent.reasoning_effort: xhigh` (T14): три условия по таблице —
- в команде запуска нет `--reasoning-effort` (раздел 1) — верно;
- в шаблоне есть `reasoning_effort` и `xhigh` (раздел 3) — верно;
- в слитой конфигурации уровень не задан или `xhigh` (раздел 5) — **неверно**: `~/.hermes/config.yaml` до установки показывает `reasoning_effort: medium` (не пусто и не `xhigh`).

Строка удалена из `config.yaml` клона перед установкой (только для этого запуска `install.sh`; после установки исходный файл в клоне восстановлен из git, коммит T14 не тронут).

Проверено отдельно, не входит в буквальный текст шлюза, но относится к тому же решению: `reasoning_effort: xhigh` в репозитории — новый ключ, `git log -p -- config.yaml` показывает, что до `cedc6cd` (сегодня, 21 сентября) строки `reasoning_effort` в `config.yaml` репозитория не было вовсе. При этом `reasoning_effort: medium` в установленной `~/.hermes/config.yaml` — не результат прежней установки харнесса: то же значение, тем же местом (строка 16), стоит во всех 22 бэкапах `install.sh` на этом сервере, включая самый первый — от 18 сентября, за три дня до появления T14. Источник этого значения (человек, `hermes config`, вендорское поведение Hermes, что-то ещё) из этой сессии не виден.

**Нерешённое противоречие, а не закрытое решение.** Раз `medium` не установочный мусор, а нечто, стабильно живущее в файле три дня, шлюз шага 3 сработал правильно, ничего другого он и не мог сделать с буквальным условием таблицы («не задан или xhigh» — а тут явно задан и не xhigh). Но тогда ожидание шага 4 («`failed 0`») этим же документом одновременно недостижимо: приложение T14 запрещено шлюзом, а его отсутствие — ровно то, что валит `selftest.sh`. Это решает не эта сессия.

## Шаг 4: `./install.sh`, `./selftest.sh ~/.hermes`, `hermes hooks doctor`

Команда отката (напечатана `install.sh`, сохранена):

```
/mnt/c/claude/artifacts/repos/hermes-harness/uninstall.sh /home/alter/.hermes-harness-backup/20260921-161606
```

Полный вывод `install.sh`:

```
== backup -> /home/alter/.hermes-harness-backup/20260921-161606
== install -> /home/alter/.hermes/harness
== config.yaml: merge
   model.default kept as 'Qwen3.8-27B-Uncensored-Cyber-IQ4_XS-imatrix-fromq8.gguf'
   model.context_length: 262144 -> 131072
   model.reasoning_echo: True
   hooks.pre_tool_call: 0 kept, 2 ours
   hooks.pre_verify: 0 kept, 1 ours
== check
   hooks: 3
   model: Qwen3.8-27B-Uncensored-Cyber-IQ4_XS-imatrix-fromq8.gguf
== hook consent
   agent.shell_hooks is not importable from any python this script can find;
   refreshing the consent file directly.
   re-stamped: pre_tool_call -> guard-paths.py
   re-stamped: pre_tool_call -> guard-read.py
   re-stamped: pre_verify -> guard-notes.py
   3 approval(s) refreshed in /home/alter/.hermes/shell-hooks-allowlist.json
   verify with: hermes hooks doctor

Done.
  backup:   /home/alter/.hermes-harness-backup/20260921-161606
  rollback: /mnt/c/claude/artifacts/repos/hermes-harness/uninstall.sh /home/alter/.hermes-harness-backup/20260921-161606 
  selftest: /mnt/c/claude/artifacts/repos/hermes-harness/selftest.sh /home/alter/.hermes
```

Факт, напечатанный самим `install.sh` и не входящий в шлюз шага 3: `model.default` в установленной конфигурации — `Qwen3.8-27B-Uncensored-Cyber-IQ4_XS-imatrix-fromq8.gguf`; модель, которую в это время в действительности отдаёт `/v1/models` на `:8080`, — `/home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf` (раздел 3 и `docs/serving-report.md`). Значения не совпадают.

```bash
./selftest.sh ~/.hermes | tail -1
```
```
passed 245, failed 1
```

Единственный провал:

```
FAIL  the reasoning effort is pinned, not left to defaults
```

Прямое следствие решения из шага 3: строка T14 в установленную копию не попала, поэтому проверка, рассчитанная на её наличие, не проходит. Это и есть нерешённое противоречие, описанное в конце шага 3 — `failed 0`, которого просит шаг 4, недостижим без нарушения запрета шага 3 на перезапись `medium`. Ни то, ни другое эта сессия не решала за человека.

```bash
hermes hooks doctor
```
```
Checking 3 configured shell hook(s)...

  [pre_tool_call] python3 /home/alter/.hermes/harness/hooks/guard-paths.py
      ✓ script exists and is executable
      ✓ allowlisted (approved 2026-09-21T13:16:10.547362Z)
      ✓ script unchanged since approval
      ✓ ran clean with empty stdout (exit=0, 0.156s) — hook is observer-only

  [pre_tool_call] python3 /home/alter/.hermes/harness/hooks/guard-read.py
      ✓ script exists and is executable
      ✓ allowlisted (approved 2026-09-21T13:16:10.547362Z)
      ✓ script unchanged since approval
      ✓ ran clean with empty stdout (exit=0, 0.135s) — hook is observer-only

  [pre_verify] python3 /home/alter/.hermes/harness/hooks/guard-notes.py
      ✓ script exists and is executable
      ✓ allowlisted (approved 2026-09-21T13:16:10.547362Z)
      ✓ script unchanged since approval
      ✓ ran clean with empty stdout (exit=0, 0.135s) — hook is observer-only

All shell hooks look healthy.
```

Без предупреждений.

## Шаг 5: `diff -rq` клона и установленной копии

```bash
diff -rq /mnt/c/claude/artifacts/repos/hermes-harness ~/.hermes/harness
```
```
Only in /mnt/c/claude/artifacts/repos/hermes-harness: .git
Only in /mnt/c/claude/artifacts/repos/hermes-harness: .gitignore
Only in /mnt/c/claude/artifacts/repos/hermes-harness: LICENSE
Only in /mnt/c/claude/artifacts/repos/hermes-harness: README.md
Files /mnt/c/claude/artifacts/repos/hermes-harness/__pycache__/tasks.cpython-314.pyc and /home/alter/.hermes/harness/__pycache__/tasks.cpython-314.pyc differ
Only in /mnt/c/claude/artifacts/repos/hermes-harness: config.yaml
Only in /mnt/c/claude/artifacts/repos/hermes-harness: docs
Only in /mnt/c/claude/artifacts/repos/hermes-harness: install.sh
Only in /mnt/c/claude/artifacts/repos/hermes-harness: project-template
Only in /mnt/c/claude/artifacts/repos/hermes-harness: selftest.sh
Only in /mnt/c/claude/artifacts/repos/hermes-harness: uninstall.sh
```

В скриптах (`run.sh`, `review.sh`, `status.sh`, `tasks.py`, `verdict.py`, `hooks/guard-notes.py`) различий нет — все перечисленные расхождения это файлы, которых в установленной копии нет по устройству `install.sh` (git-метаданные, документация, сам `config.yaml`-источник) либо скомпилированный `.pyc`.

## Шаг 6: один прогон одной задачи вручную

Проект: `/home/alter/hh-sandbox` (отдельная песочница с деревом задач, не связана с этим репозиторием). Задача `10-x/02-second` создана этой же сессией по образцу уже закрытой `10-x/01-hello` — тривиальная (`src/second.py` печатает `second`) — специально для этой проверки.

Первая попытка (`HH_MAX_TASKS=1` для `run.sh`):

```
== 10-x-02-second (attempt 1/3)
   VERIFY `python3 src/second.py | grep -qx second` exited 1
   hermes exited 1 -> stays open
```

Причина — не код харнесса. `.hermes-harness/logs/10-x-02-second.err` и `.ndjson` дали:

```
text: "Custom endpoint didn't respond in time on any of 3 attempts — it looks temporarily unavailable. ... Provider said: Connection error."
```

Прямая проверка в тот же момент: `pgrep -a llama-server` — пусто; `ss -tln` — `:8080` не слушается; хвост `/home/alter/qwen/models-new/server.log`:

```
50.15.387.746 I srv    operator(): operator(): cleaning up before exit...
```

Процесс `llama-server` (тот, что описан в разделе 1, pid 334631) завершился между разделом 5 `docs/serving-report.md` (последний успешный запрос к нему, task 752) и этой попыткой — не по команде этой сессии: в этой сессии между этими двумя моментами выполнялись только R3 (`claude`, без обращения к `:8080`) и шаги 1–5 этого раздела (`git`, `selftest.sh`, `install.sh`, `hermes hooks doctor`, `diff`), ни один не обращается к `:8080` или к процессу `llama-server`. Через непродолжительное время `llama-server` оказался снова запущен — тем же образом, с тем же командным флагом (сверено с разделом 1), но с другим pid (387328) и слушающим `:8080`; кем или чем он был перезапущен, из этой сессии не видно.

Вторая попытка, после того как `curl -s http://127.0.0.1:8080/health` снова стал отвечать `{"status":"ok"}`:

```
== 10-x-02-second (attempt 2/3)
   resuming session 20260921_162336_0a83de rather than starting over
   VERIFY `python3 src/second.py | grep -qx second` exited 0
   the working tree changed, 4 path(s) differ from HEAD -> review
   committed in /home/alter/hh-sandbox
```

`src/second.py`:
```python
import sys

sys.stdout.write("second\n")
```

Затем `HH_REVIEW_ONLY=10-x/02-second` для `review.sh`:

```
== 10-x-02-second (review round 1/2)
   change under review: the change under review is commit 6f39eebc2fca48836d3010505162c1a6ca5d7455, 527 characters
   verdict: passed (denied commands: 1, usable: yes)
   cost: 0.25 USD
   -> done
```

Проверка трёх фактов, как в задаче:

```bash
cat /home/alter/hh-sandbox/.hermes-harness/calls.tsv
```
```
2026-09-21T13:30:38Z	10-x-02-second	0	0.2504595	5	6	1290	success
```

```bash
~/.hermes/harness/status.sh
```
(фрагмент)
```
== reviews
   reviewer verdicts: done 1
   ...
   reviewer calls: 1
```

```bash
head -1 /home/alter/hh-sandbox/.hermes-harness/review/10-x-02-second
```
```
commit 6f39eebc2fca48836d3010505162c1a6ca5d7455
```

Все три подтверждены.
