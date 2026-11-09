# The Pharaoh Agent V5 — Local AI Pentesting Stack

A fully local, self-hosted AI pentesting stack for **Ubuntu 22.04** with an NVIDIA GPU
(tested target: **96 GB RAM / 48 GB VRAM, CUDA working**).

## Architecture

```
┌─────────────┐   OpenAI API    ┌──────────────────────────────┐
│  opencode   │ ──────────────► │ llama.cpp  (llama-server)     │
│  (agent CLI)│  localhost:8000 │ Qwen3.8-27B-abliterated       │
│             │                 │ (GGUF Q8_0, xhigh reasoning)  │
│             │   MCP (stdio)   └──────────────────────────────┘
│             │ ──────────────► ┌──────────────────────────────┐
└─────────────┘                 │ HexStrike AI (MCP tools)      │
                                │ hexstrike_server.py  :8888    │
                                │ nmap · nuclei · sqlmap · ...  │
                                └──────────────────────────────┘
```

| Component    | What it is                                                        | Port / transport          |
| ------------ | ----------------------------------------------------------------- | ------------------------- |
| llama.cpp    | Serves the Qwen3.8-27B Abliterated Q8_0 GGUF, OpenAI-compatible  | `0.0.0.0:8000` (HTTP)     |
| HexStrike AI | MCP security-tools server (nmap, nuclei, sqlmap, gobuster, …)     | `0.0.0.0:8888` (HTTP API) |
| opencode     | Terminal AI agent wired to the local model + HexStrike MCP tools  | MCP over stdio            |

The selected model is built for **agentic planning and execution**, native tool calling,
and long multi-step tasks. Thinking is explicitly enabled at **xhigh** depth, and reasoning
is preserved across turns to improve decision consistency. The abliterated checkpoint is
provided by `huihui-ai`; no hosted model API is required.

## Quick start (fresh Ubuntu 22.04 server)

```bash
git clone https://github.com/I7MD979/The_Pharoh_Agent_V5.git
cd The_Pharoh_Agent_V5
chmod +x install.sh start-stack.sh stop-stack.sh scripts/*.sh
./install.sh            # full setup: llama.cpp → model → services → HexStrike → opencode → tools → verify
```

The installer is idempotent — re-running it skips finished steps. It auto-detects
your login user/home and generates the systemd units from `systemd/*.service` templates.

### What the installer does (per step)

1. `scripts/01-install-llamacpp.sh` — downloads the latest prebuilt CUDA release of
   llama.cpp from `ggml-org/llama.cpp`; falls back to building from source with
   `cmake -DGGML_CUDA=ON`. Older managed installs without the required reasoning controls
   are upgraded. Verifies `llama-server --version`.
2. `scripts/02-download-model.sh` — installs `huggingface-hub`, then downloads only
   `Huihui-Qwen3.8-27B-abliterated-Q8_0.gguf` (~29 GB) from
   `huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF` into `~/models`.
   The stack runs text-only and does not download the optional vision projector.
3. `scripts/03-setup-services.sh` — installs + enables the `llama-cyberstrike` systemd
   service and verifies `curl localhost:8000/v1/models` and a `"say OK"` chat completion.
4. `scripts/04-install-hexstrike.sh` — clones `netcuter/Hexstrike-AI` into `~/Hexstrike-AI`,
   creates its venv, installs Python requirements and the security tools
   (nmap, nuclei, sqlmap, gobuster, …), patches the MCP bridge request timeout
   (300 s → 1800 s), installs + enables the `hexstrike` service.
5. `scripts/05-install-opencode.sh` — installs Node.js + `opencode-ai`, writes
   `~/.config/opencode/opencode.json` (local provider on port 8000 + HexStrike MCP over stdio,
   with a 1-hour MCP request timeout for long scans).
6. `scripts/06-install-all-tools.sh` — installs the **full** HexStrike toolset (~120 tools):
   apt packages, Go tools, pip CLIs, Ruby gems, GitHub release binaries (feroxbuster,
   rustscan, trivy, terrascan, kube-bench, ghidra, …), Metasploit via the Rapid7 installer,
   radare2 from source, OWASP ZAP, and git-based tools (Responder, commix, spiderfoot, …).
   Fault-tolerant: individual failures are summarized at the end, never abort the run.
7. `scripts/07-verify.sh` — end-to-end checks (see below).

## Managing the stack

```bash
./start-stack.sh        # systemctl start llama-cyberstrike + hexstrike
./stop-stack.sh         # stop both
sudo systemctl status llama-cyberstrike hexstrike
journalctl -u llama-cyberstrike -f      # model server logs
journalctl -u hexstrike -f              # tools server logs
```

Both services auto-start on boot and restart on failure. The historical service name
`llama-cyberstrike` is retained for compatibility; it now serves Qwen3.8.

## Using the agent

```bash
opencode                                  # interactive TUI (model: Qwen3.8-27B local)
opencode run "list your available MCP tools"
opencode run "run a quick nmap -sV scan against scanme.nmap.org and summarize open ports"
```

The API model alias is `pharaoh-agent`. Reasoning defaults to `xhigh`; generation uses the
model author's recommended thinking-mode sampling (`temp=1.0`, `top_p=0.95`, `top_k=20`,
`min_p=0`). OpenCode allows up to 32,768 output tokens for reasoning plus the final response.

