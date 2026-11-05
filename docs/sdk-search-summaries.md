# Поиск по SDK: summary вместо описания

Дата: 2026-10-06 / 2026-10-07. Ветка `deepseek-agent-loop`.

## Зачем

Сгенерированная программа не могла сыграть звук: `find_sdk_function` предлагал
`MediaKit.AVPlayer.play` (воспроизведение файла, нужен `url`) вместо подходящей
функции. Причина — тексты в индексе. Описания в `sdk-index.json` — это первая
строка JSDoc из заголовков OpenHarmony, и у многих функций она ничего не говорит
о том, зачем функция нужна: у `AudioRenderer.write` это «Writes the buffer.».
Слова «sound», «beep», «tone» там нет, поэтому по запросу про звук функцию не
находят.

## Что сделано

1. **Summary на каждую функцию.** `tools/build-sdk-summaries.py` берёт полный
   JSDoc функции (все перегрузки, описание класса, параметры, возвращаемое,
   ошибки), отдаёт `deepseek-flash` и получает 1–2 предложения: что функция
   делает простыми словами и для чего её обычно берут. Результат лежит в
   `tools/sdk-summaries.json` (11 684 функции, по ключу `Kit.module.name`).
2. **Одна запись на функцию.** SDK объявляет одну операцию несколько раз
   (callback- и promise-форма, старый и новый тип результата, иногда в разных
   файлах). Раньше каждое объявление было записью индекса, и в топ-8 повторялись
   копии одной функции. `tools/build-sdk-index.py` теперь склеивает их по
   `kit.module.name`: 16 511 → 11 684 записей. Остаётся вариант без
   `AsyncCallback` (он подходит под пары имя/значение `sdk.call`).
3. **Текст эмбеддинга — `kit module name summary`.** Summary заменяет описание, а
   не добавляется к нему. Если summary нет, остаётся описание. Тот же текст в
   `VeraSdkEmbeddingCache.ets` и `tools/build-sdk-embeddings.py`. `FORMAT_VERSION`
   поднят до 4: заголовок кэша хэширует только идентификаторы и модель, не текст,
   поэтому без этого старый кэш на телефоне остался бы «валидным».
4. **Токенный поиск** учитывает слова и описания, и summary.
5. **Модель получает summary** в поле `description` ответа `find_sdk_function`, а
   кандидатов теперь 16 вместо 8 (`SDK_SEARCH_LIMIT`).
6. **Поиск больше не смотрит на реализацию.** Убраны `IMPLEMENTED_BONUS`,
   `sdkImplementedMask`, параметр `implBonus`, поле `implemented` в выдаче и фраза
   в описании инструмента «prefer implemented=true». Правило проекта: есть ли у
   цели адаптер, не сигнал релевантности, а ответ «sdk.call is not implemented
   yet» — приемлемый результат.
7. **Промпт** (`vera-skill.txt`): убраны конкретные примеры целей
   (`PlayMusicList`, календарь, фонарик) в пользу шаблонов, и фраза «there is no
   audio, no navigation…», из-за которой модель решала, что звука нет и не искала.

Стоимость summary: 8 486 публичных функций — $0,43 (5,5 мин), ещё 3 198
системных — $0,17 (3 мин); всего ~$0,60, ~1 950 запросов (с пробой и дозапросом), без сбоев.

## Результаты

Метрики: R@k — доля запросов, у которых функция с оценкой 2 попала в первые k
различных функций. Эталоны: `entry/src/main/resources/rawfile/sdk-selection-gold.json`
(32 случая, 21 с gold) и `docs/prompts/sdk-gold-50.json` (50 случаев).

### 50 разных потребностей (основной результат)

`tools/sdk-gold-host.py`, векторы, которые лежат в приложении:

| k | было (описание) | стало (summary, 1 запись на функцию) |
|--:|--:|--:|
| 1 | 0,20 | 0,38 |
| 3 | 0,42 | 0,70 |
| 8 | 0,62 | 0,84 |
| **16** | **0,68** | **0,92** |
| 32 | 0,80 | 0,94 |

MRR 0,34 → 0,56. Построчно: `results/sdk-gold50-now-2026-10-07.json` и
`results/sdk-gold50-baseline-description-2026-10-07.json`.

Промахи на 16 кандидатах (4 из 50):

