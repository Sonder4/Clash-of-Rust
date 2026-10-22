#!/usr/bin/env python3
"""Offline checks for the single authoritative WSL tool installer.

No package installation, network request or WSL mutation runs here. The
compatibility wrapper is exercised against a temporary mock shell.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "tools" / "install-wsl-tools.sh"
WRAPPER = ROOT / "install-workspace-tools.sh"


class AuthoritativeInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSTALLER.read_text(encoding="utf-8")
        cls.wrapper = WRAPPER.read_text(encoding="utf-8")

    def test_installer_clears_every_proxy_variable_before_gate(self):
        clear = self.source.index("export http_proxy=")
        gate = self.source.index("require_vps_egress")
        self.assertLess(clear, gate)
        line = self.source[clear : self.source.index("\n", clear)]
        for name in (
            "http_proxy",
            "https_proxy",
            "all_proxy",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
        ):
            self.assertIn(name, line)

    def test_vps_gate_requires_vps_address_and_fail_closed_exit(self):
        gate_start = self.source.index("require_vps_egress()")
        gate_end = self.source.index("\n}\n", gate_start) + 3
        gate = self.source[gate_start:gate_end]
        self.assertIn("curl -4fsS", gate)
        self.assertIn("https://ifconfig.co/ip", gate)
        self.assertIn('"${actual:-unavailable}"', gate)
        self.assertIn("EXPECTED_EGRESS_IPV4", gate)
        self.assertIn("exit 20", gate)
        self.assertIn(
            'EXPECTED_EGRESS_IPV4="${EXPECTED_EGRESS_IPV4:-62.84.164.122}"',
            self.source,
        )

    def test_vps_gate_precedes_every_install_action(self):
        main_start = self.source.index("main()")
        main = self.source[main_start:]
        self.assertLess(main.index("require_vps_egress"), main.index("install_base_packages"))
        for function in (
            "install_base_packages",
            "install_node",
            "install_chrome",
            "install_claude_desktop",
            "install_npm_tools",
        ):
            self.assertIn(function + "\n", main)
        self.assertNotIn("apt-get", main[: main.index("require_vps_egress")])

    def test_required_components_and_versions_are_fixed(self):
        expected = {
            'NODE_VERSION="${NODE_VERSION:-v22.23.3}"': "Node",
            'CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.302}"': "Claude Code",
            'CODEX_CLI_VERSION="${CODEX_CLI_VERSION:-0.163.0}"': "Codex",
        }
        for declaration, label in expected.items():
            self.assertIn(declaration, self.source, label)
        self.assertIn("google-chrome-stable", self.source)
        self.assertIn("claude-desktop", self.source)
        self.assertIn(
            'npm install -g --silent "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"',
            self.source,
        )
        self.assertIn(
            'npm install -g --silent "@openai/codex@${CODEX_CLI_VERSION}"',
            self.source,
        )
        for verification in (
            "claude --version",
            "codex --version",
            "google-chrome --version",
            "claude-desktop --version",
        ):
            self.assertIn(verification, self.source)

    def test_installer_has_no_legacy_proxy_or_split_dns_logic(self):
        for token in ("mihomo", "sing-box", "redsocks", "clash"):
            self.assertNotIn(token, self.source.lower())
        self.assertNotIn("systemd-resolved", self.source)
        self.assertNotIn("resolv.conf", self.source)

    def test_wrapper_is_a_single_absolute_compatibility_forwarder(self):
        self.assertIn(
            'SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"',
            self.wrapper,
        )
        self.assertIn(
            'AUTHORITATIVE_INSTALLER="${SCRIPT_DIR}/tools/install-wsl-tools.sh"',
            self.wrapper,
        )
        self.assertIn('exec /bin/sh "${AUTHORITATIVE_INSTALLER}" "$@"', self.wrapper)
        for legacy in (
            "apt-get",
            "dpkg -i",
            "npm install",
            "google-chrome-stable_current_amd64.deb",
            "claude-desktop-wsl.desktop",
        ):
            self.assertNotIn(legacy, self.wrapper)

    def _run_wrapper(self, installer_body):
        shell = "/bin/sh"
        if os.name == "nt":
            shell = shutil.which("sh.exe") or shutil.which("bash.exe")
            if not shell:
                self.skipTest("No POSIX shell is available on this Windows host")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts" / "wsl-secure-egress"
            tools = scripts / "tools"
            tools.mkdir(parents=True)
            wrapper = scripts / "install-workspace-tools.sh"
            wrapper.write_text(self.wrapper, encoding="utf-8")
            installer = tools / "install-wsl-tools.sh"
            installer.write_text(installer_body, encoding="utf-8")
            wrapper.chmod(0o755)
            installer.chmod(0o755)
            return subprocess.run(
                [shell, str(wrapper), "forwarded value"],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_wrapper_forwards_arguments_from_an_unrelated_working_directory(self):
        result = self._run_wrapper(
            textwrap.dedent(
                """\
                #!/bin/sh
                printf 'arg=%s\\n' "$1"
                """
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "arg=forwarded value\n")

    def test_wrapper_preserves_fail_closed_exit_status(self):
        result = self._run_wrapper(
            textwrap.dedent(
                """\
                #!/bin/sh
                echo 'refusing installation: egress=unavailable' >&2
                exit 20
                """
            )
        )
        self.assertEqual(result.returncode, 20)
        self.assertIn("refusing installation", result.stderr)


if __name__ == "__main__":
    unittest.main()