## Verification checklist (run `./scripts/07-verify.sh`)

1. `curl localhost:8000/v1/models` returns the `pharaoh-agent` model id.
2. Chat completion `"say OK"` returns non-empty text with enough tokens for reasoning.
3. HexStrike tool list includes `nmap`, `nuclei`, `sqlmap`.
4. `opencode run "list your available MCP tools"` shows HexStrike tools.
5. Real test: nmap scan of `scanme.nmap.org` executed through the MCP tool.

The verifier waits for service readiness (llama.cpp can take minutes to load the model),
retries the two agent-based checks up to 3 times, and pins the exact MCP tool names in its prompts.

## Swapping the model later

1. Download a new GGUF into `~/models`.
2. Edit `ExecStart` in `/etc/systemd/system/llama-cyberstrike.service`
   (point `-m` at the new file; tune `-c`/`-ngl` and sampling as needed).
3. `sudo systemctl daemon-reload && sudo systemctl restart llama-cyberstrike`.
4. Keep `--alias pharaoh-agent` to avoid changing OpenCode, or update `config/opencode.json`
   and rerun `scripts/05-install-opencode.sh` if you change the alias.

To change the default downloaded model in the installer, update `HF_REPO` and
`MODEL_FILENAME` in `scripts/common.sh` together with the model metadata and limits in
`config/opencode.json` and `systemd/llama-cyberstrike.service`.

> VRAM/RAM note: the configured context is **131,072 tokens** with **q8_0-quantized KV cache**
> (`--cache-type-k q8_0 --cache-type-v q8_0`, flash attention on). Qwen3.8 natively supports
> 262,144 tokens, but the larger context is not enabled by default on the 48 GB VRAM target.
> Check actual model, KV, and compute-buffer usage with `nvidia-smi` before raising `-c`.

## Troubleshooting

| Symptom                                        | Fix                                                                                          |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **GPU OOM** on service start                   | Lower context: `-c 65536` or `-c 32768`; use a Q6_K/Q4_K GGUF; or reduce offload with `-ngl` |
| **System RAM exhausted** / builds OOM-killed   | Keep the default `-c 131072` + q8_0 KV cache; add a swapfile for headroom                    |
| `unknown model architecture` / missing reasoning flags | Qwen3.8 needs a recent llama.cpp — rerun step 1 to upgrade the managed installation     |
| MCP tool call fails instantly with **"Timed out, retry."** | `config/opencode.json` sets `"timeout": 3600000`; step 4 also patches the bridge HTTP timeout to 1800 s |
| Step 7 verify fails with agent reading `logs/<timestamp>/…` | Cold start race — the verifier waits for `/v1/models` + `/health` and retries agent checks |
| `llama-server` fails with missing `libcudart`  | Install CUDA runtime (`nvidia-cuda-toolkit`) or re-run step 1 (it fetches the cudart bundle)  |
| `GLIBC_2.38 not found` from prebuilt binary    | Current llama.cpp prebuilts may target Ubuntu 24.04; step 1 detects this and falls back to source |
| nvcc fails with `cannot execute cc1plus`       | gcc/g++ version skew: `sudo apt install g++-$(gcc -dumpversion)` — step 1 does this automatically |
| **Model 404** at `/v1/chat/completions`        | The API alias is `pharaoh-agent`; keep `--alias pharaoh-agent` in the systemd unit            |
| **MCP not connecting** in opencode             | Check `systemctl status hexstrike`, then `curl localhost:8888/health`; opencode uses the stdio bridge |
| Hugging Face download stalls                   | Re-run step 2 — the Hugging Face CLI resumes partial downloads                                |
| `opencode` not found                           | Ensure npm global bin is on PATH: `npm config get prefix` → add `<prefix>/bin` to `~/.bashrc`  |
| Chat API returns **empty `content`**           | Reasoning consumes tokens first. Give it enough `max_tokens` (≥512 for smoke tests; much more for real tasks) |
| apt hangs on **wireshark-common** during step 6 | Already handled: the installer pre-seeds the debconf answer (`install-setuid=false`)          |
| radare2 build fails with `ccache gcc cannot create executables` | Handled: step 6 builds radare2 with `CCACHE_DISABLE=1`                              |

## Repo layout

```
├── install.sh                  # master installer (idempotent)
├── start-stack.sh / stop-stack.sh
├── config/opencode.json        # opencode provider + MCP config template
├── systemd/                    # unit templates (user/home substituted at install)
│   ├── llama-cyberstrike.service
│   └── hexstrike.service
└── scripts/
    ├── common.sh               # model identity + logging + shared helpers
    ├── 01-install-llamacpp.sh
    ├── 02-download-model.sh
    ├── 03-setup-services.sh
    ├── 04-install-hexstrike.sh
    ├── 05-install-opencode.sh
    ├── 06-install-all-tools.sh  # full ~120-tool HexStrike toolset
    └── 07-verify.sh
```

## Legal note

The HexStrike tooling and the Qwen3.8 abliterated model are for **authorized security testing
only** (your own systems, labs, or written-permission engagements). `scanme.nmap.org`
is explicitly provided by the Nmap project for scan testing.
