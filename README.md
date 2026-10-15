# LLM Baseline Benchmark (LBB)

CLI tool for standardized LLM performance benchmarking against vLLM / SGLang inference servers.

**Agentic simulation is the primary focus.** LBB replays *real agent sessions* — most importantly **real coding-agent trajectories** (OpenAI-format traces from NVIDIA SWE-Hero and similar datasets), as well as ShareGPT conversations and Mooncake production traces — to measure serving performance under realistic agent workloads (multi-turn, tool calls, context that compounds turn over turn). Synthetic single-turn and multi-turn scenarios are also supported for baseline load testing.

---

## ⭐ Agentic Simulation (Main Use Case)

An agent is not a single chat call — it chains dozens to hundreds of LLM calls, each carrying **growing context** (prior turns served from KV cache, only new tokens prefilled) with interleaved **tool calls and code edits**. LBB's core purpose is to replay these real sessions so you can measure how an inference deployment behaves under production-like agent load, rather than under synthetic uniform prompts.

| Mode | Data | What it replays | Best for |
|------|------|-----------------|----------|
| **WEKA / AgentX** ⭐ *(main)* | WEKA hash_ids traces (SemiAnalysis `cc-traces-weka-*` on HuggingFace — 393 real Claude Code sessions) replayed by **NVIDIA aiperf** | Real agentic coding sessions with recorded **think-time**, subagent fan-out, and exact per-turn KV-block reuse structure — the InferenceX **AgentX** benchmark reproduced against your own deployment (regulation-valid `submission_valid` runs) | **AgentX-comparable agentic serving** — cache-dominated 100k+-context load, Interactivity/TTFT/cache-hit axes |
| **OpenAI trajectory** | OpenAI-format coding-agent traces ([NVIDIA SWE-Hero](https://huggingface.co/datasets/nvidia/SWE-Hero-openhands-trajectories), SWE-rebench, Open-SWE-Traces, …) | Real coding sessions: reasoning + tool calls + code edits; long context (ISL up to ~130K, short outputs) | Coding-agent serving under **saturation** load — closest to NVIDIA's AA-AgentPerf benchmark |
| **ShareGPT** | ShareGPT conversation JSON | Real multi-turn chat, turn-by-turn | Conversational-service serving |
| **Mooncake** | Mooncake production traces | Trace-timestamped tool-agent / conversation traffic | Production traffic replay |

ShareGPT / OpenAI / Mooncake modes use a **sustained-N concurrency model** (keep N sessions in flight, replay the whole dataset) and reuse recorded assistant turns (**Option B**), so runs are deterministic and measure serving timing only. The **WEKA mode instead preserves recorded think-time** (AgentX rules, enforced by aiperf): `concurrency` counts live session *trees*, so the instantaneous in-flight load is far lower than the same number under sustained-N — the two families are not directly comparable. See [Scenario Types](#scenario-types) for full details.

---

## Installation

Choose one of the following two methods.

---

### Method 1: Docker (Recommended)

No SGLang installation required. Run `docker_setup.sh` once to build the image, start the container, and register the `lbb` command.

**Prerequisites:** Docker

```bash
cd /path/to/lbb
bash docker_setup.sh
source ~/.bashrc
```

After installation, the `lbb` command always runs inside the container. The experience is identical to the Baremetal setup.

**Volume Structure:**

| Host Path | Container Path | Contents |
|-----------|----------------|----------|
| `./config/` | `/app/config` | `paths.yaml`, scenario files |
| `./logs/` | `/app/logs` | Background job metadata |
| `./result_data/` | `/result_data` | Benchmark result JSONL |
| `$HOME` | `$HOME` | User home directory (mounted at same path) |
| `~/.kube/` | `/root/.kube` | kubectl access (auto-skipped if directory is absent) |

To mount additional directories, add `-v` options to the `MOUNT_ARGS` block in `docker_setup.sh`:

```bash
MOUNT_ARGS=(
  ...
  -v "/data/models:/data/models"   # e.g., mount additional model directory
)
```

**Access the container:**

```bash
docker exec -it lbb-daemon /bin/bash
```

**Restart container / Update code:**

```bash
bash docker_setup.sh   # rebuild image + restart container
source ~/.bashrc
```

---

### Method 2: Baremetal

#### 1. Install LBB

```bash
cd /home/ubuntu/lbb
pip install -r requirements.txt
pip install -e .

# Optional — only for weka (AgentX) agentic scenarios; requires Python >= 3.11.
# (The Docker image ships with this preinstalled.)
pip install "aiperf==0.12.0"
```

> **Note:** If `aiperf` lives outside PATH (e.g. a separate Python 3.11+ venv), point LBB at it with `lbb config set aiperf_bin /path/to/aiperf`.

#### 2. Register `lbb` command and tab completion (recommended)

```bash
cat >> ~/.bashrc << 'EOF'
unalias lbb 2>/dev/null || true
lbb() { python3 -m lbb.cli "$@"; }
eval "$(python3 -m lbb.cli completion bash)"
EOF
source ~/.bashrc
```

> **Note:** Do not use `alias lbb='...'` — it causes a syntax error on `source ~/.bashrc`. Always use the function form above.

After registration, `lbb <Tab>` auto-completes commands and options.

---

## Quick Start

### Step 1: Configure

Set up model path, server info, and other settings in `config/paths.yaml`.

```bash
# Auto-detect from Kubernetes DynamoGraphDeployment (DGD)
lbb init

# Or configure manually (interactive prompts)
lbb init -i
```

After `lbb init`, `config/paths.yaml` is updated automatically. You can also edit it directly:

```yaml
# config/paths.yaml
model_path: /data/models/Qwen3-0.6B     # Model path or HF repo ID
served_model_name: Qwen/Qwen3-0.6B      # Model name used in API calls
model_fp: bf16                           # Precision label (used in result filenames)
result_dir: /result_data/results         # Docker: /result_data/... | BM: any absolute path
visualizer: 172.16.1.120:1229           # Visualizer URL (for lbb visualizer)
server:
  host: 10.233.70.221                   # Inference server host
  port: 8000                            # Inference server port
deployment:                              # Set automatically by lbb init (optional)
  type: aggregation                      #   aggregation or disaggregation
  replica: 2                             #   (aggregation) worker replicas
  tp: 4                                  #   (aggregation) GPUs per replica
  # type: disaggregation
  # prefill: 2                           #   prefill worker replicas
  # prefill_tp: 4                        #   GPUs per prefill worker
  # decode: 4                            #   decode worker replicas
  # decode_tp: 2                         #   GPUs per decode worker
```

> **For Docker, `result_dir`:** Set this to the container-internal path (`/result_data/...`). It maps to `./result_data/` on the host.

Set any key after the fact with:
```bash
lbb config set model_fp bf16
lbb config set visualizer 172.16.1.120:1229
lbb config show   # Verify current config
```

After `lbb init -i`, the tool also prompts for:
- `DGD name` — saved as `dgd_name` in `paths.yaml` (leave blank to skip)
- `Deployment type` — aggregation or disaggregation, with replica/TP counts

### Step 2: Generate scenario files

Use `lbb generate` to interactively create scenario YAML files. No manual YAML editing needed.

```bash
lbb generate
```

**Supported scenario types:**

| Type | Description |
|------|-------------|
| `single` | Single-turn with GSP dataset. Prompts for ISL, OSL, backend, KV cache hit rate, concurrency range. |
| `multi` | Multi-turn chat with accumulating context. Prompts for ISL, max ISL, OSL, backend, concurrency range. |
| `agentic` | **WEKA / AgentX** ⭐ *(main)*: replays SemiAnalysis WEKA traces via NVIDIA aiperf under AgentX rules (think-time preserved, cache-bust, `ignore_eos`). Prompts for corpus (HF alias / local truncated dir), backend label, concurrency sweep, duration, max context, seed.<br>**OpenAI trajectory**: replays real coding-agent traces (OpenAI format) turn-by-turn (sustained-N). Prompts for dataset file, backend, num_sessions sweep; analyzes ISL/OSL ranges.<br>**ShareGPT**: replays real ShareGPT JSON files turn-by-turn (sustained-N). Prompts for dataset file, backend, num_sessions sweep.<br>**Mooncake**: replays SGLang's mooncake production traces. Prompts for backend, workload, rounds, slowdown factor, output length, concurrency. |

**Single-turn generate flow:**
```
[Step 1] Scenario type        → single
[Step 2] Basic parameters     → ISL, OSL, num_groups, prompts_per_group, backend
[Step 3] KV cache hit rate    → target hit rate → auto-calculates prompt_length / question_len
                                (press Enter to skip)
[Step 4] Concurrency range    → start / end → selects from predefined list
[Step 5] Output filename      → saved as config/{name}_scenarios.yaml
```

**Agentic — WEKA / AgentX generate flow:** ⭐
```
[Step 1] Scenario type        → agentic
[Step 2] Agentic subtype      → weka
[Step 2] WEKA trace source    → [0] semianalysis_cc_traces_weka_062126        (full corpus, peaks ~1M ctx)
                                [1] semianalysis_cc_traces_weka_062126_256k   (requests >256k removed — for ≤262k models)
                                [2+] local truncated dirs (datasets/*)         → prints theoretical cache-hit upper bound
                                (or type any HF repo id / directory path)
[Step 3] Backend              → serving-engine label (vllm/sglang); aiperf is the load generator
[Step 4] Concurrency sweep    → comma-separated values (e.g. 8,16,32), one scenario per value
                                → shows Selected list, asks Confirm
[Step 5] Run parameters       → benchmark_duration (≥900s), max_context_length (match server --max-model-len), random_seed
[Step 6] Output filename      → saved as config/{name}_scenarios.yaml
```

> **Requires aiperf ≥ 0.12** on PATH (preinstalled in the Docker image; `paths.yaml` key `aiperf_bin` overrides the path). The HF corpora download and reconstruct on first run (can take tens of minutes — cached under `~/.cache/aiperf` afterwards, keyed by seed).
>
> **Small-context servers:** build a truncated local corpus first — `python3 scripts/build_weka_traces.py --max-context 32000 --out-dir datasets/weka_32k` (cuts each trace just before the first request exceeding the cap; prints a before/after distribution report). Local dirs run with `--unsafe-override` and are marked `Valid: N` (internal-only, not regulation-comparable).

**Agentic — Mooncake generate flow:**
```
[Step 1] Scenario type        → agentic
[Step 2] Agentic subtype      → mooncake
[Step 3] Basic parameters     → backend, mooncake_workload, mooncake_num_rounds,
                                mooncake_slowdown_factor, random_output_len, num_requests
[Step 4] max_concurrency range → start / end
[Step 5] Output filename      → saved as config/{name}_scenarios.yaml
```

Available agentic (mooncake) workloads: `toolagent`, `conversation`, `synthetic`, `mooncake`

**Agentic — ShareGPT generate flow:**
```
[Step 1] Scenario type        → agentic
[Step 2] Agentic subtype      → sharegpt   (default)
[Step 3] Dataset file         → pick from config/*.json
                                (train_100.json / train_500.json / train_1000.json)
                                → tool scans file and prints max ISL+OSL
                                  (helps you size vLLM --max-model-len)
[Step 4] Backend (label only) → vllm or sglang
[Step 5] num_sessions sweep   → start / end → selects from predefined list
                                (= concurrency, NOT total session count)
[Step 6] Output filename      → saved as config/{name}_scenarios.yaml
```

> **About `num_sessions` in ShareGPT**: This is the **concurrency level** (semaphore slots). The main phase always processes the entire JSON file; control total work by choosing a smaller/larger dataset (`train_100`/`500`/`1000`).

**Agentic — OpenAI Trajectory generate flow:** ⭐
```
[Step 1] Scenario type        → agentic
[Step 2] Agentic subtype      → openai
[Step 3] Dataset file         → pick from config/swe_openai_*.json
                                → tool analyzes ISL/OSL ranges
                                  (e.g. ISL 9k→104k, mean ~21k; size vLLM --max-model-len)
[Step 4] Backend (label only) → vllm or sglang
[Step 5] num_sessions sweep   → start / end  (= concurrency, sustained-N)
[Step 6] Output filename      → saved as config/{name}_scenarios.yaml
```

> **Building OpenAI trajectory datasets:** `config/swe_openai_*.json` files are generated from HuggingFace coding-agent datasets via `scripts/build_openai_trajectories.py` (seed-fixed random sampling; smaller sizes are nested subsets). They are large and gitignored — reproduce with `--seed 42`.

Review generated scenarios:
```bash
lbb list scenarios --type single
lbb list scenarios --type multi
lbb list scenarios --type agentic
lbb list scenarios --file my_scenarios.yaml
```

### Step 3: Run benchmarks

```bash
# Run all scenarios in a file (tab-complete the path)
lbb run --file config/my_scenarios.yaml

# Run by type
lbb run --type single
lbb run --type multi
lbb run --type agentic        # openai, sharegpt, and mooncake subtypes
lbb run --type all           # single + multi + agentic

# Run specific scenarios by name
lbb run --scenarios my_scenario_conc8,my_scenario_conc16

# Override server for this run only
lbb run --file config/my_scenarios.yaml --server-host 10.0.0.5 --server-port 8001

# Dry run — print command without executing
lbb run --file config/my_scenarios.yaml --dry-run

# Run in background
lbb run --file config/my_scenarios.yaml --background
```

> One of `--file`, `--type`, or `--scenarios` is required.
>
> For `--file`: use tab completion or a full/accurate relative path. Bare filenames are not recognized.

**Background job management:**
```bash
lbb jobs                            # List all jobs (includes Output Dir column)
lbb logs <job_id>                   # Print last 50 lines of logs
lbb logs <job_id> --follow          # Follow logs in real time
lbb stop <job_id>                   # Stop a running job (SIGTERM)
```

### Step 4: Analyze results

```bash
# Auto-select most recent run subfolder (default)
lbb analyze

# List run folders and pick one interactively
lbb analyze --list

# Analyze all files in result_dir (flat mode)
lbb analyze --all

# Analyze a specific directory path
lbb analyze /data/results/my_run

# Save a Markdown report
lbb analyze --output report_$(date +%Y%m%d).md
```

`lbb analyze` prints a header showing the run name and DGD name (if a `dgd_snapshot.yaml` is present in the run folder).

### Step 5: Open visualizer

```bash
lbb visualizer   # Opens visualizer URL from paths.yaml in the local browser
```

---

## Scenario Types

### Single-turn

| Parameter | Description |
|-----------|-------------|
| `prompt_length` | Shared system prompt length (tokens) — shared prefix for KV cache |
| `question_len` | Per-request unique question length (tokens) |
| `output_len` | Output length (tokens) |
| `num_groups` | Number of unique system prompt groups |
| `prompts_per_group` | Requests per group |
| `max_concurrency` | Max concurrent requests |
| `request_rate` | Request rate (req/s); `inf` = unlimited |
| `warmup_requests` | Warmup requests before benchmark (excluded from results) |

**KV cache hit rate formula:**
```
hit_rate = (1 - 1/prompts_per_group) × prompt_length / (prompt_length + question_len)
```

`lbb generate` auto-calculates `prompt_length` / `question_len` from a target hit rate.

### Multi-turn

| Parameter | Description |
|-----------|-------------|
| `initial_prompt_length` | System prompt length for the first turn (tokens) |
| `increment_per_turn` | Context added each turn (tokens) |
| `question_len` | Per-turn user question length (tokens) |
| `output_len` | Per-turn output length (tokens) |
| `num_turns` | Number of conversation turns |
| `max_concurrency` | Max concurrent requests |

### Agentic (WEKA / AgentX via aiperf) ⭐ — main agentic mode

SemiAnalysis WEKA traces — 393 real Claude Code sessions recorded as `hash_ids` KV-block structure — are replayed by **NVIDIA aiperf** (`aiperf profile --scenario inferencex-agentx-mvp`), driven and post-processed by `scripts/benchmark_simulator.py`. This reproduces the **InferenceX AgentX** benchmark against your own (e.g. Dynamo/K8s) deployment, with the same regulation set aiperf enforces: recorded **think-time preserved**, per-session-instance **cache-bust**, `ignore_eos`, t\* trajectory sampling, and a `submission_valid` stamp when the official HF corpus is used.

**How the data works:** traces carry no text — only per-request token counts and KV-block ids. aiperf deterministically synthesizes filler text (seeded slices of a fixed corpus) such that token counts and prefix-cache block reuse match the recording exactly, then sends OpenAI **chat completions** (streaming, `stream_options.include_usage`). Content differs from the original sessions; the serving-relevant load (prefill volume, cache reuse pattern, timing) is identical.

**Concurrency semantics (important):** `concurrency` = number of live session *trees* (root + subagents). Because think-time is replayed, instantaneous in-flight requests are far fewer (~1/6–1/9 observed) — do **not** compare these numbers with sharegpt/openai `num_sessions`.

**Corpus options:**
- `semianalysis_cc_traces_weka_062126` — full corpus (peaks up to ~1M context; needs a ≥1M-context server to keep every trace)
- `semianalysis_cc_traces_weka_062126_256k` — same 393 traces with >256k requests removed; the right pick for ≤262k-context models; still `Valid: Y`
- **Local truncated corpus** for small servers: `scripts/build_weka_traces.py --max-context <N> --out-dir datasets/weka_<N>` — suffix-cuts each trace before its first over-cap request, prints a before/after distribution report and the theoretical cache-hit upper bound. Runs with `--unsafe-override` → `Valid: N` (internal only).

#### Parameters

| Parameter | Description |
|-----------|-------------|
| `dataset_name` | Always `weka` |
| `weka_source` | HF corpus alias, HF repo id, or local trace directory |
| `concurrency` | Live session trees (AgentX lanes) — one scenario per sweep value |
| `benchmark_duration` | Run length in seconds (AgentX minimum 900; official runs use 1800) |
| `max_context_length` | Context cap passed to aiperf (match the server's `--max-model-len`; over-cap traces are dropped by aiperf) |
| `random_seed` | Fixed seed → deterministic synthesis + reconstruction-cache reuse |
| `backend` | Serving-engine label for results (`vllm`/`sglang`) — aiperf is the load generator |

#### Output

One-line JSONL summary aligned with the other scenario types (`agentic_weka_{model}_{fp}{dep_seg}_conc{C}_dur{D}_{ts}.jsonl`), plus weka-specific keys: `mean/median/p90/p99_interactivity_tok_s` (per-request decode rate — the SemiAnalysis "P90 Interactivity" axis), `theoretical_cache_hit_pct` / `measured_cache_hit_pct` (hash_ids upper bound vs server-usage-measured), `total_throughput`, `submission_valid`, `context_overflow_count`. Raw aiperf artifacts (per-request `profile_export.jsonl`, `server_metrics_export.json`) are preserved under `{result_dir}/aiperf/{run_stem}/`. `lbb analyze` shows weka rows with `Interact.`, `CacheHit%`, and `Valid` columns.

**Requirements:** `aiperf ≥ 0.12` (Python ≥ 3.11) on PATH — preinstalled in the LBB Docker image; bare-metal installs get an optional prompt in `scripts/setup.sh`, or set `aiperf_bin` in `paths.yaml`.

### Agentic (OpenAI Trajectory) — real coding-agent replay under saturation

OpenAI-format coding-agent trajectories (e.g. [NVIDIA SWE-Hero](https://huggingface.co/datasets/nvidia/SWE-Hero-openhands-trajectories), SWE-rebench, Open-SWE-Traces) are replayed turn-by-turn against `/v1/chat/completions` via `scripts/openai_replayer.py` (which wraps the shared sustained-N engine `scripts/replay_engine.py`). **Closest to NVIDIA's AA-AgentPerf benchmark**: unlike the WEKA mode it removes think-time (back-to-back turns), making it the saturation-load counterpart to WEKA's realistic-pacing replay.

**Why it matters:** a coding agent chains dozens–hundreds of LLM calls, each carrying growing context (prior turns from KV cache, only new tokens prefilled) with interleaved tool calls and code edits. Replaying recorded trajectories reproduces exactly this serving access pattern — the tools are *not* re-executed; the recorded tool results are fed back as the next input.

**Sustained-N concurrency model:** identical to ShareGPT — `num_sessions` = concurrency (semaphore slots); the whole dataset is replayed. Control total work by choosing `swe_openai_<source>_500/1000.json`.

**Option B replay:** each `assistant` generation is one measured turn. The request carries the full accumulated message prefix (system + user + all prior assistant/tool turns, **recorded verbatim**), and `max_tokens` is capped to the recorded turn length. The model's live output is measured for timing only and discarded — the recorded turn + tool result are fed forward, so the prefix stays byte-identical (KV-cache reuse + context growth reproduced). **No inter-turn think-time** (back-to-back, matching AA-AgentPerf's closed-loop model).

**Caveat:** requests do not send a `tools` schema (SWE-Hero records `tool_calls` but not tool definitions) — a minor ISL under-count.

**Datasets:** `config/swe_openai_*.json` are OpenAI-format trajectory samples drawn (seed-fixed, `--seed 42`) from HuggingFace coding-agent datasets. SWE-Hero files are reproducible via `scripts/build_openai_trajectories.py`; other sources use the same seed-fixed sampling adapted to each dataset's schema. Smaller sizes are nested subsets (e.g. `swe_openai_hero_500.json` ⊂ `swe_openai_hero_1000.json`). Files are large and **gitignored** (`config/swe_openai_*.json`).

**Prebuilt trace files** (in `config/`, ISL/OSL are `words × 1.4` peak-prefix estimates):

| File | Source (HuggingFace) | Traj | Size | ISL range (mean) | OSL range (mean) |
|------|----------------------|------|------|------------------|------------------|
| `swe_openai_hero_1000.json` | `nvidia/SWE-Hero-openhands-trajectories` | 1000 | 196 MB | 9k → 104k (~21k) | 3k → 25k (~7.5k) |
| `swe_openai_hero_500.json` | `nvidia/SWE-Hero-openhands-trajectories` | 500 | 98 MB | 11k → 104k (~21k) | 4k → 23k (~7.5k) |
| `swe_openai_rebench_1000.json` | `nebius/SWE-rebench-openhands-trajectories` | 1000 | 257 MB | 11k → 64k (~25k) | 3k → 28k (~8.4k) |
| `swe_openai_opentraces_1000.json` | `nvidia/Open-SWE-Traces` (openhands) | 1000 | 195 MB | 7k → 65k (~23k) | 1k → 24k (~4.6k) |
| `swe_openai_swesmith_1000.json` | `SWE-bench/SWE-smith-trajectories` | 1000 | 118 MB | 2k → 78k (~15k) | 0.3k → 26k (~3.9k) |
| `swe_openai_swenext_1000.json` | `TIGER-Lab/SWE-Next-SFT-Trajectories` | 1000 | 56 MB | 1k → 22k (~7k) | 0.1k → 4k (~0.8k) |
| `swe_openai_swegym_1000.json` | `SWE-Gym/OpenHands-SFT-Trajectories` | 491* | 34 MB | 2k → 35k (~8k) | 0.1k → 12k (~1.6k) |

\* SWE-Gym's success split yields only 491 usable trajectories; all are included.

#### Parameters

| Parameter | Description |
|-----------|-------------|
| `dataset_name` | Always `openai` |
| `dataset_path` | Path to OpenAI-format trajectory JSON (`config/swe_openai_*.json`) |
| `num_sessions` | Concurrency = semaphore slot count (sustained-N) |
| `backend` | `vllm` or `sglang` (label only) |
| `isl_min/mean/max_tokens_est`, `osl_mean_tokens_est` | (info only) ISL/OSL ranges of the dataset — peak prefix per trajectory, `words × 1.4` heuristic. Compare ISL max against vLLM `--max-model-len`. |

#### Output

Same single-line JSONL summary schema as ShareGPT, with `dataset` set to `"openai"`. Output filename: `agentic_openai_{model}_{fp}{dep_seg}_nsess{N}_{ts}.jsonl`.

### Agentic (Mooncake)

Agentic scenarios replay real production LLM traffic traces from the [Mooncake dataset](https://github.com/kvcache-ai/Mooncake) (Moonshot AI). Unlike single/multi scenarios which use synthetic GSP data with uniform request rates, agentic scenarios follow the original trace timestamps — requests arrive in bursts just like real production traffic.

**Key difference from single/multi:** Request timing is controlled by `--use-trace-timestamps` (not `--request-rate`). The unit of replay is a **session** (one user's conversation), and `mooncake_num_rounds` controls how many turns happen within each session.

#### Workload Types

| Workload | Traffic Pattern | ISL Behavior | Use Case |
|----------|----------------|--------------|----------|
| `toolagent` | Tool-calling agent loop: short request → tool result → short request, repeating | Grows each round as tool call history accumulates | Benchmarks Function calling / ReAct agent patterns |
| `conversation` | User–assistant back-and-forth dialogue over multiple rounds | Grows each round as chat history accumulates | Benchmarks ChatGPT-style conversational services |
| `synthetic` | Statistically generated requests matching trace ISL/OSL distributions (not real content) | Fixed per design | Controlled load testing with realistic length distributions |
| `mooncake` | Full Mooncake trace: mixed toolagent + conversation sessions as-is | Varies by session | Most realistic; closest to actual production traffic |

> Realism ranking: `mooncake` > `toolagent` > `conversation` > `synthetic`

#### Parameters

| Parameter | Description |
|-----------|-------------|
| `dataset_name` | Always `mooncake` |
| `mooncake_workload` | Workload type: `toolagent`, `conversation`, `synthetic`, `mooncake` |
| `mooncake_num_rounds` | Turns per session — same concept as `num_turns` in multi-turn. Each round appends the previous response to context, so ISL grows with each round. (default: 1) |
| `mooncake_slowdown_factor` | Time-stretches the trace timestamps. `1.0` = original speed, `2.0` = half the load (2× longer gaps between requests) |
| `random_output_len` | Output token length per turn |
| `num_requests` | Total number of sessions to replay |
| `max_concurrency` | Max concurrent sessions |
| `use_trace_timestamps` | Always `true` — disables `--request-rate`; scheduling follows original trace timing |
| `backend` | `sglang` (native) or `sglang-oai` (OpenAI-compatible, required for Dynamo environments) |

### Agentic (ShareGPT)

ShareGPT scenarios replay real multi-turn conversation JSON files (e.g. from the [ShareGPT dataset](https://huggingface.co/datasets/shareAI/ShareGPT-Chinese-English-90k)) against `/v1/chat/completions`. The replayer is `scripts/sharegpt_replayer.py` — a standalone async client (aiohttp streaming SSE, asyncio.Semaphore) — NOT bench_serving.py.

**Sustained-N concurrency model:**
- `num_sessions` = **concurrency only** (semaphore slot count). NOT the total sessions to process.
- The main phase always processes the **entire dataset**. Control total work by slicing the JSON file (see `config/train_100.json`, `train_500.json`, `train_1000.json`).
- One session ends → semaphore slot opens → next session enters immediately → average concurrency stays at N for the whole run.

**Option B replay** (responses are deterministic across runs):
- Each session's turns are sequential (multi-turn order preserved).
- For each turn, we send `{user₁, asst₁, …, userₙ}` as messages, where prior assistant turns use ShareGPT's `gpt` text (the actual model output is discarded — TTFT/tokens are measured but not fed back into history).

**Warmup:**
- The tail `num_sessions` sessions of the dataset are fired concurrently before the main phase (first turn only of each).
- Warmup sessions are also re-replayed during the main phase (intentional — sustained-N model treats the whole dataset uniformly).

**Backend label:**
- Restricted to `vllm` or `sglang`. The replayer always hits `/v1/chat/completions` regardless of label — it's used only for filename/result table tagging.

**Datasets bundled in `config/`:**

| File | Sessions | Approximate replay time @ concurrency=8 |
|------|----------|------------------------------------------|
| `train_100.json` | 100 | ~10 min |
| `train_500.json` | 500 | ~55 min |
| `train_1000.json` | 1000 | ~1.8 hr |

(Approximate — assumes ~6.7s wall clock per turn @ concurrency=8 from prior Qwen3-30B-A3B disagg measurements.)

#### Parameters

| Parameter | Description |
|-----------|-------------|
| `dataset_name` | Always `sharegpt` |
| `dataset_path` | Path to ShareGPT JSON file (relative to project root or absolute) |
| `num_sessions` | Concurrency = semaphore slot count (peak/sustained concurrent sessions) |
| `backend` | `vllm` or `sglang` (label only) |
| `max_context_tokens_est` | (info only, agentic) Auto-computed max ISL+OSL of the dataset, in estimated tokens (`words × 1.4` BPE heuristic). Use this as a floor for vLLM `--max-model-len`. |

#### Output

A single-line JSONL summary with the following keys:
- `concurrency`, `num_sessions_processed`, `num_sessions_failed`, `num_turns_total`
- `mean_ttft_ms`, `median_ttft_ms`, `p95_ttft_ms`, `p99_ttft_ms`
- `output_throughput`, `request_throughput`
- `mean_isl_tokens`, `mean_osl_tokens`
- `mean_session_time_s`, `total_replay_time_s`
- `dataset` ("sharegpt"), `dataset_path`

#### Mid-run logging

The simulator prints a `[SCENARIO]` banner at start and a `[RESULT]` banner at end with the key metrics. The replayer prints per-session progress:
```
[setup] dataset=.../train_100.json total=100 concurrency=8 warmup=8 (streamed)
[warmup] firing 8 concurrent sessions...
[warmup] done in 12.4s
[main] starting sustained replay: 100 sessions @ concurrency=8 ...
[main] 1/100 done session=vMqf2Wq (launch_idx=1) turns=1 time=7.72s ttft_mean=63.4ms isl_mean=15 osl_mean=1100
[main] 2/100 done session=8jD1Gjz (launch_idx=5) turns=2 time=14.97s ttft_mean=339.6ms isl_mean=384 osl_mean=1336
...
[done] wrote .../sharegpt_..._nsess8_....jsonl
```

If a turn or session fails (e.g. HTTP 400 for prompt-too-long), `[turn-fail]` / `[session-fail]` lines appear; the run continues and writes the summary from surviving sessions.

---

## Output Filename Formats

The deployment topology tag is inserted after `{fp}` when `deployment:` is set in `paths.yaml` (via `lbb init`). Omitted for legacy/unconfigured environments.

```
# single — aggregation
{type}_{engine}_{model}_{fp}_replica{r}_tp{tp}_isl{isl}_osl{osl}_conc{conc}_groups{g}_ppg{p}_{YYYYMMDD_HHMMSS}.jsonl

# single — disaggregation (prefill/decode split)
{type}_{engine}_{model}_{fp}_p{prefill}_tp{prefill_tp}_d{decode}_tp{decode_tp}_isl{isl}_osl{osl}_conc{conc}_groups{g}_ppg{p}_{YYYYMMDD_HHMMSS}.jsonl

# multi — aggregation
{type}_{engine}_{model}_{fp}_t{turns}_replica{r}_tp{tp}_isl{init}_{max}_osl{osl}_conc{conc}_groups{g}_ppg{p}_{YYYYMMDD_HHMMSS}.jsonl

# multi — disaggregation
{type}_{engine}_{model}_{fp}_t{turns}_p{prefill}_tp{prefill_tp}_d{decode}_tp{decode_tp}_isl{init}_{max}_osl{osl}_conc{conc}_groups{g}_ppg{p}_{YYYYMMDD_HHMMSS}.jsonl

# agentic — aggregation
{type}_{engine}_{model}_{fp}_replica{r}_tp{tp}_{workload}_r{rounds}_conc{c}_{YYYYMMDD_HHMMSS}.jsonl

# agentic — disaggregation
{type}_{engine}_{model}_{fp}_p{prefill}_tp{prefill_tp}_d{decode}_tp{decode_tp}_{workload}_r{rounds}_conc{c}_{YYYYMMDD_HHMMSS}.jsonl

# agentic (sharegpt) — aggregation or disaggregation
sharegpt_{engine}_{model}_{fp}{dep_seg}_nsess{N}_{YYYYMMDD_HHMMSS}.jsonl
   # N = concurrency (sustained-N model)
   # dep_seg follows the same rules as other scenarios (replica{r}_tp{tp} or p{p}_tp{ptp}_d{d}_tp{dtp})

# agentic (openai trajectory) — aggregation or disaggregation
agentic_openai_{model}_{fp}{dep_seg}_nsess{N}_{YYYYMMDD_HHMMSS}.jsonl
   # N = concurrency (sustained-N model); no engine/backend segment

# legacy (no deployment configured)
{type}_{engine}_{model}_{fp}_isl{isl}_osl{osl}_conc{conc}_groups{g}_ppg{p}_{YYYYMMDD_HHMMSS}.jsonl
```

`lbb analyze` shows a **Deployment** column (`replica2_tp4` or `p2_tp4/d4_tp2`). Legacy files show `-`.

---

## CLI Reference

| Command | Description |
|---------|-------------|
| `lbb init` | Auto-detect config from kubectl DGD |
| `lbb init -i` | Interactive manual config |
| `lbb generate` | Interactively generate a scenario YAML file |
| `lbb run --file FILE` | Run all scenarios in a file |
| `lbb run --type TYPE` | Run by type (`single`/`multi`/`agentic`/`all`) |
| `lbb run --scenarios NAME,...` | Run specific scenarios |
| `lbb run --dry-run` | Print command without executing |
| `lbb run --background` | Run in background |
| `lbb jobs` | List background jobs |
| `lbb logs JOB_ID [--follow]` | View job logs |
| `lbb stop JOB_ID` | Stop a running job |
| `lbb analyze` | Analyze most recent run subfolder |
| `lbb analyze --list` | List run folders, select interactively |
| `lbb analyze --all` | Analyze entire result_dir (flat mode) |
| `lbb analyze [DIR]` | Analyze a specific directory |
| `lbb analyze --output FILE` | Save Markdown report |
| `lbb list scenarios --type TYPE` | List scenarios by type |
| `lbb list scenarios --file FILE` | List scenarios by file |
| `lbb list results [--limit N]` | List run folders (or flat JSONL files) |
| `lbb status server` | Check inference server health |
| `lbb config show` | Show current `paths.yaml` |
| `lbb config set KEY VALUE` | Update a config key |
| `lbb visualizer` | Open visualizer in browser |

For full option details, see [docs/CLI_USAGE.md](docs/CLI_USAGE.md) or run `lbb <command> --help`.

---

## Project Structure

```
lbb/
├── lbb/                              # Python package (CLI)
│   ├── cli.py                        # Entry point
│   ├── commands/                     # Command implementations
│   │   ├── run.py                    # lbb run
│   │   ├── generate_cmd.py           # lbb generate
│   │   ├── list_cmd.py               # lbb list
│   │   ├── analyze.py                # lbb analyze
│   │   ├── jobs_cmd.py               # lbb jobs / logs / stop
│   │   ├── init_cmd.py               # lbb init
│   │   ├── config_cmd.py             # lbb config
│   │   ├── status.py                 # lbb status
│   │   └── visualizer_cmd.py         # lbb visualizer
│   └── utils/
│       ├── config.py                 # YAML read/write
│       └── paths.py                  # Project root / config dir resolution
├── config/
│   ├── paths.yaml                    # Server, model, and path config
│   ├── train_100.json / train_500.json / train_1000.json   # ShareGPT replay datasets (sliced)
│   ├── swe_openai_<source>_<N>.json  # OpenAI coding-agent trajectory datasets (gitignored, built by build_openai_trajectories.py)
│   ├── single_turn_scenarios.yaml    # Built-in single-turn scenarios
│   ├── multi_turn_scenarios.yaml     # Built-in multi-turn scenarios
│   └── *_scenarios.yaml             # Any additional user-created scenario files
├── logs/                             # Background job logs and metadata
├── result_data/                      # Benchmark results (Docker mount point)
├── scripts/
│   ├── benchmark_simulator.py        # Loads scenarios, builds args, runs bench_serving.py / replayers
│   ├── replay_engine.py             # Shared sustained-N async engine (aiohttp SSE + Semaphore + warmup)
│   ├── openai_replayer.py           # OpenAI coding-agent trajectory replayer (wraps replay_engine)
│   ├── openai_dataset.py            # ISL/OSL range analysis for OpenAI trajectory datasets
│   ├── build_openai_trajectories.py # Builds swe_openai_*.json from HuggingFace coding-agent datasets
│   ├── sharegpt_replayer.py         # ShareGPT JSON replayer (wraps replay_engine)
│   ├── bench_serving.py              # SGLang benchmark client (patched, embedded)
│   └── analyze_results.py            # Parses JSONL filenames, computes metrics, renders table
├── Dockerfile                        # Docker image definition
├── docker_setup.sh                   # One-shot Docker setup script
├── requirements.txt
└── setup.py
```

---

## References

- SGLang: https://github.com/sgl-project/sglang
- vLLM: https://github.com/vllm-project/vllm
