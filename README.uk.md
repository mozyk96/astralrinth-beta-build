# AstralRinth Beta — локальний Rust-автоматизатор для Arch/CachyOS

Цей набір щодня перевіряє upstream AstralRinth `beta`, за потреби збирає універсальний x86-64 пакет, публікує GitHub Release та оновлює AUR `astralrinth-beta-bin`. GitHub Actions не запускається, платні runner-и й банківська картка не потрібні. Ноутбук має бути увімкнений та мати інтернет.

Основний процес-оркестратор написаний на Rust (`src/main.rs`). Він додає часові мітки, записує журнал у `state/publisher.log` і запускає скрипт, який виконує конкретні кроки upstream fetch/build/release/AUR. Компіляція програми AstralRinth використовує upstream toolchain через `mise` і кешує `node_modules`/Cargo target. Це пакет для Arch-сумісних `x86_64`, не для ARM.

## Одноразове встановлення

Потрібні `gh`, авторизація GitHub CLI, `git`, `rsync`, `cargo`/`rustc`, `makepkg`, `mise`, Python, `jq`, `curl`, `systemd` та зареєстрований у AUR публічний ключ, відповідний до `~/.ssh/astralrinth_beta_aur_ci_ed25519`. Приватний ключ ніколи не додається в Git.

1. Розпакуй ZIP у `~/Завантажене/astralrinth-build-kit`.
2. Відкрий fish та виконай одну команду:

```fish
fish ~/Завантажене/astralrinth-build-kit/bootstrap.fish
```

Bootstrap клонує `mozyk96/astralrinth-beta-build` у `~/astralrinth-beta-build` (або використає наявний checkout), перенесе файли з ZIP, збере Rust-програму, підготує systemd user timer, запушить зміни в GitHub і ввімкне таймер. Наявний `LICENSE`, PKGBUILD і `.SRCINFO` не перезаписуються під час копіювання; setup оновить метадані за потреби.

Якщо потрібні системні залежності відсутні, setup покаже помилку з назвою команди/пакета. Не вводь платіжні дані: вони не потрібні.

## Розклад і журнал

- Перша автоматична перевірка — приблизно через 10 хвилин після запуску user systemd manager.
- Далі — один раз на день за календарним розкладом systemd.
- `Persistent=true` дозволяє виконати пропущений календарний запуск, коли user manager знову активується.
- `loginctl enable-linger` вмикається setup-скриптом, якщо система це дозволяє. Якщо ні, виконай `sudo loginctl enable-linger "$USER"`, щоб user services могли працювати без активної графічної сесії.
- Під час вимкнення ноутбука збірка не відбувається.

Статус:

```fish
systemctl --user status astralrinth-beta-check.timer
systemctl --user list-timers astralrinth-beta-check.timer
```

Журнал systemd:

```fish
journalctl --user -u astralrinth-beta-check.service -n 150 --no-pager
```

Журнал Rust-оркестратора:

```fish
tail -n 100 ~/astralrinth-beta-build/state/publisher.log
```

Ручний запуск:

```fish
~/.local/bin/astralrinth-publisher --root "$HOME/astralrinth-beta-build"
```

Вимкнути автоматизацію:

```fish
systemctl --user disable --now astralrinth-beta-check.timer
```

## Після успішної публікації

```fish
paru -S astralrinth-beta-bin
# або yay -S astralrinth-beta-bin
```

Пакет встановлює `.desktop` launcher та іконку у стандартні системні каталоги, тому KDE Plasma може знаходити AstralRinth через меню пошуку. `paru`/`yay` встановлюють пакет, а інтеграцію меню визначають файли, які встановлює сам пакет.

## Важливо

Перший білд може бути довгим і навантажувати CPU. Успішність справжньої збірки не можна гарантувати до першого запуску на твоєму CachyOS: це середовище не має upstream build toolchain та доступу до твого GitHub/AUR облікового запису. Якщо щось падає, надішли помилку з `journalctl` і `state/publisher.log`.

Це неофіційне пакування. Ліцензія в корені репозиторію стосується власних скриптів і конфігурацій, а не AstralRinth, його брендингу чи сторонніх компонентів.

Upstream: https://git.xorison.dev/didirus/AstralRinth  
GitHub: https://github.com/mozyk96/astralrinth-beta-build  
AUR: https://aur.archlinux.org/packages/astralrinth-beta-bin
