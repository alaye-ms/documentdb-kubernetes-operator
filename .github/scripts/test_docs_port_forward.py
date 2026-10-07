"""Regression tests for getting-started gateway port-forward commands."""

from pathlib import Path
import re
import shlex
import unittest


DOCS = Path(__file__).resolve().parents[2] / "docs/operator-public-documentation/preview"


class GatewayPortForwardTests(unittest.TestCase):
    def test_getting_started_commands_target_gateway_service(self):
        examples = {
            "getting-started/connecting-to-documentdb.md": ("my-documentdb", "documentdb-ns"),
            "getting-started/quickstart-kind.md": ("my-documentdb", "documentdb-ns"),
            "getting-started/quickstart-k3s.md": ("my-documentdb", "documentdb-ns"),
            "index.md": ("documentdb-preview", "documentdb-preview-ns"),
        }
        for filename, (name, namespace) in examples.items():
            with self.subTest(document=filename):
                content = (DOCS / filename).read_text(encoding="utf-8")
                commands = re.findall(
                    r"^\s*(kubectl\s+port-forward\b[^\n]*)", content, re.MULTILINE
                )
                self.assertTrue(commands, f"No port-forward example in {filename}")
                for command in commands:
                    self.assertEqual(
                        shlex.split(command),
                        [
                            "kubectl",
                            "port-forward",
                            f"svc/documentdb-service-{name}",
                            "10260:10260",
                            "-n",
                            namespace,
                        ],
                    )


if __name__ == "__main__":
    unittest.main()
