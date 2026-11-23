# MeetSpace для iPhone и iPad

MeetSpace — приложение для чатов, звонков и видеовстреч. Работает на iOS и iPadOS 18 и новее.

## Запуск в Xcode

1. Откройте `MeetSpace.xcodeproj` и выберите схему `MeetSpace-Debug`.
2. Выберите симулятор iPhone или iPad и нажмите **Run** (⌘R).
3. На первом экране нажмите «Подключиться к серверу» и введите HTTPS-адрес вашего MeetSpace. Для деморежима выберите «Посмотреть интерфейс».

## Пакет для Device Hub

Один ZIP подходит для симуляторов iPhone и iPad. Скачайте пакет, распакуйте его и перетащите `MeetSpace.app` в окно запущенного симулятора в Device Hub. [Готовые сборки](https://github.com/janickiy/meetspace_ios_mobile/releases)

Для сборки из текущего кода запустите **Run workflow** с вариантом `release-package` в поле **Test scope**. ZIP будет в артефакте `release-simulator`. [GitHub Actions](https://github.com/janickiy/meetspace_ios_mobile/actions/workflows/ios.yml)

[Документация проекта](https://github.com/janickiy/meetspace_ios_mobile/tree/main/docs)
