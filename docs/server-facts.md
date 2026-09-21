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
