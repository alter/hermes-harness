# R2. Числа о сервинге

Собрано на сервере с RTX 5090, тот же процесс `llama-server` на `:8080`, что описан в `docs/server-facts.md`, раздел 1. Числа — из таймингов журнала сервера (`prompt eval time`, `eval time`), не делением числа токенов на время запроса.

Перед началом: `find` по `run.lock`/`review.lock` под `/home/alter` и под клонами репозитория (`/home/alter/hh-sandbox/.hermes-harness`, `/mnt/c/claude/artifacts/repos/hft/.hermes-harness`) — ни одного файла с этим именем не найдено.

## 1. Prefill и decode на ~30k / 60k / 90k токенов

Запросы — `POST /v1/chat/completions`, каждый со своим уникальным префиксом (`Nonce-<random>`), чтобы исключить переиспользование кэша между тремя измерениями. `max_tokens: 200`.

Строки из журнала сервера (`prompt eval time`, `eval time`, `draft acceptance` — черновики MTP включены штатной командой запуска):

```
# ~30k токенов, task 215
27.27.645.446 I slot print_timing: id  0 | task 0 | prompt eval time =   12034.87 ms / 30052 tokens (    0.40 ms per token,  2497.08 tokens per second)
27.27.645.473 I slot print_timing: id  0 | task 0 |        eval time =    2800.80 ms /   200 tokens (   14.07 ms per token,    71.05 tokens per second)
```

Примечание: приведённая выше пара строк — из первого пробного запроса (без изоляции кэша, `cached_tokens: 0`). Далее — три измерения с изоляцией кэша (уникальный nonce на каждый запрос, `cached_tokens: 42` — совпадение только системного префикса шаблона):

```
# ~30k токенов, task 215, prompt_tokens=30021, cached_tokens=42
29.47.037.066 I slot print_timing: id  0 | task 215 | prompt eval time =   11436.62 ms / 30021 tokens (    0.38 ms per token,  2624.99 tokens per second)
29.47.037.093 I slot print_timing: id  0 | task 215 |        eval time =    2943.21 ms /   200 tokens (   14.79 ms per token,    67.61 tokens per second)
29.47.037.100 I slot print_timing: id  0 | task 215 | draft acceptance = 0.46117 (   95 accepted /   206 generated), mean len =  1.92

# ~60k токенов, task 330, prompt_tokens=60020, cached_tokens=42
30.33.081.844 I slot print_timing: id  0 | task 330 | prompt eval time =   25500.19 ms / 60020 tokens (    0.42 ms per token,  2353.71 tokens per second)
30.33.081.874 I slot print_timing: id  0 | task 330 |        eval time =    2991.99 ms /   200 tokens (   15.04 ms per token,    66.51 tokens per second)
30.33.081.880 I slot print_timing: id  0 | task 330 | draft acceptance = 0.57609 (  106 accepted /   184 generated), mean len =  2.15

# ~90k токенов, task 441, prompt_tokens=90019, cached_tokens=42
31.30.501.168 I slot print_timing: id  0 | task 441 | prompt eval time =   44957.06 ms / 90019 tokens (    0.50 ms per token,  2002.33 tokens per second)
31.30.501.196 I slot print_timing: id  0 | task 441 |        eval time =    3304.04 ms /   200 tokens (   16.60 ms per token,    60.23 tokens per second)
31.30.501.202 I slot print_timing: id  0 | task 441 | draft acceptance = 0.58152 (  107 accepted /   184 generated), mean len =  2.16
```

Шесть чисел (prefill / decode, tokens/sec):

| Длина контекста | prefill, tok/s | decode, tok/s |
| --- | --- | --- |
| ~30k | 2624.99 | 67.61 |
| ~60k | 2353.71 | 66.51 |
| ~90k | 2002.33 | 60.23 |

## 2. MTP включён/выключен на другом порту — не выполнено

**Попытка остановлена по факту риска для рабочего сервера на `:8080`, задача не выполнена.**

Команда запуска второго сервера на `:8081` (уменьшенный `-ngl 6 -c 2048 -b 512 -ub 512`, чтобы поместиться в свободную память — полный `-ngl 99 -c 131072`, как на `:8080`, при уже занятых 29023 MiB из 32607 MiB не помещается: файл модели весит 20 GiB на диске одной копией):

