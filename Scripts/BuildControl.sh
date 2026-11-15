#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
resources_dir="$1"
/bin/mkdir -p "$resources_dir/bin"
test_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mojaveray-tests.XXXXXX")"
trap '/bin/rm -f "$test_dir/control-tests"; /bin/rmdir "$test_dir"' EXIT
/usr/bin/xcrun clang -std=c11 -Wall -Wextra -O2 -arch x86_64 \
    -mmacosx-version-min=10.14 -lproc \
    "$project_dir/Tests/control_tests.c" -o "$test_dir/control-tests"
"$test_dir/control-tests"
/usr/bin/xcrun clang -std=c11 -Wall -Wextra -O2 -arch x86_64 \
    -mmacosx-version-min=10.14 -lproc \
    "$project_dir/Helper/control.c" -o "$resources_dir/bin/control"
/bin/cp "$project_dir/Resources/mojaveray-service-install.sh" "$resources_dir/mojaveray-service-install.sh"
/bin/chmod 755 "$resources_dir/bin/control" "$resources_dir/mojaveray-service-install.sh"

for core in awg-bridge awg-bridge-mojave; do
    if [ ! -x "$project_dir/Vendor/bin/$core" ]; then
        echo "Отсутствует движок AmneziaWG: $core" >&2
        exit 1
    fi
    /bin/cp "$project_dir/Vendor/bin/$core" "$resources_dir/bin/$core"
    /bin/chmod 755 "$resources_dir/bin/$core"
done
/bin/mkdir -p "$resources_dir/AmneziaWG-Licenses"
/bin/cp -R "$project_dir/Vendor/AmneziaWG-Licenses/." "$resources_dir/AmneziaWG-Licenses/"
