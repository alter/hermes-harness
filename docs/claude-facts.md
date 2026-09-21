# R3. Как на самом деле отвечает Claude Code

Выполнено на сервере (`claude` из `docs/server-facts.md`, раздел 8), в пустом временном каталоге с `git init` и одним файлом `file.txt` (после `git init` — коммит с исходным содержимым, затем некоммиченное изменение одной строки, чтобы `git status`/`git diff` были непустыми). Флаги — те же, что в `review.sh`: `--model opus --effort high --fallback-model sonnet --permission-mode dontAsk --permission-prompts none --tools "Bash,Read,Grep,Glob" --allowedTools … --output-format json --json-schema "$SCHEMA" --max-budget-usd …`, схема — `SCHEMA` из `review.sh` (строки 219–227). Три вызова, ровно как согласовано (не больше).

Версия:

```bash
claude --version
```

```
2.1.278 (Claude Code)
```

## 1. Обычный вызов

Команда:

```bash
echo "Look at file.txt in this git repository. Use git status and git diff to see what changed, then report a one-sentence summary of the change. This is a short, low-cost test task." \
| claude -p \
    --model opus --effort high --fallback-model sonnet \
    --permission-mode dontAsk --permission-prompts none \
    --tools "Bash,Read,Grep,Glob" \
    --allowedTools Read Grep Glob "Bash(git status:*)" "Bash(git ls-files:*)" "Bash(rg:*)" "Bash(wc:*)" "Bash(ls:*)" \
    --output-format json --json-schema "$SCHEMA" \
    --max-budget-usd 5
```

Код выхода: `0`.

Конверт (дословно):

```json
{"duration_api_ms":5005,"stop_reason":"tool_use","session_id":"1c3e16ba-7056-4868-a77c-8b975463cc8b","total_cost_usd":0.7195550000000001,"usage":{"input_tokens":4,"cache_creation_input_tokens":67597,"cache_read_input_tokens":67330,"output_tokens":396,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":67597,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":2,"output_tokens":302,"cache_read_input_tokens":67330,"cache_creation_input_tokens":267,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":267},"type":"message"}],"speed":"standard"},"modelUsage":{"claude-opus-5":{"inputTokens":4,"outputTokens":396,"cacheReadInputTokens":67330,"cacheCreationInputTokens":67597,"webSearchRequests":0,"costUSD":0.7195550000000001,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":0,"canonicalModel":"claude-opus-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":false,"num_turns":3,"subtype":"success","api_error_status":null,"result":"{\"verdict\":\"passed\",\"summary\":\"В file.txt изменена одна строка: вторая строка «line two» заменена на «line two CHANGED», остальное не тронуто.\",\"evidence\":[{\"claim\":\"file.txt — единственный изменённый отслеживаемый файл, в diff заменена одна строка\",\"command\":\"git status --short && git diff -- file.txt\",\"output\":\" M file.txt\\n?? call1.review.err\\n?? call1.review.json\\n?? schema.json\\n@@ -1,3 +1,3 @@\\n line one\\n-line two\\n+line two CHANGED\\n line three\"}],\"unmet\":[]}","structured_output":{"verdict":"passed","summary":"В file.txt изменена одна строка: вторая строка «line two» заменена на «line two CHANGED», остальное не тронуто.","evidence":[{"claim":"file.txt — единственный изменённый отслеживаемый файл, в diff заменена одна строка","command":"git status --short && git diff -- file.txt","output":" M file.txt\n?? call1.review.err\n?? call1.review.json\n?? schema.json\n@@ -1,3 +1,3 @@\n line one\n-line two\n+line two CHANGED\n line three"}],"unmet":[]},"ttft_ms":1991,"type":"result","duration_ms":5557,"uuid":"67b813c9-7113-45da-8d72-02eec634afb7","ttft_stream_ms":1483,"time_to_request_ms":97,"first_content_frame_ms":1483,"queued_turn_count":0,"result_index":0}
```

Поля в конверте (полный список ключей верхнего уровня): `duration_api_ms, stop_reason, session_id, total_cost_usd, usage, modelUsage, permission_denials, terminal_reason, fast_mode_state, fast_mode_disabled_reason, subagent_stats, is_error, num_turns, subtype, api_error_status, result, structured_output, ttft_ms, type, duration_ms, uuid, ttft_stream_ms, time_to_request_ms, first_content_frame_ms, queued_turn_count, result_index`. Присутствуют все пять полей из вопроса: `structured_output`, `total_cost_usd` (0.7195550000000001), `num_turns` (3), `usage`, `subtype` (`success`), `permission_denials` (`[]`).