```bash
./build/bin/llama-server -m /home/alter/qwen/models-new/Qwen3.8-27B-UD-Q6_K.gguf \
  -c 2048 -ctk q8_0 -ctv q8_0 -fa on -ngl 6 -b 512 -ub 512 --parallel 1 \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --jinja --reasoning-format deepseek --reasoning on --reasoning-budget 8192 \
  --ctx-checkpoints 4 --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --repeat-penalty 1.0 --presence-penalty 0.0 \
  --host 127.0.0.1 --port 8081
```

Память сразу после загрузки второй копии:

```bash
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv
```

```
memory.total [MiB], memory.used [MiB], memory.free [MiB]
32607 MiB, 32032 MiB, 156 MiB
```

Свободно осталось 156 MiB из 32607 MiB. Следующая команда — обычный `curl .../health` на рабочий сервер `:8080` — была отклонена классификатором харнесса Claude Code с причиной `Interfere With Workloads`.

Действие: вторая копия остановлена (`kill`), память восстановлена, работоспособность `:8080` подтверждена:

```bash
kill <pid второй копии>
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv
```

```
memory.total [MiB], memory.used [MiB], memory.free [MiB]
32607 MiB, 28363 MiB, 3825 MiB
```

```bash
curl -s -m 3 http://127.0.0.1:8080/health
```

```
{"status":"ok"}
```

Повторная попытка с другими параметрами `-ngl`/`-c` не предпринималась: ограничение — объём VRAM (32607 MiB), а не выбор параметров второго запуска; при занятых первым процессом ~29 GiB для второй копии модели (20 GiB на диске) без остановки первого свободного места нет ни при каком разумном `-ngl`, дающем осмысленное сравнение.

## 3. Память под `-c 131072`

Команда:

```bash
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv
```

Вывод (в состоянии простоя сервера с `-c 131072`; выделение KV-кэша под `-c 131072` в этой сборке происходит при старте сервера, а не по мере поступления запросов — до и после запросов раздела 1 показание не менялось за вычетом обычного разброса компute-буферов):

```
memory.total [MiB], memory.used [MiB], memory.free [MiB]
32607 MiB, 28693 MiB, 3495 MiB
```

Строка вида `KV self size` в журнале сервера отсутствует (см. `docs/server-facts.md`, раздел 2 — полный журнал приведён целиком).

## 4. Поведение кэша между ходами агента

Три запроса `POST /v1/chat/completions` подряд: (a) первый ход — 8018 токенов промпта; (b) второй ход — то же сообщение + ответ первого хода + короткая реплика (симуляция продолжения диалога); (c) посторонний короткий запрос; (d) снова второй ход, после постороннего запроса.

Ответы CLI (`usage.prompt_tokens_details.cached_tokens`):

```
[turn1] usage {'completion_tokens': 150, 'prompt_tokens': 8060, 'total_tokens': 8210, 'prompt_tokens_details': {'cached_tokens': 42}}
[turn2] usage {'completion_tokens': 100, 'prompt_tokens': 8092, 'total_tokens': 8192, 'prompt_tokens_details': {'cached_tokens': 8056}}
[foreign] usage {'completion_tokens': 20, 'prompt_tokens': 63, 'total_tokens': 83, 'prompt_tokens_details': {'cached_tokens': 42}}
[turn2b_after_foreign] usage {'completion_tokens': 100, 'prompt_tokens': 8094, 'total_tokens': 8194, 'prompt_tokens_details': {'cached_tokens': 8064}}
```

Соответствующие строки журнала сервера:

