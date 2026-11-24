"""App-owned oMLX server. The controller uses only Python's standard library.

Runtime requirements (upstream): Apple silicon, macOS 15+, and an oMLX
installation with Python 3.11–3.13. The controller needs Python 3.11+.
Pass the entry point from your app's managed environment, or pass the staged
OMLXRuntime directory embedded in your .app. Models live outside the bundle.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import time
from typing import Sequence
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener


@dataclass(frozen=True)
class Endpoint:
    base_url: str
    model_ids: tuple[str, ...]
    api_key: str = field(repr=False)


class OMLXServer:
    """Create one instance per backend. Call lifecycle methods serially."""

    def __init__(
        self,
        model_dir: Path,
        state_dir: Path,
        port: int = 8000,
        *,
        command: Sequence[str] | None = None,
        bundled_runtime: Path | None = None,
    ) -> None:
        if (command is None) == (bundled_runtime is None):
            raise ValueError("Specify exactly one of command or bundled_runtime.")
        if not 1 <= port <= 65535:
            raise ValueError("Port must be between 1 and 65535.")
        self.model_dir = Path(model_dir).expanduser().absolute()
        self.state_dir = Path(state_dir).expanduser().absolute()
        self.port = port
        self.log_path = self.state_dir / "server.log"
        self._process: subprocess.Popen | None = None
        self.endpoint: Endpoint | None = None

        # Do not pick up settings or API credentials from a separate oMLX app.
        self._env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("OMLX_", "PYTHON"))
        }
        self._env.update(
            OMLX_BASE_PATH=str(self.state_dir),
            PYTHONNOUSERSITE="1",
            PYTHONUNBUFFERED="1",
        )
        if bundled_runtime is not None:
            root = Path(bundled_runtime).expanduser().absolute()
            python_home = root / "Python/cpython-3.11"
            python = python_home / "bin/python3"
            site = root / "Python/framework-mlx-base/lib/python3.11/site-packages"
            if not site.is_dir() or not (root / "omlx/cli.py").is_file():
                raise FileNotFoundError(f"Incomplete bundled oMLX runtime: {root}")
            self._command = [str(python), "-m", "omlx.cli"]
            self._env.update(
                PYTHONHOME=str(python_home),
                PYTHONPATH=os.pathsep.join((str(root), str(site))),
                PYTHONDONTWRITEBYTECODE="1",
            )
        else:
            if not command:
                raise ValueError("command must include an executable.")
            executable = Path(command[0]).expanduser()
            if not executable.is_absolute():
                raise ValueError("Provide an absolute path to the managed executable.")
            # Preserve the executable path. Resolving symlinks breaks some venvs.
            self._command = [str(executable), *command[1:]]
        if not os.access(self._command[0], os.X_OK) or not Path(self._command[0]).is_file():
            raise FileNotFoundError(f"oMLX launcher is unavailable: {self._command[0]}")

    def start(self, timeout: float = 60) -> Endpoint:
        """Start the worker and wait for the authenticated model catalog."""
        if timeout <= 0:
            raise ValueError("Startup timeout must be positive.")
        if self._process is not None:
            if self._process.poll() is None:
                raise RuntimeError("oMLX is already running.")
            self.stop()
        if not self.model_dir.is_dir():
            raise FileNotFoundError(f"Model directory does not exist: {self.model_dir}")
        # Detect a common conflict early. The child still has to bind the port.
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1", self.port))
            except OSError as exc:
                raise RuntimeError(f"Cannot bind local port {self.port}: {exc}") from exc

        self.state_dir.mkdir(parents=True, exist_ok=True)
        key = secrets.token_urlsafe(32)
        base_url = f"http://127.0.0.1:{self.port}/v1"
        command = [
            *self._command, "serve", "--host", "127.0.0.1",
            "--port", str(self.port), "--model-dir", str(self.model_dir),
            "--headless", "--paged-ssd-cache-max-size", "20GB",
        ]
        with self.log_path.open("ab") as log:
            self._process = subprocess.Popen(
                command, cwd=self.state_dir, env={**self._env, "OMLX_API_KEY": key},
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                code = self._process.poll()
                if code is not None:
                    raise RuntimeError(f"oMLX exited with code {code}. See {self.log_path}")
                try:
                    catalog = _json_request(base_url + "/models", key, timeout=1)
                    ids = tuple(item["id"] for item in catalog["data"])
                    if not all(isinstance(item, str) for item in ids):
                        raise ValueError("Invalid model IDs")
                except (URLError, TimeoutError, ValueError, KeyError, TypeError):
                    time.sleep(0.25)
                    continue
                if self._process.poll() is None:
                    self.endpoint = Endpoint(base_url, ids, key)
                    return self.endpoint
            raise TimeoutError(f"oMLX did not become ready. See {self.log_path}")
        except BaseException:
            self.stop()
            raise

    def stop(self) -> None:
        """Stop only the process started by this instance and reap it."""
        self.endpoint = None
        process = self._process
        if process is None:
            return
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        self._process = None


def _json_request(url: str, api_key: str, *, timeout: float, body: dict | None = None):
    request = Request(
        url, data=None if body is None else json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    with build_opener(ProxyHandler({})).open(request, timeout=timeout) as response:
        return json.load(response)


def smoke_chat(endpoint: Endpoint, model_id: str, timeout: float = 180) -> dict:
    """Send one completion to confirm the selected checkpoint actually loads."""
    if model_id not in endpoint.model_ids:
        raise ValueError(f"Model {model_id!r} is absent from the server catalog.")
    return _json_request(
        endpoint.base_url + "/chat/completions", endpoint.api_key, timeout=timeout,
        body={
            "model": model_id,
            "messages": [{"role": "user", "content": "Say hello in one sentence."}],
            "max_tokens": 64,
            "stream": False,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    runtime = parser.add_mutually_exclusive_group(required=True)
    runtime.add_argument("--python", type=Path, help="Python in your managed oMLX environment")
    runtime.add_argument("--bundled-runtime", type=Path, help="Embedded OMLXRuntime directory")
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--smoke-model", help="Make one chat request using this exact catalog ID")
    args = parser.parse_args()

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    server = None
    try:
        server = OMLXServer(
            args.model_dir, args.state_dir, args.port,
            command=None if args.python is None else [str(args.python), "-m", "omlx.cli"],
            bundled_runtime=args.bundled_runtime,
        )
        endpoint = server.start()
        print(json.dumps({"base_url": endpoint.base_url, "models": endpoint.model_ids}))
        if args.smoke_model:
            print(json.dumps(smoke_chat(endpoint, args.smoke_model), indent=2))
        return 0
    except KeyboardInterrupt:
        return 130
    except HTTPError as exc:
        parser.exit(1, f"oMLX HTTP {exc.code}: {exc.read(2048).decode(errors='replace')}\n")
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, f"{exc}\n")
    finally:
        if server is not None:
            server.stop()


if __name__ == "__main__":
    raise SystemExit(main())
