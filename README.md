# Xor::Filter

XOR‑фильтр с динамическими обновлениями (add/remove), неизменяемыми снапшотами, персистентностью и потокобезопасный. Базовая структура — классический XOR‑фильтр. Динамика достигается за счёт буферизации изменений и периодического ребилда базового снимка.

## Установка

Добавьте гем в Gemfile приложения командой:

    $ bundle add xor

Если вы не используете Bundler, установите гем так:

    $ gem install xor

## Использование

```ruby
require 'xor'

# Создание фильтра. Опции:
# - capacity: размер
# - fingerprint_bits: 4..16 (по умолчанию 8)
# - auto_rebuild: true/false (по умолчанию true)
filter = Xor::Filter.new(capacity: 10_000, fingerprint_bits: 8)

filter.add('bar')
filter.add_all(%w[foo baz])
filter.remove('baz')

filter.include?('bar') # => true
filter.include?('baz') # => false (после удаления)

# Сохранение на диск
filter.save('xor.bin')

# Загрузка с диска
loaded = Xor::Filter.load('xor.bin')
loaded.include?('bar') # => true

# Для тяжёлых батчей можно отключить авто‑ребилд и уплотнять вручную
filter = Xor::Filter.new(auto_rebuild: false)
filter.add_all(huge_array)
filter.remove_all(other_array)
filter.compact!
```

### Потокобезопасность и производительность

- Чтения без блокировок работают на неизменяемых снапшотах.
- Записи (add/remove) сериализуются под `Mutex`; пакетные `add_all`/`remove_all` уменьшают конкуренцию. Под нагрузкой предпочитайте батчи.
- Вероятность ложноположительного ответа определяется `fingerprint_bits` (≈ 2^{-fp_bits}). Например, 8 бит ≈ 0.39%.

## Разработка

После клонирования репозитория выполните `bin/setup` для установки зависимостей. Затем запустите тесты `rake test`. Также доступна интерактивная консоль `bin/console` для экспериментов.

Для локальной установки гема используйте `bundle exec rake install`. Для релиза новой версии обновите номер в `version.rb` и выполните `bundle exec rake release` (создаст git‑тег, запушит коммиты и опубликует `.gem` на [rubygems.org](https://rubygems.org)).

### Запуск тестов

```bash
bundle install
bundle exec rake test
```

## Бенчмарк

Пример прогона (ваши результаты зависят от CPU/ОС):

```bash
bin/bench
```

Пример вывода:

```text
Config: keys=500.00k read_threads=8 write_threads=2 duration=10s batch=10000 fp_bits=8 mode=mixed
Generating keys...
Building filter (bulk, no auto rebuild)...
Filter built. size=500000
Running benchmark...
Elapsed: 10.94s
Read ops:  1.20M (109.56k/s)
Write ops: 370.00k (33.82k/s)
Membership spot-check: present=true miss=false
```

Как повторить и варьировать параметры:

```bash
# только чтение
MODE=read READ_THREADS=16 TOTAL_KEYS=1000000 bin/bench

# смешанная нагрузка
TOTAL_KEYS=2000000 READ_THREADS=16 WRITE_THREADS=4 DURATION_S=20 FP_BITS=8 MODE=mixed bin/bench
```

## Вклад

Сообщения об ошибках и pull‑request’ы приветствуются в GitHub: https://github.com/creadone/xor.

## Лицензия

Гем доступен как open‑source на условиях [MIT License](https://opensource.org/licenses/MIT).
