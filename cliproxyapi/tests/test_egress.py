import base64
import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
CONVERTER = ROOT / "egress" / "vless_config.py"
TEST_UUID = "11111111-2222-4333-8444-555555555555"
PUBLIC_KEY = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("=")


def node(**changes: str) -> str:
    query = dict(encryption="none", flow="xtls-rprx-vision", security="reality",
                 sni="example.com", fp="chrome", pbk=PUBLIC_KEY,
                 sid="a3402368", type="tcp", headerType="none")
    query.update(changes)
    return f"vless://{TEST_UUID}@192.0.2.1:443?{urlencode(query)}#synthetic"


class EgressTests(unittest.TestCase):
    def convert(self, link: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(CONVERTER)], input=link,
                              text=True, capture_output=True, check=False)

    def test_reality_node_produces_validated_socks_configuration(self) -> None:
        result = self.convert(node())
        self.assertEqual(result.returncode, 0, result.stderr)
        cfg = json.loads(result.stdout)
        self.assertEqual(cfg["inbounds"][0]["listen_port"], 1080)
        self.assertEqual(cfg["inbounds"][0]["type"], "socks")
        outbound = cfg["outbounds"][0]
        self.assertEqual(outbound["uuid"], TEST_UUID)
        self.assertEqual(outbound["server"], "192.0.2.1")
        self.assertEqual(outbound["server_port"], 443)
        self.assertEqual(outbound["flow"], "xtls-rprx-vision")
        self.assertTrue(outbound["tls"]["enabled"])
        self.assertTrue(outbound["tls"]["reality"]["enabled"])
        self.assertEqual(outbound["tls"]["reality"]["short_id"], "a3402368")
        self.assertEqual(outbound["tls"]["utls"], {"enabled": True, "fingerprint": "chrome"})
        self.assertEqual(outbound["tls"]["reality"]["public_key"], PUBLIC_KEY)
        self.assertEqual(outbound["tls"]["server_name"], "example.com")
        self.assertNotIn("insecure", outbound["tls"])
        self.assertEqual(cfg["route"]["final"], outbound["tag"])

    def test_rejects_unsupported_or_malformed_links_without_echoing_secrets(self) -> None:
        links = [node(type="ws"), node(security="tls"), node(encryption="other"),
                 node(flow="unknown"), node(pbk="invalid"), node(sid="xyz"),
                 node(insecure="1"), node(fp="invalid"), node(sni=""),
                 node() + "\n" + node(), "vmess://" + TEST_UUID,
                 node().replace(":443?", ":0?"),
                 node().replace("#synthetic", "&security=reality#synthetic")]
        for link in links:
            with self.subTest(link_kind=links.index(link)):
                result = self.convert(link)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("Invalid VLESS Reality link", result.stderr)
                self.assertNotIn(TEST_UUID, result.stderr)
                self.assertNotIn(link, result.stderr)

    @unittest.skipUnless(shutil.which("docker"), "Docker CLI unavailable")
    def test_egress_project_joins_application_network_without_host_ports(self) -> None:
        env = dict(os.environ, CLIPROXY_DATA_DIR="/opt/cliproxyapi",
                   COMPOSE_PROJECT_NAME="application-project",
                   EGRESS_NETWORK_NAME="application-project_backend")
        result = subprocess.run(["docker", "compose", "-f", str(ROOT / "egress/compose.yml"),
                                 "-p", "separate-egress-project", "config", "--format", "json"],
                                env=env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = json.loads(result.stdout)
        self.assertEqual(rendered["networks"]["backend"]["name"], "application-project_backend")
        self.assertTrue(rendered["networks"]["backend"]["external"])
        self.assertFalse(rendered["services"]["egress"].get("ports"))
        self.assertNotEqual(rendered["services"]["egress"].get("network_mode"), "host")


if __name__ == "__main__":
    unittest.main()