```
37.03.255.299 I slot get_availabl: id  0 | task -1 | selected slot by LRU, t_last = 344366150831
37.03.258.618 W srv         alloc:  - making room for prompt cache entry, removing oldest entry (size = 1955.248 MiB)
37.07.102.268 I slot launch_slot_: id  0 | task 558 | processing task, is_child = 0
37.15.718.567 I slot print_timing: id  0 | task 558 | prompt eval time =    6605.83 ms /  8018 tokens (    0.82 ms per token,  1213.78 tokens per second)
37.15.718.599 I slot print_timing: id  0 | task 558 | draft acceptance = 0.47059 (   72 accepted /   153 generated), mean len =  1.94
37.15.718.740 I slot      release: id  0 | task 558 | stop processing: n_tokens = 8209, truncated = 0

37.23.416.904 I slot get_availabl: id  0 | task -1 | selected slot by LCP similarity, f_sim_best = 0.996 (> 0.100 thold), f_keep = 0.982
37.23.417.041 I slot launch_slot_: id  0 | task 640 | processing task, is_child = 0
37.25.397.874 I slot print_timing: id  0 | task 640 | prompt eval time =     783.24 ms /    36 tokens (   21.76 ms per token,    45.96 tokens per second)
37.25.397.901 I slot print_timing: id  0 | task 640 |       total time =    1980.79 ms /   136 tokens
37.25.398.050 I slot      release: id  0 | task 640 | stop processing: n_tokens = 8191, truncated = 0

37.31.432.065 I slot get_availabl: id  0 | task -1 | selected slot by LCP similarity, f_sim_best = 0.730 (> 0.100 thold), f_keep = 0.006
37.31.432.487 W srv         alloc:  - making room for prompt cache entry, removing oldest entry (size = 3305.606 MiB)
37.32.289.131 I slot launch_slot_: id  0 | task 690 | processing task, is_child = 0
37.33.065.246 I slot print_timing: id  0 | task 690 | prompt eval time =     570.23 ms /    21 tokens (   27.15 ms per token,    36.83 tokens per second)
37.33.065.340 I slot      release: id  0 | task 690 | stop processing: n_tokens = 82, truncated = 0

37.40.948.039 I slot get_availabl: id  0 | task -1 | selected slot by LRU, t_last = 344728729569
37.41.572.734 I slot launch_slot_: id  0 | task 700 | processing task, is_child = 0
37.43.152.617 I slot print_timing: id  0 | task 700 | prompt eval time =     294.52 ms /    30 tokens (    9.82 ms per token,   101.86 tokens per second)
37.43.152.649 I slot print_timing: id  0 | task 700 |    graphs reused =        636
37.43.152.876 I slot      release: id  0 | task 700 | stop processing: n_tokens = 8193, truncated = 0
```

Второй ход (task 640): из 8092 токенов промпта заново обработано 36 (`selected slot by LCP similarity`, `f_keep = 0.982`), остальное — из кэша. Посторонний запрос (task 690) вклинился между ними и вызвал вытеснение кэшированной записи (`making room for prompt cache entry, removing oldest entry (size = 3305.606 MiB)`) — но эта запись относится к предыдущему циклу (первому измерению из раздела 1 набора), а не к обсуждаемому диалогу: диалог продолжил использовать кэш дальше. Возврат к диалогу после постороннего запроса (task 700): из 8094 токенов заново обработано 30, остальные 8064 — из кэша (`cached_tokens: 8064`).

## 5. `tool_calls` и разделение размышления

Команда (дословно из `docs/model-serving.md`, раздел 4, пункт 2):

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"x","messages":[{"role":"user","content":"What is the weather in Paris? Use the tool."}],
  "tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
  "properties":{"city":{"type":"string"}},"required":["city"]}}}]}' \
  | python3 -c "import json,sys; m=json.load(sys.stdin)['choices'][0]['message']; print('tool_calls:', bool(m.get('tool_calls'))); print('reasoning separated:', 'reasoning_content' in m)"
