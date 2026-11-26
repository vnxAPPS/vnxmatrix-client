#!/usr/bin/env bash
# Дымовой тест на эмуляторе Android: ставит APK, запускает приложение,
# проходит первый экран согласия и проверяет, что приложение живо.
#
# Зачем: «ядро остановлено» и «getConfig timed out» на телефоне вскрывались
# только у владельца, через ручную установку и скриншоты, по циклу на версию.
# Здесь то же видно на каждом пуше, вместе с logcat и скриншотами в
# артефактах запуска.
#
# Падает на явных отказах: APK не ставится, процесс приложения умер, в logcat
# есть FATAL EXCEPTION / UnsatisfiedLinkError / ANR, профиль по ссылке не
# скачан, User-Agent не FlClash…, после команды START не поднялся туннель.
# Остальное собирает как доказательства для разбора.
#
# Запуск: bash .github/scripts/emulator-smoke.sh <каталог с APK>
set -u

DIST=${1:-dist}
OUT=smoke
PKG=com.vnxmatrix.client
mkdir -p "$OUT"
fail=0

summary() { printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; echo "$*"; }

APK=$(ls "$DIST"/vnxMATRIX-android-x86_64*.apk 2>/dev/null | head -1)
if [ -z "$APK" ]; then
  echo "::error::В $DIST нет x86_64 APK — эмулятору нечего ставить."
  exit 1
fi
summary "## Стенд: эмулятор Android"
summary ""
summary "- APK: \`$(basename "$APK")\`"

if ! adb install -r -g "$APK" > "$OUT/install.txt" 2>&1; then
  cat "$OUT/install.txt"
  echo "::error::APK не установился на эмулятор."
  exit 1
fi
summary "- установка: ок"

adb logcat -c
adb shell am start -W -n "$PKG/com.follow.clashx.MainActivity" > "$OUT/start.txt" 2>&1
sleep 15
adb exec-out screencap -p > "$OUT/01-start.png" 2>/dev/null

# Flutter отдаёт подписи кнопок в content-desc, обычные виджеты — в text,
# поэтому ищем по обоим. Первым экраном идёт согласие с условиями.
tap_label() {
  adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 || return 1
  adb shell cat /sdcard/ui.xml > "$OUT/ui.xml" 2>/dev/null || return 1
  local bounds
  bounds=$(grep -oE "<node[^>]*(text|content-desc)=\"[^\"]*($1)[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" "$OUT/ui.xml" \
    | head -1 | grep -oE 'bounds="[^"]+"' | grep -oE '[0-9]+' | tr '\n' ' ')
  [ -n "$bounds" ] || return 1
  # shellcheck disable=SC2086
  set -- $bounds
  adb shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
  return 0
}

for attempt in 1 2 3; do
  if tap_label 'I agree|Agree|Accept|Согласен|Принять|Continue|Продолжить|OK'; then
    summary "- нажата кнопка первого экрана (попытка $attempt)"
    sleep 6
  fi
done

sleep 20
adb exec-out screencap -p > "$OUT/02-after.png" 2>/dev/null

# --- Ядро: профиль по ссылке, VPN, туннель ---------------------------------
# На телефоне ломалось именно это: профиль скачан, а ядро не стартует
# («Перезапустить ядро — Остановлено»). Профиль синтетический, с локального
# сервера, без наших узлов: стенд проверяет приложение, а не панель.
PORT=8765
: > "$OUT/http.log"
python3 "$(dirname "$0")/smoke-profile-server.py" "$PORT" "$OUT/http.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
adb reverse tcp:$PORT tcp:$PORT > /dev/null
adb shell "am start -a android.intent.action.VIEW -d 'vnxmatrix://install-config?url=http%3A%2F%2F127.0.0.1%3A$PORT%2Fsub' $PKG" \
  > "$OUT/link.txt" 2>&1

for _ in $(seq 1 30); do [ -s "$OUT/http.log" ] && break; sleep 2; done
summary ""
summary "### Ядро"
if [ -s "$OUT/http.log" ]; then
  ua=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["headers"].get("User-Agent",""))' "$OUT/http.log")
  hdrs=$(python3 -c 'import json,sys; h=json.loads(open(sys.argv[1]).readline())["headers"]; print(", ".join(sorted(k for k in h if k.lower().startswith("x-"))))' "$OUT/http.log")
  summary "- профиль скачан, User-Agent: \`$ua\`"
  summary "- заголовки устройства: ${hdrs:-нет}"
  # Панель выбирает формат по началу User-Agent (правило ^flclash → MIHOMO).
  if ! printf '%s' "$ua" | grep -qi '^flclash'; then
    echo "::error::User-Agent не начинается с FlClash: панель отдаст base64 вместо YAML."
    fail=1
  fi
else
  echo "::error::Приложение не скачало профиль по ссылке install-config."
  summary "- профиль по ссылке не скачан"
  fail=1
fi
sleep 5
adb exec-out screencap -p > "$OUT/03-profile.png" 2>/dev/null

# Разрешение на VPN выдаём сами: системный диалог на эмуляторе нажать некому.
adb shell appops set "$PKG" ACTIVATE_VPN allow
adb shell am start -n "$PKG/com.follow.clashx.QuickActionActivity" -a "$PKG.action.START" \
  > "$OUT/vpn-start.txt" 2>&1
tun=""
for _ in $(seq 1 30); do
  tun=$(adb shell ip -o link 2>/dev/null | grep -oE 'tun[0-9]+' | head -1)
  [ -n "$tun" ] && break
  sleep 2
done
adb shell ip addr > "$OUT/ip-addr.txt" 2>&1
adb shell dumpsys connectivity > "$OUT/connectivity.txt" 2>&1
sleep 3
adb exec-out screencap -p > "$OUT/04-vpn.png" 2>/dev/null
if [ -n "$tun" ]; then
  summary "- VPN включён, туннель \`$tun\` поднят: ядро стартовало"
else
  echo "::error::После команды START туннель не появился: ядро или VpnService не стартовали."
  summary "- туннель не поднялся за минуту"
  fail=1
fi
sleep 10
adb shell ps -A -o PID,NAME > "$OUT/ps.txt" 2>&1
adb shell dumpsys activity services "$PKG" > "$OUT/services.txt" 2>&1
adb logcat -d -v time > "$OUT/logcat.txt" 2>&1

summary ""
summary "### Процессы приложения"
summary '```'
grep -i "$PKG" "$OUT/ps.txt" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" || summary "(нет)"
grep -i "$PKG" "$OUT/ps.txt" || true
summary '```'

if ! grep -qi "$PKG" "$OUT/ps.txt"; then
  echo "::error::Процесс приложения не жив через минуту после запуска."
  fail=1
fi

crashes=$(grep -nE "FATAL EXCEPTION|UnsatisfiedLinkError|ANR in $PKG|Fatal signal" "$OUT/logcat.txt" | head -20)
if [ -n "$crashes" ]; then
  echo "::error::В logcat есть падения приложения."
  summary ""
  summary "### Падения"
  summary '```'
  summary "$crashes"
  summary '```'
  fail=1
fi

summary ""
summary "### Ядро и служба: последние строки logcat"
summary '```'
grep -iE "clash|mihomo|core|vpn|flutter" "$OUT/logcat.txt" | grep -i -E "$PKG|flutter|clash|mihomo" | tail -40 \
  >> "${GITHUB_STEP_SUMMARY:-/dev/null}" || true
summary '```'
summary ""
summary "Полный logcat, скриншоты и дамп экрана — в артефакте smoke-…"

exit $fail
