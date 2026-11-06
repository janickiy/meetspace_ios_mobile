# Проверка контраста двух подписей календаря — CI3 / iPad18

**Область вывода: только `calendar.weekday.0` («Пн») и `calendar.weekday.4` («Пт») на указанном снимке.** Обе подписи полностью видны, без перекрытия панелями или отсечения scroll viewport. Внутри штрихов фактически присутствуют исходные foreground colors; их контраст с фактическим фоном равен 13,972:1 и 5,271:1. Это основание для двух узких reviewed exceptions, а не прохождение всего contrast-аудита.

Проверка выполнена 2026-11-06. CI run: [42240106296](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42240106296), source commit `586bfe875355f930a5d463214bd7860a78ac189e`. Устройство симулятора: iPad mini (A17 Pro), iPadOS 18. Проверяемый normal-size кадр: XCTest attachment `762282FB-8872-4286-822B-19A5FF4A5E32.png`, исходное имя `stage08-accessibility-calendar_0_5E9DC290-6D7A-4F01-BD1C-172C72E6C86C.png`.

[Копия полного PNG без изменений](evidence/accessibility-attempt03/iPad18-calendar-normal.png), 1488×2266 px, 744×1133 pt, scale2, профиль `sRGB IEC61966-2.1`. SHA-256:

```text
d436a64875627feee78d9b7e36bd1cd8d953bf3cd7fac5dc23c9c3f235427328
```

## Исходные замечания и результаты

[Raw JSON двух замечаний](evidence/accessibility-attempt03/iPad18-weekday-raw-issues.json) сохранён без изменения полей. Для обоих `screen=calendar`, `type=1` (contrast). `Пн` получил `Contrast nearly passed`, `Пт` — `Contrast failed`. Это результат Apple audit, который сохранён отдельно от нашей интерпретации.

| Параметр | Пн | Пт |
| --- | --- | --- |
| ID | `calendar.weekday.0` | `calendar.weekday.4` |
| Raw frame `(x,y,w,h)`, pt | `(49.25,379.25,13.5,12.5)` | `(285.75,379.25,12.5,12.5)` |
| Sample bounds `(minX,minY,maxX,maxY)`, px, max exclusive | `(98,758,126,784)` | `(571,758,597,784)` |
| Исходный font | Inter Regular10, `.body` | Inter Regular10, `.body` |
| Состояние | Не выбран | Выбран |
| Foreground RGB / hex | `(41,43,59)` / `#292b3b` | `(255,255,255)` / `#ffffff` |
| Background RGB / hex | `(255,255,255)` / `#ffffff` | `(93,95,205)` / `#5d5fcd` |
| Число пикселей, точно равных foreground | 53 | 47 |
| Число пикселей, точно равных background | 550 | 518 |
| Пикселей с контрастом ≥4,5:1 к этому фону | 100 | 55 |
| Контраст исходной пары, без округления при сравнении | 13.972171951774728 | 5.2712558308611674 |
| Максимальный наблюдаемый контраст в PNG | 13.972171951774728 | 5.2712558308611674 |

Foreground/background совпадают с `MSTheme.ink/surface/accent` в исходниках CI3. Максимальный наблюдаемый контраст совпал с исходной парой, потому что PNG содержит десятки пикселей полного foreground color, а не только бледные края сглаживания. На полном изображении обе двухбуквенные подписи читаемы; они находятся внутри соответствующих белой и фиолетовой карточек. Причину расхождения внутреннего эвристического анализа XCTest мы не установили; не выдаём предположение о его алгоритме за факт.

## Метод и воспроизведение

[Swift script](evidence/accessibility-attempt03/weekday-contrast.swift) использует только системные Foundation/AppKit/ImageIO/CryptoKit. Сначала проверяет SHA-256 исходного PNG, размер и формат RGB8. Затем умножает raw point bounds на2, округляет начало вниз, конец вверх и читает каждый RGB-пиксель через `NSBitmapImageRep.getPixel`. Изображение не масштабируется, не перекрашивается, не обрезается в сохранённой копии. Скрипт выводит полную histogram каждой области и результат в JSON.

Из корня репозитория:

```sh
xcrun swift docs/stage08/evidence/accessibility-attempt03/weekday-contrast.swift > /tmp/meetspace-weekday-contrast.json
cmp /tmp/meetspace-weekday-contrast.json docs/stage08/evidence/accessibility-attempt03/iPad18-weekday-pixel-contrast.json
```

[Сохранённый результат](evidence/accessibility-attempt03/iPad18-weekday-pixel-contrast.json) получен этим скриптом; [manifest SHA-256](evidence/accessibility-attempt03/weekday-contrast-manifest.json) связывает PNG, raw issues, script и JSON.

Расчёт использует sRGB linearization с порогом0,04045, `L=0.2126R+0.7152G+0.0722B`, затем `(Llighter+0.05)/(Ldarker+0.05)`. Для обычного текста сравнение выполняется с4,5 без округления. Метод относительной яркости приведён в [W3C G18](https://www.w3.org/WAI/WCAG22/Techniques/general/G18). W3C также различает исходные foreground/background colors и более светлые пиксели сглаживания: [Understanding SC1.4.3, примечание об anti-aliasing](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).

Histogram содержит и пиксели сглаживания с меньшим контрастом. Мы **не утверждаем**, что каждый пиксель каждого штриха имеет4,5:1, и не используем максимум как универсальный критерий проверки любого текста. Здесь он дополнительно подтверждает, что совпадающие с исходниками цвета реально присутствуют в центрах двух конкретных подписей. Пиксельный анализ не заменяет оценку читаемости с assistive technologies.

## Граница узкого исключения

Допустимое сопоставление: screen `calendar`, audit type `.contrast`, exact ID `calendar.weekday.0` + label «Пн» либо exact ID `calendar.weekday.4` + label «Пт», **полные bounds внутри видимого viewport и без перекрытия navbar/tabbar/горизонтальным scroll clip**. Исходный source-contrast check продолжает проверять используемые цветовые пары. При изменении цветов, состояния, label или геометрии нужен новый анализ; другие weekdays и другие типы ошибок этим результатом не разрешаются.

Это не blanket exclusion для calendar, `.contrast`, Inter10 или текста на фиолетовом фоне. Данные не относятся к iPad26, другим экранам, тёмной теме или частично видимым элементам. Изменение шрифта на12 semibold по этим двум результатам не требуется: подтверждённой проблемы цветов, отсутствия foreground pixels, обрезания или перекрытия на данном кадре нет.