```

Вывод:

```
tool_calls: True
reasoning separated: True
```

## R5. `reasoning_echo`: критерий отката (записан до прогонов)

Задача: `10-knowledge-system/02-knowledge-graph` в реальном проекте `hft` (`HH_TASK_ROOT=task_manager`), выбрана по прямому указанию человека — единственная реальная разноразмерная задача, доступная на сервере. Примечание, известное на момент выбора: задача просит воссоздать граф знаний, который в этом проекте уже строили и намеренно удалили как мёртвый код (см. ревизию 2026-08-27 в `task.txt` самой задачи) — для целей этого измерения это не значимо: нужен реальный, не игрушечный объём работы и реальных вызовов инструментов, а не именно эта фича.

**Критерий отката (до прогонов):** оставляем `reasoning_echo: true` (текущее, из T13), если ни одно из следующего не произойдёт на плече `true`:
1. задача не дошла до `review` (осталась `todo`/`in_progress`/`blocked`) из-за сжатий контекста;
2. вердикт ревьюера на плече `true` хуже, чем на плече `false` (сравнение: `verdict` — `passed` лучше `failed`/`blocked`; при равном `verdict` — по числу пунктов в `unmet`/«Not met», меньше лучше).

Если сработало любое из двух — откат на `false`.

Оба прогона — в новых сессиях (не `resume`), с холодным стартом `llama-server` перед каждым (одна и та же командная строка, см. `docs/server-facts.md`, раздел 1). Один прогон на плечо — проверка на грубую поломку, не доказательство выигрыша.

### R5. Результат

Между плечами: полная инвентаризация и откат состояния плеча `false` перед стартом плеча `true` — не только `git status` в `hft` (плечо `false` не закоммитилось: рабочее дерево уже держало чужие незакоммиченные правки в других задачах, харнесс отказался коммитить), но и файлы вне git (`.hermes-notes/10-knowledge-system-02-knowledge-graph/`) и внутреннее состояние харнесса (`.hermes-harness/{review,returns}/...` для этой задачи). После отката `git status` в `hft` побайтово совпал с состоянием до плеча `false`. Плечо `true` стартовало действительно новой сессией (в выводе `run.sh` нет строки «resuming session»).

| | `reasoning_echo: false` | `reasoning_echo: true` |
| --- | --- | --- |
| `session_id` | `20260921_182304_a8b57b` | `20260921_192108_408c54` |
| сжатий контекста | 1 (99 082 → 84 358 токенов, `agent.log`) | 2 (100 262 → 42 359; 98 538 → 60 830, `agent.log`) |
| время до `review` (`duration_ms` из результата ndjson) | 2 938 125 мс (≈ 48 м 58 с) | 2 705 339 мс (≈ 45 м 5 с) |
| вердикт шлюза (project check) | нет — `HH_TEST_COMMAND` для `hft` не задан | нет — тот же |
| вердикт ревьюера | `failed`, cost 1.63 USD | `passed`, cost 1.15 USD |
| раздел «Not met» ревьюера | 2 пункта: дословный `graph query "MM модели"` (одним аргументом) возвращает пусто — тесты передают термин уже разбитым и это не ловят; `pytest` целиком не прогонялся (запуск запрещён ревьюеру) | пусто (`unmet: []`) |
| `finish_reason: length` в ndjson | поле в ndjson отсутствует вообще (0 совпадений). В `~/.hermes/logs/agent.log` есть `finish_reason` только для последнего хода сессии (`Turn ended: reason=text_response(finish_reason=stop) ... session=20260921_182304_a8b57b`) — `stop`, не `length`; количество по всем ходам сессии (не только последнему) ни в одном из логов не публикуется | то же: последний ход `finish_reason=stop` (`session=20260921_192108_408c54`); по всем ходам — та же нехватка данных |

**Решение.** Критерий отката не сработал — плечо `true` дошло до `review` и получило `passed`, лучше, чем `failed` на `false`. `reasoning_echo` остаётся `true` (текущее значение, менять не пришлось).

Плечо `true` в реальности означало не только измерение: задача `10-knowledge-system/02-knowledge-graph` в `hft` была решена по-настоящему и закоммичена в `676fa1f` (`status: done`, `verify: passed` — не закоммичено харнессом автоматически по той же причине, что и раньше — рабочее дерево уже не чистое — оставлено как есть, дальше человеку). Плечо `false` вернуло задачу в `todo` (вердикт `failed`) и было полностью откачено до запуска второго плеча — от него в репозитории `hft` не осталось следов, кроме исторических файлов харнесса (`calls.tsv`, `ledger.tsv`, `logs/history/`).

## R8. Не запущено — нет годной задачи в очереди

Условие R8: не меньше 3 повторов на плечо. Самый дешёвый вариант из таблицы (MTP включён/выключён — не требует настоящего Claude-ревью, только `run.sh` и время/долю принятых черновиков из журнала сервера) — это 2 плеча × 3 повтора = 6 настоящих прогонов Hermes по реальной задаче, ~45–50 минут каждый по опыту R5 (`docs/serving-report.md`, раздел R5).

После того как R5 по-настоящему закрыла `10-knowledge-system/02-knowledge-graph`, очередь `hft` держит ровно две `ready` задачи:
- `10-knowledge-system/03-rag-integration` — `status:in_progress`, чужая настоящая незавершённая работа; `run.sh` в режиме `next` может её резюмировать — трогать нельзя;
- `30-experimentation/32-vip-fee-tiers-unimplemented` — `role:architect`, `build:none`, `type:design`, и по тексту самого узла (ревизия владельца 2026-08-29) правильный исход — письменное решение, что тир НЕ реализуется, а не код. Не даёт объёма генерации кода, нужного для сигнала по времени/доле черновиков.

Другого реального проекта с медиум-задачами на сервере нет (см. выбор задачи для R5). Годной третьей задачи не нашлось — это не решается дальнейшим поиском в этой же очереди, нужен новый источник задач. R8 не запущен.

## Окружение

Версия драйвера как часть описания окружения (без выводов по её номеру): `616.56` (см. `docs/server-facts.md`, раздел 9).
