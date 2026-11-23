# MeetSpace для iPhone и iPad

MeetSpace — приложение для чатов, звонков и видеовстреч. Работает на iOS и iPadOS 18 и новее.

## Запуск в Xcode

1. Откройте `MeetSpace.xcodeproj` и выберите схему `MeetSpace-Debug`.
2. Выберите симулятор iPhone или iPad и нажмите **Run** (⌘R).
3. На первом экране нажмите «Подключиться к серверу» и введите HTTPS-адрес вашего MeetSpace. Для деморежима выберите «Посмотреть интерфейс».

## Пакет для Device Hub

Чтобы собрать ZIP из текущего кода, откройте [GitHub Actions](https://github.com/janickiy/meetspace_ios_mobile/actions/workflows/ios.yml), нажмите **Run workflow** и выберите `release-package` в поле **Test scope**.

Скачайте артефакт `release-simulator`, распакуйте вложенный ZIP для симулятора и перетащите `MeetSpace.app` в окно запущенного iPhone в Device Hub.

[Опубликованные сборки](https://github.com/janickiy/meetspace_ios_mobile/releases) · [Документация проекта](https://github.com/janickiy/meetspace_ios_mobile/tree/main/docs)
