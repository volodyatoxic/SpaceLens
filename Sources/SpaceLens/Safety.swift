import SwiftUI

/// Оценка риска удаления. Порядок важен: protected — нельзя удалить вообще.
enum Risk: Int {
    case protected, caution, unknown, safe

    var title: String {
        switch self {
        case .protected: "Защищено"
        case .caution: "Проверьте перед удалением"
        case .unknown: "Решать вам"
        case .safe: "Можно удалить"
        }
    }
    var short: String {
        switch self {
        case .protected: "Защищено"
        case .caution: "Осторожно"
        case .unknown: "Не определено"
        case .safe: "Безопасно"
        }
    }
    var color: Color {
        switch self {
        case .protected: .red
        case .caution: .orange
        case .unknown: Color(white: 0.5)
        case .safe: .green
        }
    }
    var symbol: String {
        switch self {
        case .protected: "lock.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        case .safe: "checkmark.shield.fill"
        }
    }
}

struct Verdict {
    let risk: Risk
    let category: String
    let reason: String
    var canTrash: Bool { risk != .protected }
}

/// Локальные правила безопасности. ИИ может только *понизить* оценку, но никогда не повысить
/// до «защищено → удаляемо». Финальная проверка выполняется ещё раз прямо перед удалением.
final class Safety: @unchecked Sendable {
    static let shared = Safety()
    private let lock = NSLock()
    private var cache: [String: Verdict] = [:]
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    func verdict(for node: FileNode) -> Verdict {
        let key = node.isAggregate ? node.path + "#agg" : node.path
        lock.lock()
        if let v = cache[key] { lock.unlock(); return v }
        lock.unlock()
        let v = compute(node)
        lock.lock(); cache[key] = v; lock.unlock()
        return v
    }

    private func V(_ r: Risk, _ c: String, _ why: String) -> Verdict { Verdict(risk: r, category: c, reason: why) }
    private func under(_ rel: String, _ prefix: String) -> Bool { rel == prefix || rel.hasPrefix(prefix + "/") }

    // MARK: таблицы

    private let protectedHome: [(String, String, String)] = [
        ("Library/Keychains", "Пароли", "Связка ключей: здесь хранятся ваши пароли и сертификаты."),
        ("Library/Mobile Documents", "iCloud Drive", "Синхронизируется с iCloud — удаление пропадёт и в облаке и на других устройствах."),
        ("Library/Preferences", "Настройки", "Настройки всех приложений."),
        ("Library/Mail", "Почта", "Локальная почта и вложения."),
        ("Library/Messages", "Сообщения", "История iMessage и вложения."),
        ("Library/Safari", "Safari", "Закладки, история и данные Safari."),
        ("Library/Cookies", "Cookies", "Сессии и входы на сайтах."),
        ("Library/Accounts", "Аккаунты", "Учётные записи системы."),
        ("Library/Calendars", "Календарь", "Локальные календари."),
        ("Library/Group Containers", "Данные приложений", "Общие данные приложений (Заметки, мессенджеры и т. д.)."),
        ("Library/Application Support/AddressBook", "Контакты", "Адресная книга."),
        ("Library/Application Support/CloudDocs", "iCloud", "Служебные данные iCloud."),
        (".ssh", "Ключи", "SSH-ключи: без них потеряете доступ к серверам и репозиториям."),
        (".gnupg", "Ключи", "GPG-ключи."),
        (".aws", "Ключи", "Доступы AWS."),
        (".kube", "Ключи", "Доступы Kubernetes."),
        (".zshrc", "Настройки оболочки", "Конфигурация терминала."),
        (".zprofile", "Настройки оболочки", "Конфигурация терминала."),
        (".zshenv", "Настройки оболочки", "Конфигурация терминала."),
        (".bash_profile", "Настройки оболочки", "Конфигурация терминала."),
        (".bashrc", "Настройки оболочки", "Конфигурация терминала."),
        (".gitconfig", "Настройки Git", "Глобальная конфигурация Git."),
        (".netrc", "Ключи", "Сохранённые логины/пароли для CLI."),
    ]

