# The Pharaoh Agent V5 — Local AI Pentesting Stack

A fully local, self-hosted AI pentesting stack for **Ubuntu 22.04** with an NVIDIA GPU
(tested target: **96 GB RAM / 48 GB VRAM, CUDA working**).

## Architecture

```
┌─────────────┐   OpenAI API    ┌──────────────────────────────┐
│  opencode   │ ──────────────► │ llama.cpp  (llama-server)     │
│  (agent CLI)│  localhost:8000 │ Huihui-CyberStrike-OffSec-35B │
│             │                 │ -abliterated (GGUF Q4_K_M)    │
│             │   MCP (stdio)   └──────────────────────────────┘
│             │ ──────────────► ┌──────────────────────────────┐
└─────────────┘                 │ HexStrike AI (MCP tools)      │
                                │ hexstrike_server.py  :8888    │
                                │ nmap · nuclei · sqlmap · ...  │
                                └──────────────────────────────┘
```

| Component    | What it is                                                        | Port / transport          |
| ------------ | ----------------------------------------------------------------- | ------------------------- |
| llama.cpp    | Serves the CyberStrike 35B Q4_K_M GGUF, OpenAI-compatible API     | `0.0.0.0:8000` (HTTP)     |
| HexStrike AI | MCP security-tools server (nmap, nuclei, sqlmap, gobuster, …)     | `0.0.0.0:8888` (HTTP API) |
| opencode     | Terminal AI agent wired to the local model + HexStrike MCP tools  | MCP over stdio            |

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
   `cmake -DGGML_CUDA=ON`. Verifies `llama-server --version`.
2. `scripts/02-download-model.sh` — installs `huggingface-hub`, downloads only the
   `*Q4_K_M*` GGUF (~21 GB) of `huihui-ai/Huihui-CyberStrike-OffSec-35B-abliterated-GGUF`
   into `~/models` (skips MTP/speculative-decoding extras).
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

Both services auto-start on boot and restart on failure.

## Using the agent

```bash
opencode                                  # interactive TUI (model: CyberStrike-35B local)
opencode run "list your available MCP tools"
opencode run "run a quick nmap -sV scan against scanme.nmap.org and summarize open ports"
```

## Verification checklist (run `./scripts/07-verify.sh`)

1. `curl localhost:8000/v1/models` returns the CyberStrike model id.
2. Chat completion `"say OK"` returns text.
3. HexStrike tool list includes `nmap`, `nuclei`, `sqlmap`.
4. `opencode run "list your available MCP tools"` shows HexStrike tools.
5. Real test: nmap scan of `scanme.nmap.org` executed through the MCP tool.

The verifier waits for service readiness (llama.cpp can take minutes to load the model),
retries the two agent-based checks up to 3 times (local models are non-deterministic at
tool calling), and pins the exact MCP tool names in its prompts.

## Swapping the model later

1. Download a new GGUF into `~/models`.
2. Edit `ExecStart` in `/etc/systemd/system/llama-cyberstrike.service`
   (point `-m` at the new file; tune `-c`/`-ngl` as needed).
3. `sudo systemctl daemon-reload && sudo systemctl restart llama-cyberstrike`.

> VRAM/RAM note: the default context is **131 072 tokens** with **q8_0-quantized KV cache**
> (`--cache-type-k q8_0 --cache-type-v q8_0`, flash attention on). Do **not** raise `-c`
> to the model's native 262 144 without quantization — on the 96 GB RAM / 48 GB VRAM
> reference machine that exhausted all RAM and swap and got processes OOM-killed.
> With 131 072 + q8_0 KV the stack leaves plenty of headroom for heavy tool builds.

## Troubleshooting

| Symptom                                        | Fix                                                                                          |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **GPU OOM** on service start                   | Lower context: `-c 32768`; or partial offload `-ngl 60`; check `nvidia-smi` for other tenants |
| **System RAM exhausted** / builds OOM-killed   | Context too large. Use the default `-c 131072` + q8_0 KV cache; add a swapfile for headroom   |
| MCP tool call fails instantly with **"Timed out, retry."** | opencode's MCP request timeout defaults to 5 s — `config/opencode.json` sets `"timeout": 3600000`. Also step 4 patches the MCP bridge HTTP timeout to 1800 s |
| Step 6 verify fails with agent reading `logs/<timestamp>/…` | Cold start race — the verifier now waits for `/v1/models` + `/health` and retries agent checks |
| `llama-server` fails with missing `libcudart`  | Install CUDA runtime (`nvidia-cuda-toolkit`) or re-run step 1 (it fetches the cudart bundle)  |
| `GLIBC_2.38 not found` from prebuilt binary    | Current llama.cpp prebuilts target Ubuntu 24.04; step 1 detects this and auto-falls back to a source build |
| nvcc fails with `cannot execute cc1plus`       | gcc/g++ version skew (e.g. gcc 12 + g++ 11): `sudo apt install g++-$(gcc -dumpversion)` — step 1 now does this automatically |
| **Model 404** at `/v1/chat/completions`        | The opencode config uses model id `cyberstrike`; llama.cpp serves it under the file alias — keep `--alias cyberstrike` in the unit (already set) |
| **MCP not connecting** in opencode             | Check `systemctl status hexstrike`, then `curl localhost:8888/health`; opencode talks to HexStrike via stdio (`hexstrike_mcp.py`) which bridges to `:8888` — the service must be up |
| Hugging Face download stalls                   | `export HF_HUB_ENABLE_HF_TRANSFER=1` (installer already tries) or re-run step 2 — it resumes   |
| `opencode` not found                           | Ensure npm global bin is on PATH: `npm config get prefix` → add `<prefix>/bin` to `~/.bashrc`  |
| Chat API returns **empty `content`**            | The model is a reasoning model — output first goes to `reasoning_content`. Give it enough `max_tokens` (e.g. ≥512) or it spends the whole budget thinking |
| apt hangs on **wireshark-common** during step 6 | Already handled: the installer pre-seeds the debconf answer (`install-setuid=false`) |
| radare2 build fails with `ccache gcc cannot create executables` | Handled: step 6 builds radare2 with `CCACHE_DISABLE=1` |

## Repo layout

```
├── install.sh                  # master installer (idempotent)
├── start-stack.sh / stop-stack.sh
├── config/opencode.json        # opencode provider + MCP config template
├── systemd/                    # unit templates (user/home substituted at install)
│   ├── llama-cyberstrike.service
│   └── hexstrike.service
└── scripts/
    ├── common.sh               # logging + helpers
    ├── 01-install-llamacpp.sh
    ├── 02-download-model.sh
    ├── 03-setup-services.sh
    ├── 04-install-hexstrike.sh
    ├── 05-install-opencode.sh
    ├── 06-install-all-tools.sh  # full ~120-tool HexStrike toolset
    └── 07-verify.sh
```

## Legal note

The HexStrike tooling and the CyberStrike model are for **authorized security testing
only** (your own systems, labs, or written-permission engagements). `scanme.nmap.org`
is explicitly provided by the Nmap project for scan testing.
