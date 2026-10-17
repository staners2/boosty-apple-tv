# Contributing

Keep changes focused and describe the user-visible result. Discuss changes to
pairing, session storage or the shared API before implementing them; the server
lives in [boosty-samsung-tv](https://github.com/staners2/boosty-samsung-tv).

Before opening a pull request:

1. Run `./scripts/test.sh` and `./scripts/build.sh simulator` with full Xcode.
2. For focus, navigation or player UI changes, run the simulator scenarios in
   [docs/development.md](docs/development.md).
3. Add regression tests and update both README languages when setup or controls
   change.
4. State Xcode/tvOS versions, passed and omitted checks, and whether a physical
   device was tested. A simulator pass does not prove production CDN behavior.

Edit `project.yml` and `scripts/generate-assets.swift`, not generated Xcode
projects or assets. Keep native tvOS focus and Back behavior. Do not add private
APIs, forced process termination or TLS bypasses.

Never include signing material, personal server addresses, phone numbers, session
data, active pairing QR codes or signed media URLs. See [SECURITY.md](SECURITY.md).

Русский: ошибки и PR можно писать на русском или английском. Опишите результат,
воспроизведение и реальные проверки; установка описана в [README.ru.md](README.ru.md).