- «lock the screen orientation to landscape» — `Window.setPreferredOrientation` на
  28-м месте; выше стоят `screen.setScreenRotationLocked`, `Screen.setOrientation`.
- «get the screen width, height and pixel density» — `display.getDefaultDisplaySync`
  не найден даже в топ-32.
- «find out whether the phone is on Wi-Fi or mobile data» — получены
  `wifi.isConnected` и функции состояния мобильных данных, а не
  `connection.getDefaultNet` / `getNetCapabilities`.
- «store a small setting persistently» — получены `Preferences.put`, `Storage.put`;
  gold засчитывает только `preferences.getPreferences`. По существу ответ разумный,
  gold здесь строгий.

Как это устроено: потребности (`need`) написаны до того, как смотрели результаты
поиска; эталон подобран по именам функций в SDK и по документации, а не по
выдаче нашего поиска. Все ключи есть в индексе; оценка 2 нигде не стоит у
системных и устаревших функций.

### Исходный gold (21 запрос с gold)

R@k по векторам из приложения: R@1 0,29, R@3 0,48, R@8 0,62, R@12 0,67, R@16 0,76.

На устройстве, режим без бонуса, 19 общих запросов:

| | R@1 | R@3 | R@8 | MRR |
|---|--:|--:|--:|--:|
| описание (исходный) | 0,16 | 0,26 | 0,42 | 0,23 |
| summary, одна запись на функцию | 0,32 | 0,47 | 0,63 | 0,41 |

Токенный режим без бонуса: R@1 0,11 → 0,16, R@8 0,16 → 0,21.

### Что дал каждый шаг (оффлайн-стенд, `tools/sdk-search-lab.py`)

Варианты текста эмбеддинга, 21 запрос, полный корпус 16 511:

| вариант | R@1 | R@3 | R@8 | MRR |
|---|--:|--:|--:|--:|
| `desc` (исходный) | 0,14 | 0,24 | 0,33 | 0,22 |
| `summary` | 0,29 | 0,48 | 0,52 | 0,39 |
| `both` (описание + summary) | 0,19 | 0,29 | 0,62 | 0,30 |

`summary` лучше по верху выдачи, `both` чаще держит нужное в топ-8. Выбрана
`summary`: лучший верх выдачи и оба аудио-запроса (`a01`, `a02`) решены лучше.

Склейка копий (R@8, 21 запрос): `desc` 0,33 → 0,48, `summary` 0,52 → 0,62.
Размер выдачи при склейке (`summary`): R@8 0,62, R@12 0,67, R@16 0,76.

### Что не помогло: контекст класса и параметров (вариант A)

Поля `scopeDoc` (описание класса) и `paramDoc` (описания параметров) добавлялись к
тексту эмбеддинга. На 19 запросах эффекта не было (токенный режим не изменился,
эмбеддинговый R@8 с бонусом 0,21 → 0,16), токенный поиск стал медленнее
(52,7 → 65,7 мс). Контекст класса одинаков у всех его методов, поднимает класс
целиком, но не отличает `write` от `start`. Скрипт оставлен с флагом
`--context-fields`, в поставляемый индекс поля не пишутся. Полная версия контекста
(вся проза, `@returns`, `@throws`, `@useinstead`) не проверялась.

### Время (`veraBenchmark` и лог eval)

- Эмбеддинговый вызов на новом индексе: 134 мс в среднем (запрос 97 мс + скан
  37 мс, 64 замера). Раньше 142,7 мс; скан быстрее, потому что корпус меньше.
- Токенный: замер 65,7 мс сделан на индексе с вариантом A; на итоговом индексе не
  перемерян.

Размер: `sdk-index.json` 6,5 МБ, `sdk-embeddings.bin` 35,9 МБ (было 50,7 МБ).

## Адаптеры и исправления, найденные по ходу

Эти правки не про поиск, а про то, что программа реально делает после него.

- **Фонарик.** Модель передаёт режим по-разному: `"ON"`, `"TorchMode.ON"`, `"1"`;
  `parseInt("ON")` давал `NaN`, камера получала 0, а адаптер отвечал `ok`.
  `torchModeFrom` понимает числа и имена, любое другое значение — ошибка.
- **Общая защита:** `paramInt` / `paramFloat` теперь бросают ошибку на нечисловом
  значении (`error: parameter mode must be an integer, got "OFF"`) вместо тихого 0.
  Правка и в генераторе `tools/generate-sdk-backend.py`.
