"""Локальный сервер подписки для стенда на эмуляторе.

Отдаёт минимальный профиль mihomo (всё напрямую, без внешних узлов) и пишет
в журнал заголовки каждого запроса: по ним стенд проверяет User-Agent и
заголовки устройства, которые приложение шлёт панели.

Секретов здесь нет и быть не должно: профиль синтетический, ни одного
нашего сервера в нём нет.

Запуск: python3 smoke-profile-server.py <порт> <файл журнала>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROFILE = """\
mixed-port: 7890
mode: rule
log-level: info
proxies: []
proxy-groups:
  - name: SMOKE
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,SMOKE
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 — имя задаёт BaseHTTPRequestHandler
        entry = {"path": self.path, "headers": dict(self.headers.items())}
        with open(sys.argv[2], "a", encoding="utf-8") as log:
            log.write(json.dumps(entry, ensure_ascii=False) + "\n")
        body = PROFILE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("profile-title", "smoke")
        self.send_header("subscription-userinfo", "upload=0; download=0; total=0; expire=0")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