`structured_output` соответствует схеме `SCHEMA` (`verdict`, `summary`, `evidence`, `unmet` — обязательные поля присутствуют; `next_step` отсутствует, схема его не требует).

## 2. Старый список разрешений (`Bash(git diff:*)`, `Bash(sed -n:*)`)

Команда:

```bash
echo "In this git repository, run exactly these two commands and report their exit codes: (1) git diff --output=probe1.txt (2) sed -n 'w probe2.txt' file.txt" \
| claude -p \
    --model opus --effort high --fallback-model sonnet \
    --permission-mode dontAsk --permission-prompts none \
    --tools "Bash,Read,Grep,Glob" \
    --allowedTools Read Grep Glob "Bash(git diff:*)" "Bash(sed -n:*)" \
    --output-format json --json-schema "$SCHEMA" \
    --max-budget-usd 5
```

Код выхода: `0`.

Появились ли файлы: нет. `ls -la probe1.txt probe2.txt` после вызова — `No such file or directory` для обоих.

Конверт (дословно):

```json
{"duration_api_ms":14459,"stop_reason":"tool_use","session_id":"9232e7d6-8b51-48e3-97af-cc65f2e1eebd","total_cost_usd":0.218702,"usage":{"input_tokens":8,"cache_creation_input_tokens":8571,"cache_read_input_tokens":199154,"output_tokens":1335,"output_tokens_details":{"thinking_tokens":77},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":8571,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":4,"output_tokens":599,"cache_read_input_tokens":69925,"cache_creation_input_tokens":522,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":522},"type":"message"}],"speed":"standard"},"modelUsage":{"claude-opus-5":{"inputTokens":8,"outputTokens":1335,"cacheReadInputTokens":199154,"cacheCreationInputTokens":8571,"webSearchRequests":0,"costUSD":0.218702,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":77,"canonicalModel":"claude-opus-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_01QToXEDQPxBBhRC3mAeR6XT","tool_input":{"command":"git diff --output=probe1.txt; echo \"exit1=$?\"","description":"Write git diff to probe1.txt and print exit code"}},{"tool_name":"Bash","tool_use_id":"toolu_01BXPmo4ntZDFbacaxdZLNnn","tool_input":{"command":"sed -n 'w probe2.txt' file.txt; echo \"exit2=$?\"","description":"Copy file.txt to probe2.txt via sed and print exit code"}}],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":false,"num_turns":5,"subtype":"success","api_error_status":null,"result":"{\"verdict\":\"blocked\",\"summary\":\"Я не запустил ни одну из двух команд, поэтому кодов возврата нет. Сессия работает в режиме «don't ask», и в нём Bash запрещён: обе попытки отклонены ещё до запуска. Файлы probe1.txt и probe2.txt не созданы.\",\"evidence\":[{\"claim\":\"Запрет прав доступа отклонил команду 1, и она не запускалась\",\"command\":\"git diff --output=probe1.txt; echo \\\"exit1=$?\\\"\",\"output\":\"Permission to use Bash has been denied because Claude Code is running in don't ask mode.\"},{\"claim\":\"Запрет прав доступа отклонил команду 2, и она не запускалась\",\"command\":\"sed -n 'w probe2.txt' file.txt; echo \\\"exit2=$?\\\"\",\"output\":\"Permission to use Bash has been denied because Claude Code is running in don't ask mode.\"}],\"unmet\":[\"Код возврата команды `git diff --output=probe1.txt` не получен: Bash запрещён\",\"Код возврата команды `sed -n 'w probe2.txt' file.txt` не получен: Bash запрещён\"],\"next_step\":\"Разрешите Bash для этих команд (/permissions, правила allow Bash(git diff:*) и Bash(sed:*)) или выйдите из режима «don't ask», затем запустите задачу снова. Можно также выполнить обе команды вручную с `echo $?`.\"}","structured_output":{"verdict":"blocked","summary":"Я не запустил ни одну из двух команд, поэтому кодов возврата нет. Сессия работает в режиме «don't ask», и в нём Bash запрещён: обе попытки отклонены ещё до запуска. Файлы probe1.txt и probe2.txt не созданы.","evidence":[{"claim":"Запрет прав доступа отклонил команду 1, и она не запускалась","command":"git diff --output=probe1.txt; echo \"exit1=$?\"","output":"Permission to use Bash has been denied because Claude Code is running in don't ask mode."},{"claim":"Запрет прав доступа отклонил команду 2, и она не запускалась","command":"sed -n 'w probe2.txt' file.txt; echo \"exit2=$?\"","output":"Permission to use Bash has been denied because Claude Code is running in don't ask mode."}],"unmet":["Код возврата команды `git diff --output=probe1.txt` не получен: Bash запрещён","Код возврата команды `sed -n 'w probe2.txt' file.txt` не получен: Bash запрещён"],"next_step":"Разрешите Bash для этих команд (/permissions, правила allow Bash(git diff:*) и Bash(sed:*)) или выйдите из режима «don't ask», затем запустите задачу снова. Можно также выполнить обе команды вручную с `echo $?`."},"ttft_ms":2071,"type":"result","duration_ms":14742,"uuid":"6556aa60-438b-4db1-8755-5baaf677fb77","ttft_stream_ms":1683,"time_to_request_ms":101,"first_content_frame_ms":1683,"queued_turn_count":0,"result_index":0}
```

