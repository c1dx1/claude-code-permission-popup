# Claude Code Permission Popup

Плагин Claude Code для macOS: когда Claude просит разрешение запустить команду или поменять файл,
в правом верхнем углу экрана выезжает карточка с кнопками **Запретить / Разрешить**.
Можно ответить, не переключаясь в Claude. Подробности — в [README плагина](plugins/permission-popup/README.md).

## Установка

Нужны macOS 13+ и доступ к этому репозиторию (он приватный, git должен уметь его клонировать,
например через `gh auth login`).

В Claude Code:

```
/plugin marketplace add c1dx1/claude-code-permission-popup
/plugin install permission-popup@claude-code-permission-popup
```

Или из терминала:

```bash
claude plugin marketplace add c1dx1/claude-code-permission-popup
claude plugin install permission-popup@claude-code-permission-popup
```

Обновление: `/plugin marketplace update claude-code-permission-popup`.

## Структура

- `.claude-plugin/marketplace.json` — маркетплейс с одним плагином
- `plugins/permission-popup/` — сам плагин: хук, исходники на Swift, собранное приложение