- **Звук: `TonePlayer`.** Адаптер для `audio.createTonePlayer`, `TonePlayer.load`,
  `start`, `stop`, `release`: один экземпляр на приложение, тип тона числом или
  именем (по умолчанию бип), `load` перед каждым `start`.
- **Вибрация:** `vibrator.startVibration`, `vibrator.vibrate` (устаревший, его
  выбирает модель), `vibrator.stopVibration`. Объекты эффекта и атрибута строятся
  внутри из `duration` / `effectId` / `usage`. В манифест добавлено
  `ohos.permission.VIBRATE`, без него вызов не работает.
- Разбор enum-значений (`enumMemberName`) общий для фонарика, тонов и `usage`.

## Что остаётся открытым

- `AudioRenderer.write` по запросу про тон в топ-8 не попадает. Платформенный
  `TonePlayer` подходит под запрос не хуже, но gold для `a01` засчитывает только
  `write`. Gold не менялся после того, как был виден результат.
- Модель угадывает значения enum, потому что выдача поиска их не содержит.
  Адаптеры чинят по одному; системное решение — показывать допустимые значения
  параметров в результатах.
- Эталон 50 случаев — «чистые» потребности по одной возможности; модель
  формулирует небрежнее. Прогон на формулировках в стиле реальных запросов не
  делался.
- Логические ошибки сгенерированных программ (например, один флаг в роли и
  настройки, и текущего состояния, из-за чего фонарик переставал мигать)
  адаптерами не лечатся.
- Звук и вибрация проверены по логам сервисов (поток у аудиосервера, драйвер
  вибромотора), но не «на слух» и не «в руке».

## Воспроизведение

Экспортируйте `SDK_API_DIR` с путём к каталогу `interface/sdk-js/api` вашего
исходного дерева OpenHarmony SDK.

```bash
# summary (нужен ключ DeepSeek в ~/.deepseek-key; в репозиторий не попадает)
python3 tools/build-sdk-summaries.py --sdk-dir "${SDK_API_DIR:?Export SDK_API_DIR with the SDK API source directory}" \
    --out tools/sdk-summaries.json --include-system

# индекс (одна запись на функцию, с summary) и эмбеддинги
python3 tools/build-sdk-index.py --sdk-dir "${SDK_API_DIR:?Export SDK_API_DIR with the SDK API source directory}" \
    --summaries tools/sdk-summaries.json \
    --out entry/src/main/resources/rawfile/sdk-index.json
python3 tools/build-sdk-embeddings.py --model <embeddinggemma-300m-q4_k_m.gguf> \
    --llama-embedding entry/src/main/cpp/llama.cpp/build-host/bin/llama-embedding

# recall на 50 потребностях, без телефона
python3 tools/sdk-gold-host.py --gold docs/prompts/sdk-gold-50.json \
    --model <embeddinggemma-300m-q4_k_m.gguf> \
    --llama-embedding entry/src/main/cpp/llama.cpp/build-host/bin/llama-embedding

# сравнение вариантов текста эмбеддинга (оффлайн)
python3 tools/sdk-search-lab.py --summaries tools/sdk-summaries.json ...

# eval на телефоне (запускается со страницы Generate), потом скрипт оценки
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps veraSdkEval 1
hdc shell "hilog -x | grep VERA-SDKEVAL" > results/sdk-eval.log
python3 tools/eval-sdk-selection.py results/sdk-eval.log
```

Модель `embeddinggemma-300m-q4_k_m.gguf` лежит на телефоне в
`{filesDir}/models/` (скачивается приложением); для стенда её можно взять
оттуда `hdc file recv`.

## Файлы

- Инструменты: `tools/build-sdk-summaries.py`, `tools/sdk-search-lab.py`,
  `tools/sdk-gold-host.py`, `tools/eval-sdk-selection.py`;
  изменены `tools/build-sdk-index.py`, `tools/build-sdk-embeddings.py`,
  `tools/generate-sdk-backend.py`.
- Данные: `tools/sdk-summaries.json`, `docs/prompts/sdk-gold-50.json`,
  `docs/prompts/sdk-selection-gold.md`,
  `entry/src/main/resources/rawfile/sdk-selection-gold.json`.
- Логи и результаты: `results/sdk-eval-*.log`, `results/sdk-bench-*.log`,
  `results/sdk-gold50-*.json`.
