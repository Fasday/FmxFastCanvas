# FastCanvas для Delphi FireMonkey

FastCanvas заменяет канвас и 3D-контекст FireMonkey (FMX) на Windows собственным GPU-рендерером на Direct3D 11 или
Direct3D 12. Программа остаётся обычной FMX-программой: формы, контролы, стили, `TBitmap`, `TTextLayout`,
`TViewport3D`, `TForm3D` и эффекты работают как раньше; переключение — несколько строк перед `Application.Initialize`.

[English version](README.md)

- **Скорость.** Каждая фигура, глиф и картинка — один экземпляр instanced-отрисовки; сглаживание считается
  аналитически в пиксельном шейдере; текст берётся из атласа глифов; команды записываются в главном потоке и
  исполняются в потоке рендера. В 5–60 раз быстрее канваса FMX по умолчанию на фигурах, тексте и картинках, в 2–4 раза —
  на реальных формах.
- **Свои 3D-контексты** на том же устройстве: `TViewport3D` рисует прямо в форму на GPU, эффекты (тень, свечение,
  размытие) фильтруют битмапы, не покидая GPU, накладные расходы FMX на каждый вызов отрисовки исчезают.
- **Трассировка лучей** (Direct3D 12, DXR 1.1): тени, мягкие тени, ambient occlusion и отражения поверх любой 3D-сцены
  FMX, с её штатными материалами и источниками света; прикладные проходы лучей (свои compute- и пиксельные шейдеры над
  сценой).
- **Выглядит как FMX.** Текст сглаживается в оттенках серого с контрастом и гаммой DirectWrite, как его рисует
  Direct2D-канвас FMX (по желанию — ClearType, без сглаживания или как в Windows: `FastCanvasTextAntialias`); окна
  выводятся через DirectComposition, поэтому формы, нарисованные прозрачными поверх Mica или Acrylic, выглядят как со
  штатным канвасом.
- **HDR-вывод** (Direct3D 12) на HDR-мониторах, для форм и `TForm3D`: SDR-содержимое не меняется, 3D — ярче белого SDR
  (`DrawIntensity`: лампы, экраны, небо ярче белого без шейдеров; прикладные проходы лучей).
- **DLSS Super Resolution** (экспериментально; Direct3D 12, NVIDIA RTX, Win64): 3D-сцена `TForm3D` рисуется в
  уменьшенном размере и восстанавливается NVIDIA DLSS, 2D-панель поверх — в полном размере. Выигрыш — на тяжёлых
  сценах; на лёгких DLSS стоит дороже, чем экономит (около 0.9 мс на кадр при 2560 x 1400 на RTX 3090).
- **Надёжность.** Потеря устройства (обновление драйвера, сброс GPU) восстанавливается, битмапы сохраняют содержимое;
  частичная перерисовка на Direct3D 12; стресс-тесты и отладочный слой Direct3D 12 проходят чисто; при завершении
  ничего не утекает.

## Скорость

Время кадра одних и тех же сцен в окне 1920 x 1080 (мс, меньше — лучше; AMD Radeon RX 9070 XT, Ryzen 5 7500F).
`d2d` — канвас FMX по умолчанию; «лучший штатный» — самый быстрый в этой сцене из канвасов FMX Direct2D, GPU, GDI+,
Skia и Skia Vulkan.

| Сцена | FMX по умолчанию (`d2d`) | Лучший штатный | FastCanvas D3D11 | FastCanvas D3D12 |
|---|---:|---:|---:|---:|
| 16000 прямоугольников | 8.43 | 2.02 (`gpu`) | 1.54 | 1.43 |
| 250 строк, `FillText` | 7.84 | 5.19 (`gpu`) | 0.335 | 0.296 |
| 700 эллипсов | 7.42 | 6.52 (`skiavk`) | 0.130 | 0.131 |
| 330 путей | 7.40 | 5.03 (`skiavk`) | 0.518 | 0.520 |
| 11500 битмапов | 9.23 | 9.23 (`d2d`) | 1.27 | 1.27 |
| 190 контролов со стилями | 8.56 | 4.12 (`skiavk`) | 1.93 | 1.88 |
| 112 контролов с эффектами тени, свечения, размытия | 7.70 | 5.85 (`skiavk`) | 0.678 | 0.349 |
| `TListBox`, 4000 элементов, прокрутка | 6.43 | 5.47 (`skiavk`) | 2.68 | 2.29 |
| `TViewport3D`, 160 освещённых объектов | 8.53 | 7.64 (`skiavk`) | 0.562 | 0.519 |

