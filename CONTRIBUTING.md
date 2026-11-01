# Contributing

Спасибо за интерес к проекту! Любой вклад приветствуется.

## Как помочь

| Способ | Что нужно |
|---|---|
| 🐛 Баг-репорт | [Создайте Issue](https://github.com/GlooMlK/mikrotik-geoip-vpn/issues/new?template=bug_report.md) |
| 💡 Идея | [Предложите фичу](https://github.com/GlooMlK/mikrotik-geoip-vpn/issues/new?template=feature_request.md) |
| 🔧 Код | Сделайте форк → внесите изменения → Pull Request |
| 📖 Документация | Исправьте опечатку, добавьте пример — PR приветствуется |
| ⭐ Звезда | Просто поставьте star — это помогает проекту |

## Правила для Pull Request

1. **Один PR = одна фича/фикс** — не смешивайте изменения
2. **Опишите что и зачем** — в комментарии к PR
3. **Проверьте на своём железе** — изменения должны быть протестированы
4. **Не включайте секреты** — IP, UUID, ключи, пароли

### Процесс

```bash
# 1. Форкните репозиторий на GitHub

# 2. Клонируйте свой форк
git clone git@github.com:ВАШ_ЛОГИН/mikrotik-geoip-vpn.git
cd mikrotik-geoip-vpn

# 3. Создайте ветку
git checkout -b feature/my-improvement

# 4. Внесите изменения, закоммитьте
git add .
git commit -m "Add: описание изменения"

# 5. Запушьте
git push origin feature/my-improvement

# 6. Откройте Pull Request на GitHub
```

## Стиль кода

- **YAML** — 2 пробела отступ, комментарии к блокам
- **RouterOS scripts** — комментарии к каждому блоку
- **Markdown** — таблицы для сравнений, code blocks для команд

## Что НЕ принимать в PR

- Секреты (UUID, ключи, IP ваших серверов)
- Изменения, ломающие обратную совместимость без обсуждения
- Ссылки на сторонние проприетарные сервисы
- Изменения лицензии

## Вопросы?

Создайте [Issue](https://github.com/GlooMlK/mikrotik-geoip-vpn/issues) с меткой `question`.
