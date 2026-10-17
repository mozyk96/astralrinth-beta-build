# AstralRinth Beta — Arch Linux build pipeline

Неофіційний пакувальний проєкт. Він перевіряє upstream-гілку `beta`, збирає AstralRinth у GitHub Actions і після успішної збірки публікує реліз у цьому GitHub-репозиторії та оновлює окремий пакет AUR `astralrinth-beta-bin`.

## Що буде встановлено

- `astralrinth-beta-bin` — бінарний пакет для Arch Linux та сумісних дистрибутивів, `x86_64`, з базовими інструкціями CPU (`x86-64`), без `native`.
- `AstralRinth (Beta)` у меню KDE Plasma: пакет постачає `/usr/share/applications/astralrinth-beta.desktop`, пошукові ключові слова Minecraft/Modrinth/AstralRinth та стабільне ім'я іконки `astralrinth-beta` у `/usr/share/pixmaps/`.
- GitHub Actions запускається після першого push у `main`, вручну та щочотири години (`17 */4 * * *`, UTC). Якщо upstream commit не змінився і реліз існує, збірка пропускається.
- Кожен реліз містить compressed rootfs payload, SHA-256 і manifest з upstream commit/версією.
- AUR отримує `PKGBUILD` і `.SRCINFO`, які вказують на GitHub Release. Сам AUR не зберігає бінарник.

**Неофіційний beta-білд.** Це не офіційний пакет AstralRinth. Оновлення beta можуть бути нестабільними.

## 1. Однією командою завантажити pipeline у GitHub

Потрібні CachyOS/Arch, `fish`, `git`, `curl`, `openssh`, `base-devel`, `python`, `unzip` та вже авторизований GitHub CLI. Перевір авторизацію:

```fish
gh auth status
```

Якщо ZIP уже лежить у `~/Downloads`, виконай з fish одну команду (вона розпакує набір і створить публічний GitHub-репозиторій):

```fish
cd ~/Downloads; and unzip -o astralrinth-build-kit.zip; and cd astralrinth-build-kit; and fish ./setup.fish
```

Назва репозиторію за замовчуванням `astralrinth-beta-build`; можна передати іншу: `fish ./setup.fish my-astralrinth-beta`. Репозиторій має бути публічним, бо PKGBUILD завантажує release asset без GitHub-токена.

Setup скрипт перевіряє доступність AUR package base `astralrinth-beta-bin`, підставляє власника/репозиторій у PKGBUILD, генерує `.SRCINFO`, пушить файли в GitHub і готує окремий SSH-ключ для публікації в AUR. Він не використовує personal SSH key і не робить force-push.

## 2. Один обов'язковий крок AUR

Автоматично від імені користувача додати SSH public key в AUR неможливо. Скрипт покаже **публічний** ключ і відкриє [AUR account settings](https://aur.archlinux.org/account/). Додай його в `My Account → SSH Public Keys`.

Для `known_hosts` скрипт використовує наявний локальний запис, якщо він у тебе вже є. Інакше він завантажує ключ через `ssh-keyscan` і показує відбиток; це trust-on-first-use, тому не підтверджуй його без незалежної перевірки. Не публікуй приватний ключ. Після реєстрації ключа підтверди запит у терміналі: приватний ключ і pinned `known_hosts` будуть додані як GitHub Actions secrets, а перший workflow запуститься вручну.

Якщо скрипт завершився до налаштування секретів, знову виконай `fish ./setup.fish` з цієї папки. Назву наявного GitHub-репозиторію скрипт зчитає з `origin` автоматично. Повторний запуск призначений бути безпечним: він не стирає локальні файли та не перезаписує GitHub історію. Якщо локальна й віддалена гілки розійшлися, він зупиниться, а не буде робити force-push.

## 3. Де дивитися збірку

У GitHub відкрий `Actions → Watch upstream beta and publish`. Перший запуск компілює джерела з конкретного upstream commit. Коли все пройде, у `Releases` з'явиться версійний tag, а workflow оновить рецепт AUR. Заплановані workflow можуть стартувати із затримкою; «кожні 4 години» не гарантує запуск рівно до секунди.

Публікувальний job має `contents: write`; інші jobs — тільки читання. Секрет AUR доступний лише публікувальному job і не передається коду AstralRinth під час компіляції.

## 4. Як встановити саму програму

Після того, як перший workflow завершився успішно і пакет уже є в AUR, у розпакованій папці виконай:

```fish
fish ./install.fish
```

Скрипт використовує `paru`, якщо він встановлений, інакше `yay`, а за їх відсутності — `git + makepkg`. Еквівалентно:

```fish
paru -S astralrinth-beta-bin
# або
 yay -S astralrinth-beta-bin
```

`paru`/`yay` не створюють іконки автоматично: вони встановлюють файли, визначені в `PKGBUILD`. Наш пакет включає `.desktop` entry та іконку в стандартних каталогах, тому KDE Plasma знаходить програму через пошук. Якщо меню не оновилось відразу:

```fish
kbuildsycoca6 --noincremental
```

Перевірка встановлених файлів:

```fish
pacman -Ql astralrinth-beta-bin | grep -E 'applications/|pixmaps/|icons/'
```

Пакет конфліктує з `astralrinth-bin` та `astralrinth-app-bin`, бо вони встановлюють ту саму програму. Видали інший пакет через `paru -R`/`yay -R` перед встановленням, якщо він уже стоїть.

## 5. Архітектура/межі

Збірка компілюється з `RUSTFLAGS='-C target-cpu=x86-64'` і `-march=x86-64 -mtune=generic`; це загальна база x86-64, а не оптимізація конкретно під ноутбук. ARM/aarch64 не підтримується цим пакетом. Збірка та встановлення націлені на Arch-подібну систему з `webkit2gtk-4.1` та іншими залежностями в PKGBUILD, а не на довільний Linux.

Пайплайн навмисно завершується помилкою, якщо upstream більше не створює `.deb`, launcher `.desktop`, виконуваний файл чи іконку. Це краще, ніж випустити пакет, що не запускається. До поширення перевір перший workflow, логи, контрольну суму й вміст release.

## Посилання

- Upstream: https://git.xorison.dev/didirus/AstralRinth
- AUR package після першої публікації: https://aur.archlinux.org/packages/astralrinth-beta-bin
- ArchWiki: [AUR submission guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines), [Desktop entries](https://wiki.archlinux.org/title/Desktop_entry)