Все 26 сцен, два размера, методика и стоимость трассировки лучей: [docs/BENCHMARKS.md](docs/BENCHMARKS.md)
(на английском). Программа замеров, её скрипты, сводки и каждый прогон (окружение, командная строка, статистика) лежат
в репозитории (`src/Bench`, `tools`, `results`): цифры можно проверить и перемерить на другой машине.

## Требования

- Delphi 13 (RAD Studio 37.0) или новее, FireMonkey, **Win64** или Win32 (Win64 быстрее на стороне процессора).
- Windows 10 или 11.
- GPU с уровнем Direct3D 10_0 для бэкенда Direct3D 11 (без видеокарты — WARP), 11_0 для Direct3D 12.
- Для трассировки лучей — DirectX Raytracing tier 1.1 (NVIDIA RTX 20 и новее, AMD RX 6000 и новее, Intel Arc); без
  него эффекты просто не рисуются.

## Подключение

Добавьте в пути поиска проекта две папки:

```
src\Canvas
third_party\delphidx12\src
```

и установите FastCanvas до `Application.Initialize`:

```pascal
program MyApp;

uses
  System.StartUpCopy,
  FMX.Forms,
  FastCanvas.Device,       // FastCanvasBackend
  FastCanvas.Canvas,       // InstallFastCanvas и настройки канваса
  FastCanvas.Context3D12,  // 3D-контекст Direct3D 12
  Main in 'Main.pas' {MainForm};

{$R *.res}

begin
  FastCanvasBackend := TFastCanvasBackend.D3D12;
  // По желанию: сглаживание текста, Grayscale (по умолчанию, как у FMX), ClearType, Aliased или System (как в Windows).
  FastCanvasTextAntialias := TFastTextAntialias.ClearType;
  InstallFastCanvas;
  InstallFastContext3D12;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
```

Для Direct3D 11 оставьте `FastCanvasBackend` по умолчанию и подключите `FastCanvas.Context3D11` /
`InstallFastContext3D11`: 3D-контекст должен быть того же API, что и канвас. Больше в программе ничего не меняется.

## Пример

В `example` два проекта RAD Studio, оба в группе `Examples.groupproj`. Все компоненты лежат на формах в дизайнере;
FastCanvas устанавливается в `.dpr`. В заголовке окна написано, чем оно рисуется.

- [HelloFastCanvas.dproj](example/HelloFastCanvas.dproj) — форма с анимированной 2D-графикой, кнопкой с эффектом тени,
  освещённым 3D-кубом над полом в `TViewport3D` и переключателем теней трассировкой лучей.
