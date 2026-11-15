# Пересборка движка AmneziaWG 3.1

Для обычной сборки MojaveRay Go не нужен. Обе версии моста включены в архив.
Команды ниже запускаются из папки `AmneziaWGBridge`.

```bash
# Intel: macOS 10.14.6 Mojave, 10.15 Catalina и 11 Big Sur, Go 1.20.14
GOTOOLCHAIN=local GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -mod=readonly -modfile=mojave.mod -trimpath -buildvcs=false -ldflags='-s -w' -o ../Vendor/bin/awg-bridge-mojave .
# Intel: macOS 12 Monterey и новее, Go 1.25.5
GOTOOLCHAIN=local GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w' -o ../Vendor/bin/awg-bridge .
```

Оба варианта используют amneziawg-go v3.1.20260828 (коммит
`b5928efb6ca19f0153958460c3d141f04abc5c2e`). В `upstream/` лежат
исходники для Go 1.20: новые языковые конструкции заменены эквивалентами,
порядок байтов зафиксирован для x86_64 и указаны версии зависимостей, которые
собираются с Go 1.20. Алгоритмы шифрования и формат пакетов не изменены.
Совместимая версия предназначена только для x86_64.

`go test` с Go 1.25.5 и `go test -modfile=mojave.mod` с Go 1.20.14
проверяют импорт и передачу TCP и UDP между локальными пирами AmneziaWG.
Сценарий 3.1 включает защиту заголовков, диапазоны таймеров и keepalive.

## Тесты моста на Mac

На Big Sur используется только `awg-bridge-mojave` (сборки на Go 1.25 требуют macOS 12+).

```bash
cd AmneziaWGBridge
# Go 1.20.14 (как для сборки awg-bridge-mojave):
GOTOOLCHAIN=local go test -count=1 -race -modfile=mojave.mod .
# затем пересобрать мост командой из начала этого файла
```

`socks_test.go` проверяет лимит соединений, освобождение мест после простоя TCP/UDP и
устойчивость к ошибкам `Accept`; `memory_test.go` (запуск с `AWG_MEMTEST=1`) измеряет память при сотнях застрявших загрузок; `tunnel_test.go` проверяет TCP и UDP через локальные пиры AmneziaWG.