    private let standardFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications", "Sites",
    ]

    private let devCachesSafe: [(String, String)] = [
        (".npm", "Кэш npm"), (".pnpm-store", "Кэш pnpm"), (".cocoapods", "Кэш CocoaPods"),
        (".gradle/caches", "Кэш Gradle"), (".cargo/registry", "Кэш Cargo"), (".bun/install/cache", "Кэш Bun"),
        (".yarn/cache", "Кэш Yarn"), ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "Xcode DeviceSupport"),
        ("Library/Developer/CoreSimulator/Caches", "Кэш симуляторов"),
        ("Library/Saved Application State", "Сохранённое состояние окон"),
        ("Library/HTTPStorages", "HTTP-кэш"),
    ]

    private let devToolsCaution: [(String, String)] = [
        (".rustup", "Тулчейн Rust"), (".nvm", "Версии Node"), (".pyenv", "Версии Python"),
        (".rbenv", "Версии Ruby"), (".conda", "Conda"), (".docker", "Docker"),
        (".ollama", "Модели Ollama"), (".claude", "Данные Claude Code"), (".codex", "Данные Codex"),
        (".gemini", "Данные Gemini CLI"), (".cargo", "Cargo"), (".gradle", "Gradle"), (".cache", "Кэши CLI"),
    ]

    private let artifactSafe: [String: (String, String)] = [
        "node_modules": ("Зависимости", "Восстанавливаются командой npm/pnpm/yarn install."),
        "__pycache__": ("Кэш Python", "Python пересоздаст при запуске."),
        ".pytest_cache": ("Кэш тестов", "Пересоздаётся при запуске тестов."),
        ".mypy_cache": ("Кэш mypy", "Пересоздаётся автоматически."),
        ".ruff_cache": ("Кэш ruff", "Пересоздаётся автоматически."),
        ".next": ("Сборка Next.js", "Пересоздаётся командой dev/build."),
        ".nuxt": ("Сборка Nuxt", "Пересоздаётся командой dev/build."),
        ".turbo": ("Кэш Turborepo", "Пересоздаётся автоматически."),
        ".parcel-cache": ("Кэш Parcel", "Пересоздаётся автоматически."),
        ".svelte-kit": ("Сборка SvelteKit", "Пересоздаётся командой dev/build."),
        "DerivedData": ("Xcode DerivedData", "Xcode пересоберёт проект (первая сборка будет дольше)."),
        "Pods": ("CocoaPods", "Восстанавливается командой pod install."),
        ".build": ("Сборка SwiftPM", "Пересоздаётся командой swift build."),
        ".tox": ("Окружения tox", "Пересоздаются автоматически."),
    ]

    private let fileExtRules: [String: (Risk, String, String)] = [
        "log": (.safe, "Лог", "Журнал работы программы — обычно не нужен."),
        "ipsw": (.safe, "Прошивка Apple", "Образ прошивки: при необходимости скачивается заново."),
        "dmg": (.caution, "Установщик", "Установочный образ. Если приложение уже установлено — можно удалить; скачать можно заново."),
        "pkg": (.caution, "Установщик", "Установочный пакет. Можно скачать заново."),
        "iso": (.caution, "Образ диска", "Проверьте, что он вам больше не нужен."),
        "xcarchive": (.caution, "Архив Xcode", "Архив сборки для App Store/TestFlight — убедитесь, что релиз уже опубликован."),
        "vmdk": (.caution, "Виртуальная машина", "Диск ВМ может содержать единственную копию данных."),
        "vdi": (.caution, "Виртуальная машина", "Диск ВМ может содержать единственную копию данных."),
        "qcow2": (.caution, "Виртуальная машина", "Диск ВМ может содержать единственную копию данных."),
        "vhd": (.caution, "Виртуальная машина", "Диск ВМ может содержать единственную копию данных."),
        "vhdx": (.caution, "Виртуальная машина", "Диск ВМ может содержать единственную копию данных."),
        "utm": (.caution, "Виртуальная машина", "ВМ может содержать единственную копию данных."),
        "pvm": (.caution, "Виртуальная машина", "ВМ Parallels может содержать единственную копию данных."),
        "vmwarevm": (.caution, "Виртуальная машина", "ВМ VMware может содержать единственную копию данных."),
        "sqlite": (.caution, "База данных", "База данных приложения — удаление приведёт к потере данных."),
        "sqlite3": (.caution, "База данных", "База данных приложения — удаление приведёт к потере данных."),
        "db": (.caution, "База данных", "База данных приложения — удаление приведёт к потере данных."),
        "pem": (.protected, "Ключ", "Ключ или сертификат."),
        "p12": (.protected, "Ключ", "Ключ или сертификат."),
        "pfx": (.protected, "Ключ", "Ключ или сертификат."),
        "ppk": (.protected, "Ключ", "Ключ или сертификат."),
        "keychain": (.protected, "Ключ", "Связка ключей."),
        "keychain-db": (.protected, "Ключ", "Связка ключей."),
        "photoslibrary": (.protected, "Медиатека Фото", "Управляется приложением «Фото» — удаляйте снимки через него."),
        "musiclibrary": (.protected, "Медиатека Музыки", "Управляется приложением «Музыка»."),
        "tvlibrary": (.protected, "Медиатека TV", "Управляется приложением TV."),
        "zip": (.unknown, "Архив", "Архив: проверьте содержимое, прежде чем удалять."),
    ]

    // MARK: вычисление

    private func compute(_ node: FileNode) -> Verdict {
        if node.isAggregate {
            return V(.protected, "Группа", "Это набор мелких файлов, а не отдельный элемент. Откройте папку, чтобы увидеть их.")
        }
        let p = node.path
        let last = node.url.lastPathComponent
        let ext = node.url.pathExtension.lowercased()
        let inHome = p == home || p.hasPrefix(home + "/")

        if !inHome {
            if p.hasPrefix("/Volumes/") {
                let rest = p.dropFirst("/Volumes/".count)
                if !rest.contains("/") { return V(.protected, "Том", "Корень подключённого тома.") }
            } else if p.hasPrefix("/Applications/") {
                let rest = p.dropFirst("/Applications/".count)
                if !rest.contains("/") {
                    return V(.caution, "Приложение",
                             "Удаление приложения. Его данные в ~/Library останутся. Платные приложения придётся покупать/активировать заново.")
                }
                return V(.protected, "Внутри приложения", "Файл внутри пакета приложения. Удаляйте приложение целиком, а не его части.")
            } else {
                return V(.protected, "Система", "Системная или общая папка macOS. Удаление может сломать систему.")
            }
        }

        var rel = ""
        if inHome {
            rel = p == home ? "" : String(p.dropFirst(home.count + 1))
            if rel.isEmpty { return V(.protected, "Домашняя папка", "Ваша домашняя папка целиком.") }
            for (prefix, cat, why) in protectedHome where under(rel, prefix) {
                return V(.protected, cat, why)
            }
            if under(rel, ".Trash") {
                return V(.protected, "Корзина", "Уже в Корзине. Очистите её через Finder, чтобы освободить место.")
            }
            if rel == "Library/CloudStorage" { return V(.protected, "Облако", "Папка облачных хранилищ.") }
            if under(rel, "Library/CloudStorage") || under(rel, "Dropbox") || under(rel, "Google Drive")
                || under(rel, "OneDrive") || under(rel, "Yandex.Disk.localized") {
                return V(.caution, "Облако", "Синхронизируемая папка: удаление исчезнет и в облаке, и на других ваших устройствах.")
            }
            if !rel.contains("/") && standardFolders.contains(rel) {
                return V(.protected, "Стандартная папка macOS", "Саму папку удалять нельзя — но можно чистить её содержимое.")
            }
            if rel == "Library" { return V(.protected, "Данные пользователя", "Папка ~/Library: настройки и данные всех ваших приложений.") }
        }

        // Git: никогда не режем историю репозитория
        if p.split(separator: "/").contains(".git") {
            return V(.protected, "История Git", "История репозитория. Если нужно удалить проект — делайте это осознанно, целиком, через Finder.")
        }

        if inHome {
            for (prefix, why) in devCachesSafe where under(rel, prefix) {
                return V(.safe, "Кэш", "\(why): создаётся заново при необходимости.")
            }
            if under(rel, "Library/Caches") {
                if rel == "Library/Caches" {
                    return V(.caution, "Кэши", "Все кэши сразу. Лучше удалять подпапки по одной, начиная с самых больших.")
                }
                return V(.safe, "Кэш", "Кэш приложения: оно создаст его заново. Возможна повторная загрузка данных при следующем запуске.")
            }
            if under(rel, "Library/Logs") {
                return rel == "Library/Logs"
                    ? V(.caution, "Логи", "Папка журналов.")
                    : V(.safe, "Логи", "Журналы работы приложений и системы — не нужны для работы.")
            }
            if under(rel, "Library/Application Support/MobileSync") {
                return V(.caution, "Бэкапы iPhone", "Резервные копии устройств. Если телефон потеряется — это может быть единственная копия.")
            }
            if rel == "Library/Application Support" {
                return V(.protected, "Данные приложений", "Папка с данными всех приложений. Работайте с её подпапками по отдельности.")
            }
            if under(rel, "Library/Application Support") {
                return V(.caution, "Данные приложения", "Настройки, базы, лицензии и сохранения приложения. Если приложение удалено — можно чистить.")
            }
            if rel == "Library/Containers" { return V(.protected, "Данные приложений", "Песочницы приложений.") }
            if under(rel, "Library/Containers/com.docker.docker") {
                return V(.caution, "Docker", "Образы и тома Docker: можно очистить из самого Docker (docker system prune).")
            }
            if under(rel, "Library/Containers") {
                return V(.caution, "Данные приложения", "Данные приложения из песочницы.")
            }
            if under(rel, "Library/Developer/Xcode/Archives") {
                return V(.caution, "Архивы Xcode", "Архивы релизов. Нужны для символикации крэшей опубликованных версий.")
            }
            if under(rel, "Library/Developer/CoreSimulator") {
                return V(.caution, "Симуляторы", "Данные симуляторов iOS. Лучше чистить через `xcrun simctl delete unavailable`.")
            }
            for (prefix, why) in devToolsCaution where under(rel, prefix) {
                return V(.caution, "Инструменты разработки", "\(why): удаление сбросит установленные версии/данные.")
            }
            if under(rel, "Library") {
                return V(.caution, "Данные пользователя", "Служебные данные приложений и системы.")
            }
        }

        // Универсальные правила по имени — работают в любом месте (в т. ч. внешние диски)
        let comps = p.split(separator: "/").map(String.init)
        for c in comps {
            if let a = artifactSafe[c] { return V(.safe, a.0, a.1) }
        }
        if last == "target" {
            let sib = node.url.deletingLastPathComponent().path
            if FileManager.default.fileExists(atPath: sib + "/Cargo.toml") {
                return V(.safe, "Сборка Rust", "Пересоздаётся командой cargo build.")
            }
        }
        if ["build", "dist", "out"].contains(last) && node.isDir {
            return V(.caution, "Результат сборки", "Обычно пересоздаётся сборкой, но проверьте, что это не нужный вам релиз.")
        }
        if ["venv", ".venv"].contains(last) {
            return V(.caution, "Окружение Python", "Создаётся заново из requirements/pyproject, если они есть в проекте.")
        }
        if comps.contains(where: { $0 == "venv" || $0 == ".venv" }) {
            return V(.caution, "Окружение Python", "Внутри виртуального окружения Python.")
        }
        if last == ".DS_Store" { return V(.safe, "Служебный файл", "Служебный файл Finder.") }
        if last.hasPrefix(".env") { return V(.caution, "Конфиг/секреты", "Может содержать ключи и пароли проекта.") }
        if !node.isDir, let r = fileExtRules[ext] { return V(r.0, r.1, r.2) }
        if node.isDir, let r = fileExtRules[ext], r.0 == .protected || r.0 == .caution { return V(r.0, r.1, r.2) }

        if inHome {
            for personal in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] where under(rel, personal) {
                return V(.unknown, "Личные файлы", "Ваши данные: программа не знает, нужны ли они. Решение за вами.")
            }
        }
        return V(.unknown, "Не определено", "Нет известных правил для этого элемента. Проверьте содержимое.")
    }
}
