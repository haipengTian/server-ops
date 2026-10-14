"""Convert a server-local VLESS Reality link without echoing it on errors."""
import base64
import json
import re
import sys
import uuid
from typing import Dict, List, Union
from urllib.parse import parse_qs, urlsplit


JSONValue = Union[None, bool, int, str, List["JSONValue"], Dict[str, "JSONValue"]]


def convert(link: str) -> Dict[str, JSONValue]:
    if not link or len(link) > 8192 or any(c.isspace() for c in link):
        raise ValueError
    url = urlsplit(link)
    if url.scheme != "vless" or url.password or url.path not in ("", "/"):
        raise ValueError
    identity = str(uuid.UUID(url.username or ""))
    host, port = url.hostname, url.port
    if not host or not port or not 1 <= port <= 65535:
        raise ValueError
    if not re.fullmatch(r"[A-Za-z0-9.:-]+", host):
        raise ValueError
    query = parse_qs(url.query, keep_blank_values=True, strict_parsing=True)
    allowed = {"encryption", "flow", "security", "sni", "fp", "pbk",
               "sid", "type", "headerType"}
    if set(query) - allowed or any(len(values) != 1 for values in query.values()):
        raise ValueError
    def field(key: str, default: str = "") -> str:
        return query.get(key, [default])[0]
    if (field("security") != "reality" or field("type", "tcp") != "tcp"
            or field("encryption", "none") != "none"
            or field("headerType", "none") != "none"
            or field("flow") != "xtls-rprx-vision"):
        raise ValueError
    sni, key, short_id = field("sni"), field("pbk"), field("sid")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", sni):
        raise ValueError
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", key):
        raise ValueError
    if len(base64.urlsafe_b64decode(key + "=")) != 32:
        raise ValueError
    if not re.fullmatch(r"(?:[a-fA-F0-9]{2}){0,8}", short_id):
        raise ValueError
    fingerprint = field("fp", "chrome")
    if fingerprint not in {"chrome", "firefox", "safari", "edge"}:
        raise ValueError
    return {
        "log": {"level": "warn"},
        "inbounds": [{"type": "socks", "tag": "socks-in",
                      "listen": "0.0.0.0", "listen_port": 1080}],
        "outbounds": [{"type": "vless", "tag": "node", "server": host,
                       "server_port": port, "uuid": identity,
                       "flow": "xtls-rprx-vision", "tls": {
                           "enabled": True, "server_name": sni,
                           "utls": {"enabled": True, "fingerprint": fingerprint},
                           "reality": {"enabled": True, "public_key": key,
                                       "short_id": short_id}}}],
        "route": {"final": "node"},
    }


if __name__ == "__main__":
    try:
        config = convert(sys.stdin.read().strip())
    except (ValueError, TypeError, OverflowError):
        print("Invalid VLESS Reality link; input was not logged.", file=sys.stderr)
        sys.exit(1)
    json.dump(config, sys.stdout, indent=2)
    sys.stdout.write("\n")