- [HelloForm3D.dproj](example/HelloForm3D.dproj) — `TForm3D`, всё окно — одна 3D-сцена: анимированные объекты на
  отражающем полу, лампа, качающаяся камера и панель (`TLayer3D` со штатными контролами), которая включает тени, мягкие
  тени, ambient occlusion и отражения трассировкой лучей, пол и HDR-вывод: на мониторе в режиме HDR лампа светит ярче
  белого SDR (`DrawIntensity`), остальное выглядит как в SDR; на картах NVIDIA RTX — DLSS Super Resolution
  (`nvngx_dlss.dll` из [DLSS SDK](https://github.com/NVIDIA/DLSS), положенный в `third_party\nvidia_dlss\bin\win64`,
  копируется к программе при сборке).

Откройте в RAD Studio `Examples.groupproj` (или один из проектов) и запустите: проекты собираются под Win64 (и Win32), пути
поиска (`..\src\Canvas;..\third_party\delphidx12\src`) уже прописаны. Из командной строки:

```
cd example
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
msbuild Examples.groupproj /p:Config=Release /p:Platform=Win64
```

(программы — в `example\Win64\Release`). Переменные окружения примеров: `FC_BACKEND=11` (Direct3D 11, без трассировки
лучей и HDR), `FC_PRESENT=flip` (вывод окон без DirectComposition), `FC_TEXT=cleartype|aliased|system`
(`HelloFastCanvas`: сглаживание текста), `FC_STOCK=1` (штатные канвас и 3D-контекст FMX для сравнения), `FC_HDR=force`
(`HelloForm3D`: HDR-вывод и на SDR-мониторе), `FC_DRED=0|1`, `FC_DLSS_JITTER`, `FC_DLSS_VIEW=input|motion`
(`HelloForm3D`: метки DRED и диагностика DLSS).

## Главные настройки

Глобальные переменные, задаются до `Application.Initialize`; все — в [docs/USAGE.md](docs/USAGE.md) (на английском).

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `FastCanvasBackend` | `D3D11` | API: `D3D11` или `D3D12` |
| `FastCanvasPresentation` | `Composition` | Вывод окон через DirectComposition (прозрачные места формы показывают то, что под окном, как у Direct2D-канваса FMX) или `Flip` (swap chain самого окна, непрозрачный); скорость одинаковая |
| `FastCanvasPartialFrames` | `True` | Direct3D 12: перерисовывать только изменившиеся прямоугольники |
| `FastCanvasRenderThread` | `True` | Исполнять команды в потоке рендера |
| `FastCanvasTextAntialias` | `Grayscale` | Сглаживание текста: `Grayscale` (как у Direct2D-канваса FMX), `ClearType` (субпиксельное, с настройками ClearType системы), `Aliased` (без сглаживания), `System` (как рисует Windows: ClearType, если он включён, без сглаживания, если выключено сглаживание шрифтов); можно менять во время работы |
| `FastCanvasHdr` (`FastCanvas.Hdr`) | `Off` | HDR-вывод окон на HDR-мониторах (`Auto`) |
| `FastContext3DRayTracing` (`FastCanvas.Context3D12`) | всё выключено | Тени, мягкие тени, ambient occlusion, отражения в 3D-сценах |
| `FastContext3DDlssMode` (`FastCanvas.Context3D12`) | `Off` | DLSS Super Resolution новых окон `TForm3D` (NVIDIA RTX); у контекста во время работы — `DlssMode` |

## Репозиторий

| Путь | Содержимое |
|---|---|
| `src/Canvas` | FastCanvas: канвас, рендерер, бэкенды Direct3D 11/12, 3D-контексты, шейдеры (HLSL и скомпилированные) |
| `third_party/delphidx12` | Заголовки Direct3D 12 / DXGI (DelphiDX12, Apache 2.0) |
| `example` | `HelloFastCanvas` и `HelloForm3D` — самые короткие проверки (проекты RAD Studio) |
| `docs` | [USAGE.md](docs/USAGE.md) (настройки, трассировка лучей, HDR, DLSS, потоки), [ARCHITECTURE.md](docs/ARCHITECTURE.md) (как устроено), [BENCHMARKS.md](docs/BENCHMARKS.md) — на английском |
| `src/Bench`, `src/Common` | Бенчмарк `FmxCanvasBench` (сцены, канвасы, замер) и вспомогательные модули |
| `results` | Сводки замеров (`.md`, `.csv`), в `raw` — каждый их прогон |
| `tools` | `run-bench.ps1`, `summarize-bench.ps1` и помощники: запуск и сводка бенчмарка; `compile-shaders.ps1`: HLSL в Pascal-включения (нужен только после изменения шейдеров) |
| `build.ps1`, `res` | Сборка бенчмарка из командной строки (dcc64) |

## Ограничения

- Только Windows (Win64 и Win32); нет канваса печати (`TPrinter`).
- ClearType (`FastCanvasTextAntialias`) — только в кадрах окон: текст в битмапах (эффекты, `TLayer3D`, `TForm3D`),
  в прозрачных формах и повёрнутый остаётся в оттенках серого.
- Частичная перерисовка и HDR-вывод — только на Direct3D 12; окна с HDR-выводом непрозрачны.
- Окна, выводящие кадры с tearing (`AllowTearing`), выводятся через `Flip`.
- Трассировка лучей не учитывает прозрачные объекты.
- DLSS: только окна `TForm3D`, без мультисэмплинга; векторы движения — только у непрозрачных объектов, которые движутся
  своими матрицами.

## Участники

- [Hemul GM](https://github.com/HemulGM): NVIDIA DLSS Super Resolution в 3D-контексте Direct3D 12 (`FastCanvas.Dlss`,
  `FastCanvas.Context3D12.Dlss.inc`, `Shaders\FastDlss.hlsl`, панель DLSS в `HelloForm3D`); первым проверил её на RTX 5080.

## Лицензия

MIT, см. [LICENSE](LICENSE). Сторонний код и формулы: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). FastCanvas не
содержит кода FireMonkey от Embarcadero; для сборки нужна лицензия Delphi.
