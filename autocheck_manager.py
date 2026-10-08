#!/usr/bin/env python3
"""
autocheck_manager.py — Dynamic Multi-Model Manager for llama.cpp SYCL

Scans /models (or $MODELS_DIR) for .gguf model files and matching config files:
  <model_name>.gguf  <--->  <model_name>.json / <model_name>.yaml / <model_name>.ini

Features:
- Dynamically starts llama-server instances for valid model + config pairs.
- Automatically assigns distinct ports if unspecified, or uses the port in config.
- Automatically isolates stdout/stderr logs into /logs/<model_name>.log.
- Periodically scans for:
    - New model + config added -> launches new llama-server process.
    - Model or config deleted -> gracefully terminates running instance.
    - Config file modified (mtime/hash changed) -> restarts instance with updated params.
- Propagates SIGTERM/SIGINT cleanly to all child processes.
"""

import os
import sys
import time
import signal
import shlex
import subprocess
from pathlib import Path

MODELS_DIR = Path(os.environ.get("MODELS_DIR", "/models"))
LOGS_DIR = Path(os.environ.get("LOGS_DIR", "/logs"))
SCAN_INTERVAL = float(os.environ.get("SCAN_INTERVAL", "5.0"))
BASE_PORT = int(os.environ.get("BASE_PORT", "8080"))
LLAMA_SERVER_BIN = os.environ.get("LLAMA_SERVER_BIN", "/usr/local/bin/llama-server")

running_instances = {}
allocated_ports = set()
stopping = False


def log(msg: str):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [autocheck] {msg}", flush=True)


def parse_config(cfg_path: Path) -> dict:
    """Parses JSON, YAML-like, or KEY=VAL / CLI args text config."""
    text = cfg_path.read_text(encoding="utf-8").strip()
    data = {}

    # Try JSON
    if text.startswith("{"):
        try:
            import json
            data = json.loads(text)
            if isinstance(data, dict):
                return data
        except Exception:
            pass

    # Try simple key: value (YAML-like) or key=value / ini
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip().strip("\"'")
        elif "=" in line:
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip().strip("\"'")

    return data


def config_to_args(cfg: dict, model_path: Path, port: int) -> list[str]:
    """Builds llama-server argument list from config dict."""
    args = [LLAMA_SERVER_BIN]

    # Model path
    args.extend(["-m", str(model_path)])

    # Host & Port
    host = cfg.get("host", "0.0.0.0")
    args.extend(["--host", str(host), "--port", str(port)])

    # Known key mappings
    key_mapping = {
        "ngl": "-ngl", "n_gpu_layers": "-ngl", "gpu_layers": "-ngl",
        "c": "-c", "ctx_size": "-c", "context_size": "-c",
        "t": "-t", "threads": "-t",
        "b": "-b", "batch_size": "-b",
        "ub": "-ub", "ubatch_size": "-ub",
        "alias": "-a", "model_alias": "-a",
        "reasoning_budget": "--reasoning-budget", "reasoning_effort": "--reasoning-effort",
        "cache_type_k": "-ctk", "cache_type_v": "-ctv",
        "n_parallel": "-np", "parallel": "-np",
        "embedding": "--embedding", "embeddings": "--embedding"
    }

    # Custom cli_args raw string if provided
    raw_args = cfg.get("args") or cfg.get("cli_args")
    if raw_args and isinstance(raw_args, str):
        args.extend(shlex.split(raw_args))

    handled_keys = {"host", "port", "args", "cli_args"}

    for k, v in cfg.items():
        if k in handled_keys:
            continue
        cli_flag = key_mapping.get(k)
        if cli_flag:
            if isinstance(v, bool):
                if v:
                    args.append(cli_flag)
            elif v is not None and str(v).strip():
                args.extend([cli_flag, str(v)])
        else:
            # If user provided a literal flag like "--jinja" or "-fa"
            flag = k if k.startswith("-") else f"--{k.replace('_', '-')}"
            if isinstance(v, bool):
                if v:
                    args.append(flag)
            elif v is not None and str(v).strip():
                args.extend([flag, str(v)])

    return args


def get_available_port(preferred: int | None = None) -> int:
    if preferred and preferred not in allocated_ports:
        allocated_ports.add(preferred)
        return preferred
    p = BASE_PORT
    while p in allocated_ports:
        p += 1
    allocated_ports.add(p)
    return p