Что попало в `permission_denials`: два элемента, оба `tool_name: "Bash"`, с `tool_input.command`, дословно равным тому, что модель составила сама — не голой команде из задания, а с добавленным `; echo "exit…=$?"` (это добавление модели, задание просило только отчёт о кодах возврата, не диктовало точный текст команды). Обе попытки отклонены; в `structured_output.evidence[].output` модель воспроизводит текст отказа: `Permission to use Bash has been denied because Claude Code is running in don't ask mode.`

## 3. `--max-budget-usd 0.01` с заведомо более дорогим заданием

Команда:

```bash
echo "Review file.txt in this git repository thoroughly: read it, check git status and git diff, and write a detailed multi-paragraph analysis of the change, its implications, and alternative approaches. This should be a long, thorough response." \
| claude -p \
    --model opus --effort high --fallback-model sonnet \
    --permission-mode dontAsk --permission-prompts none \
    --tools "Bash,Read,Grep,Glob" \
    --allowedTools Read Grep Glob "Bash(git status:*)" "Bash(git ls-files:*)" "Bash(rg:*)" "Bash(wc:*)" "Bash(ls:*)" \
    --output-format json --json-schema "$SCHEMA" \
    --max-budget-usd 0.01
```

Код выхода: `1`.

Конверт (дословно):

```json
{"duration_api_ms":0,"stop_reason":"tool_use","session_id":"556a7b76-8092-4e1f-a4b5-7183706a4e7d","total_cost_usd":0.090968,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{"claude-opus-5":{"inputTokens":2,"outputTokens":196,"cacheReadInputTokens":61876,"cacheCreationInputTokens":5512,"webSearchRequests":0,"costUSD":0.090968,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":28,"canonicalModel":"claude-opus-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"budget_exhausted","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":true,"num_turns":1,"subtype":"error_max_budget_usd","errors":["Reached maximum budget ($0.01)"],"type":"result","duration_ms":2944,"uuid":"40d46e9a-c6f2-44da-9826-8051abf631fd","queued_turn_count":0,"result_index":0}
```

`subtype`: `error_max_budget_usd`. `is_error`: `true`. `terminal_reason`: `budget_exhausted`. `total_cost_usd`: `0.090968` — фактический расход превысил заданный потолок `0.01` (списание считается по завершённому ходу целиком, потолок не остановил его на середине).

## 4. Настоящее исчерпание лимита подписки

Не наступало. Раздел остаётся пустым до первого настоящего случая; тогда сюда без изменений добавляются `<проект>/.hermes-harness/logs/<задача>.review.json`, `.review.err` и код выхода из вывода `review.sh`.

## Потрачено

Три вызова CLI, расчётная стоимость по ответу CLI (`total_cost_usd`): `0.7195550000000001 + 0.218702 + 0.090968` = `1.029225...` USD. Списание по подписке — нет; это ответ API, не платёж (см. `docs/server-tasks.md`, R8: «расчётный USD из ответа CLI — не списание»).
