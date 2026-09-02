# Приложение

`FitTrack.xcodeproj` создаётся в Xcode вручную (в этом окружении Xcode нет,
только Command Line Tools, поэтому проект не сгенерирован).

Что должно быть в проекте при создании:

- таргет `FitTrack`, iOS 17.0, Swift 6, strict concurrency
- таргет `FitTrackTimerWidget` (Widget Extension) — Live Activity таймера
  отдыха (SPEC §13.3)
- локальные пакеты: `Packages/FitCore`, `Packages/FitContent`, `Packages/FitData`
- capabilities: Sign in with Apple, Push (для Live Activity), Background Modes
- локализация — только `ru`

Каталоги `FitTrack/` уже разложены по структуре из плана: `App`, `Features/*`,
`DesignSystem`, `Localization`, `Resources`.