class ModelInstance:
    def __init__(self, name: str, model_file: Path, config_file: Path):
        self.name = name
        self.model_file = model_file
        self.config_file = config_file
        self.config_mtime = config_file.stat().st_mtime
        self.model_mtime = model_file.stat().st_mtime
        self.process = None
        self.log_file = None
        self.port = None

    def start(self):
        cfg = parse_config(self.config_file)
        preferred_port = None
        if "port" in cfg:
            try:
                preferred_port = int(cfg["port"])
            except ValueError:
                pass

        self.port = get_available_port(preferred_port)
        cmd_args = config_to_args(cfg, self.model_file, self.port)

        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        log_path = LOGS_DIR / f"{self.name}.log"
        self.log_file = open(log_path, "a", encoding="utf-8")

        log(f"Starting [{self.name}] on port {self.port} ...")
        log(f"  Command: {' '.join(shlex.quote(x) for x in cmd_args)}")
        log(f"  Log file: {log_path}")

        env = os.environ.copy()
        # Keep SYCL dynamic backend discovery active
        env["LD_LIBRARY_PATH"] = f"/app/lib:{env.get('LD_LIBRARY_PATH', '')}"

        self.process = subprocess.Popen(
            cmd_args,
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            cwd="/app/lib",
            env=env,
            preexec_fn=os.setsid
        )
        log(f"Instance [{self.name}] launched (PID {self.process.pid}).")

    def stop(self):
        if not self.process:
            return
        log(f"Stopping [{self.name}] (PID {self.process.pid}) ...")
        try:
            os.killpg(os.getpgid(self.process.pid), signal.SIGTERM)
            try:
                self.process.wait(timeout=8.0)
            except subprocess.TimeoutExpired:
                log(f"Force killing [{self.name}] (SIGKILL) ...")
                os.killpg(os.getpgid(self.process.pid), signal.SIGKILL)
                self.process.wait(timeout=2.0)
        except Exception as e:
            log(f"Error terminating [{self.name}]: {e}")
        finally:
            if self.log_file:
                self.log_file.close()
            if self.port in allocated_ports:
                allocated_ports.remove(self.port)
            log(f"Instance [{self.name}] stopped.")
            self.process = None


def scan_models() -> dict[str, tuple[Path, Path]]:
    if not MODELS_DIR.exists():
        return {}
    pairs = {}
    for mf in MODELS_DIR.glob("*.gguf"):
        stem = mf.stem
        # check for config with matching stem (.json, .yaml, .yml, .ini, .conf)
        cfg_candidates = [
            MODELS_DIR / f"{stem}.json",
            MODELS_DIR / f"{stem}.yaml",
            MODELS_DIR / f"{stem}.yml",
            MODELS_DIR / f"{stem}.conf",
            MODELS_DIR / f"{stem}.ini",
        ]
        found_cfg = None
        for cand in cfg_candidates:
            if cand.is_file():
                found_cfg = cand
                break
        if found_cfg:
            pairs[stem] = (mf, found_cfg)
    return pairs


def reconcile():
    active_pairs = scan_models()

    # 1. Stop instances whose model or config was removed
    to_remove = []
    for name, inst in running_instances.items():
        if name not in active_pairs:
            log(f"Model or config removed for [{name}].")
            inst.stop()
            to_remove.append(name)
        elif not inst.model_file.exists() or not inst.config_file.exists():
            log(f"File missing for [{name}].")
            inst.stop()
            to_remove.append(name)
        else:
            # Check if config or model was modified
            cur_cfg_mtime = inst.config_file.stat().st_mtime
            cur_model_mtime = inst.model_file.stat().st_mtime
            if cur_cfg_mtime != inst.config_mtime or cur_model_mtime != inst.model_mtime:
                log(f"Configuration or model file modified for [{name}]. Triggering reload...")
                inst.stop()
                inst.config_mtime = cur_cfg_mtime
                inst.model_mtime = cur_model_mtime
                inst.start()

    for name in to_remove:
        del running_instances[name]

    # 2. Check process health of running instances
    for name, inst in list(running_instances.items()):
        if inst.process and inst.process.poll() is not None:
            code = inst.process.returncode
            log(f"WARNING: Instance [{name}] exited unexpectedly with code {code}.")
            inst.stop()
            del running_instances[name]

    # 3. Start new instances
    for name, (mf, cf) in active_pairs.items():
        if name not in running_instances:
            log(f"Discovered new model + config: [{name}] ({mf.name} + {cf.name})")
            inst = ModelInstance(name, mf, cf)
            try:
                inst.start()
                running_instances[name] = inst
            except Exception as e:
                log(f"Failed to start [{name}]: {e}")


def handle_shutdown(signum, frame):
    global stopping
    log("Received termination signal. Shutting down all managed instances...")
    stopping = True
    for name, inst in list(running_instances.items()):
        inst.stop()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    log(f"autocheck manager started.")
    log(f"Scanning models in: {MODELS_DIR}")
    log(f"Logs directory:    {LOGS_DIR}")
    log(f"Base port:         {BASE_PORT}")
    log(f"Scan interval:     {SCAN_INTERVAL}s")

    while not stopping:
        try:
            reconcile()
        except Exception as e:
            log(f"Error during reconcile loop: {e}")
        time.sleep(SCAN_INTERVAL)


if __name__ == "__main__":
    main()
