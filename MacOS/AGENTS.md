# AGENTS.md — Melon Tools (правила для агента)

## DMG и копии приложения (запомнено по просьбе пользователя)

1. **После установки из DMG — извлекай том (⏏).**
   Смонтированный образ = ещё одна «копия» приложения для macOS: LaunchServices
   регистрирует его и дёргает кэш иконок. Установил → `hdiutil detach /Volumes/…`.

2. **Старые DMG не открывать** (`MelonTools-1.4.0.dmg` и старше).
   Внутри — старые версии со старой иконкой; они дёргают кэш иконок и плодят
   «копии» в Launchpad/Spotlight. Если пользователь просит — удалять из
   `/Volumes/Z Slim/MelonTools/` (пользователь разрешил удалять по запросу).

3. **«Отставшая» иконка = кэш IconServices.**
   Лечение: `touch "/Applications/Melon Tools.app" && killall Dock && killall Finder`.
   Плюс пользовательский кэш: `~/Library/Caches/com.apple.iconservices*`.

## Памятка по чистке (если симптомы вернулись)

Призраки живут в базе LaunchServices. Проверка:
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | grep -i melon`.
Все пути кроме `/Applications/Melon Tools.app` — снимать: `lsregister -u <путь>`.

## Операционные заметки этой сессии (кратко)

- Тесты: `xcodebuild -project app/MelonTools.xcodeproj -scheme MelonTools -configuration Debug -derivedDataPath "$HOME/Library/Developer/MelonTools" test` (12 тестов).
- Полная сборка: `./build.sh` (версия читается из `app/project.yml`, DMG → копия в delivery).
- Установка на мак: ditto из Release-build в `/Applications/Melon Tools.app` + `xattr -dr com.apple.quarantine`.
- Запущенный процесс: путь содержит пробел (`Melon Tools.app`) — обычный `pgrep MelonTools` не находит; искать паттерн `Tools.app/Contents/MacOS/MelonTools`.
