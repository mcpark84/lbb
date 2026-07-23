# LLM Baseline Benchmark (LBB)

CLI tool for standardized LLM performance benchmarking against vLLM / SGLang inference servers.

**Agentic simulation is the primary focus.** LBB replays *real agent sessions* — most importantly **real coding-agent trajectories** (OpenAI-format traces from NVIDIA SWE-Hero and similar datasets), as well as ShareGPT conversations and Mooncake production traces — to measure serving performance under realistic agent workloads (multi-turn, tool calls, context that compounds turn over turn). Synthetic single-turn and multi-turn scenarios are also supported for baseline load testing.

> **This repository ships only configuration, setup scripts, and docs.** The LBB
> implementation is distributed as a prebuilt Docker image
> (`danmcpark84/lbb:latest` on Docker Hub) — you do not build or install any source.

---

## ⭐ Agentic Simulation (Main Use Case)

An agent is not a single chat call — it chains dozens to hundreds of LLM calls, each carrying **growing context** (prior turns served from KV cache, only new tokens prefilled) with interleaved **tool calls and code edits**. LBB's core purpose is to replay these real sessions so you can measure how an inference deployment behaves under production-like agent load, rather than under synthetic uniform prompts.

| Mode | Data | What it replays | Best for |
|------|------|-----------------|----------|
| **OpenAI trajectory** ⭐ | OpenAI-format coding-agent traces ([NVIDIA SWE-Hero](https://huggingface.co/datasets/nvidia/SWE-Hero-openhands-trajectories), SWE-rebench, Open-SWE-Traces, …) | Real coding sessions: reasoning + tool calls + code edits; long context (ISL up to ~130K, short outputs) | **Coding-agent serving** — closest to NVIDIA's AA-AgentPerf benchmark |
| **ShareGPT** | ShareGPT conversation JSON | Real multi-turn chat, turn-by-turn | Conversational-service serving |
| **Mooncake** | Mooncake production traces | Trace-timestamped tool-agent / conversation traffic | Production traffic replay |

All agentic modes use a **sustained-N concurrency model** (keep N sessions in flight, replay the whole dataset) and reuse recorded assistant turns (**Option B**), so runs are deterministic and measure serving timing only. See [Scenario Types](#scenario-types) for full details.

---

## Installation

**Prerequisites:** Docker.

LBB runs entirely from a prebuilt Docker Hub image — no SGLang install, no source build.

```bash
git clone https://github.com/mcpark84/lbb.git
cd lbb
bash docker_setup.sh      # pulls danmcpark84/lbb:latest, starts lbb-daemon, installs the lbb command
source ~/.bashrc
```

`docker_setup.sh` does three things:
1. `docker pull danmcpark84/lbb:latest` (override with `LBB_IMAGE=... bash docker_setup.sh`)
2. Starts the `lbb-daemon` container with the volume mounts below
3. Installs an `lbb` wrapper at `~/.local/bin/lbb` and registers tab completion

After setup, the `lbb` command always runs inside the container — `lbb <Tab>` completes
commands and options, exactly like a native install.

> **Already have the image loaded locally** (e.g. air-gapped, or `docker load`ed a tar)?
> Use `bash docker_setup_with_image.sh` instead — it lists local images and lets you
> pick one by number rather than pulling from Docker Hub.

**Volume structure:**

| Host Path | Container Path | Contents |
|-----------|----------------|----------|
| `./config/` | `/app/config` | `paths.yaml`, scenario files, replay datasets |
| `./logs/` | `/app/logs` | Background job metadata |
| `./result_data/` | `/result_data` | Benchmark result JSONL |
| `$HOME` | `$HOME` | User home directory (mounted at same path) |
| `~/.kube/` | `/root/.kube` | kubectl access (auto-skipped if directory is absent) |

> The host `./config/` is bind-mounted **over** the image's `/app/config`, so the
> scenario YAMLs and `paths.yaml` in this repo are what the container actually uses.
> Edit them on the host — no need to enter the container.

To mount additional directories (e.g. a model directory), add `-v` options to the
`MOUNT_ARGS` block in `docker_setup.sh`:

```bash
MOUNT_ARGS=(
  ...
  -v "/data/models:/data/models"
)
```

**Access the container shell:**

```bash
docker exec -it lbb-daemon /bin/bash
```

**Update to a newer image:**

```bash
bash docker_setup.sh      # re-pulls latest and restarts the container
source ~/.bashrc
```

### (Optional) Result visualizer

To view benchmark results in a browser, install the Inference Benchmark Visualizer
(also image-based). Point its `DATA_DIR` at the same directory as LBB's `result_dir`.

```bash
git clone https://github.com/mcpark84/ibv.git
cd ibv
bash docker_setup.sh      # pulls danmcpark84/ibv:v1.0 and starts it (default port 1229)
```

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

After `lbb init`, `config/paths.yaml` is created/updated automatically. You can also
copy the shipped sample and edit it directly:

```bash
cp config/paths.yaml.sample config/paths.yaml
```

```yaml
# config/paths.yaml
model_path: /data/models/Qwen3-0.6B     # Model path or HF repo ID
served_model_name: Qwen/Qwen3-0.6B      # Model name used in API calls
model_fp: bf16                           # Precision label (used in result filenames)
result_dir: /result_data                 # Container-internal path → maps to ./result_data on host
visualizer: 127.0.0.1:1229              # Visualizer URL (for lbb visualizer)
server:
  host: 127.0.0.1                       # Inference server host
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

> **`result_dir`:** set this to the container-internal path (`/result_data`). It maps to `./result_data/` on the host.

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
| `agentic` | **OpenAI trajectory** ⭐: replays real coding-agent traces (OpenAI format) turn-by-turn (sustained-N). Prompts for dataset file, backend, num_sessions sweep; analyzes ISL/OSL ranges.<br>**ShareGPT**: replays real ShareGPT JSON files turn-by-turn (sustained-N). Prompts for dataset file, backend, num_sessions sweep.<br>**Mooncake**: replays SGLang's mooncake production traces. Prompts for backend, workload, rounds, slowdown factor, output length, concurrency. |

**Single-turn generate flow:**
```
[Step 1] Scenario type        → single
[Step 2] Basic parameters     → ISL, OSL, num_groups, prompts_per_group, backend
[Step 3] KV cache hit rate    → target hit rate → auto-calculates prompt_length / question_len
                                (press Enter to skip)
[Step 4] Concurrency range    → start / end → selects from predefined list
[Step 5] Output filename      → saved as config/{name}_scenarios.yaml
```

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
                                (train_100.json bundled; add train_500 / train_1000 yourself)
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

> **Building OpenAI trajectory datasets:** `config/swe_openai_*.json` files are large and are **not shipped in this repo**. Build them into your host `config/` (bind-mounted into the container) with the dataset builder baked into the image:
> ```bash
> docker exec -it lbb-daemon python3 /app/scripts/build_openai_trajectories.py --seed 42
> ```
> Sampling is seed-fixed and reproducible; smaller sizes are nested subsets.

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
lbb analyze /result_data/my_run

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

### Agentic (OpenAI Trajectory) ⭐ — real coding-agent replay

OpenAI-format coding-agent trajectories (e.g. [NVIDIA SWE-Hero](https://huggingface.co/datasets/nvidia/SWE-Hero-openhands-trajectories), SWE-rebench, Open-SWE-Traces) are replayed turn-by-turn against `/v1/chat/completions`. **This is LBB's flagship agentic mode and the closest to NVIDIA's AA-AgentPerf agentic benchmark.**

**Why it matters:** a coding agent chains dozens–hundreds of LLM calls, each carrying growing context (prior turns from KV cache, only new tokens prefilled) with interleaved tool calls and code edits. Replaying recorded trajectories reproduces exactly this serving access pattern — the tools are *not* re-executed; the recorded tool results are fed back as the next input.

**Sustained-N concurrency model:** identical to ShareGPT — `num_sessions` = concurrency (semaphore slots); the whole dataset is replayed. Control total work by choosing `swe_openai_<source>_500/1000.json`.

**Option B replay:** each `assistant` generation is one measured turn. The request carries the full accumulated message prefix (system + user + all prior assistant/tool turns, **recorded verbatim**), and `max_tokens` is capped to the recorded turn length. The model's live output is measured for timing only and discarded — the recorded turn + tool result are fed forward, so the prefix stays byte-identical (KV-cache reuse + context growth reproduced). **No inter-turn think-time** (back-to-back, matching AA-AgentPerf's closed-loop model).

**Caveat:** requests do not send a `tools` schema (SWE-Hero records `tool_calls` but not tool definitions) — a minor ISL under-count.

**Datasets:** `config/swe_openai_*.json` are OpenAI-format trajectory samples drawn (seed-fixed, `--seed 42`) from HuggingFace coding-agent datasets. They are large and **not shipped in this repo** — build them with the in-image `build_openai_trajectories.py` (see the OpenAI generate flow above). Smaller sizes are nested subsets (e.g. `swe_openai_hero_500.json` ⊂ `swe_openai_hero_1000.json`).

**Prebuilt trace sources** (ISL/OSL are `words × 1.4` peak-prefix estimates):

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

Single-line JSONL summary. Output filename: `agentic_openai_{model}_{fp}{dep_seg}_nsess{N}_{ts}.jsonl`.

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

ShareGPT scenarios replay real multi-turn conversation JSON files (e.g. from the [ShareGPT dataset](https://huggingface.co/datasets/shareAI/ShareGPT-Chinese-English-90k)) against `/v1/chat/completions` using a standalone async client (aiohttp streaming SSE, asyncio.Semaphore).

**Sustained-N concurrency model:**
- `num_sessions` = **concurrency only** (semaphore slot count). NOT the total sessions to process.
- The main phase always processes the **entire dataset**. Control total work by slicing the JSON file (`config/train_100.json` is bundled; `train_500.json` / `train_1000.json` can be added).
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

(Approximate — assumes ~6.7s wall clock per turn @ concurrency=8 from prior Qwen3-30B-A3B disagg measurements. Larger slices `train_500.json` / `train_1000.json` can be added to `config/`.)

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

# agentic (mooncake) — aggregation
{type}_{engine}_{model}_{fp}_replica{r}_tp{tp}_{workload}_r{rounds}_conc{c}_{YYYYMMDD_HHMMSS}.jsonl

# agentic (mooncake) — disaggregation
{type}_{engine}_{model}_{fp}_p{prefill}_tp{prefill_tp}_d{decode}_tp{decode_tp}_{workload}_r{rounds}_conc{c}_{YYYYMMDD_HHMMSS}.jsonl

# agentic (sharegpt) — aggregation or disaggregation
sharegpt_{engine}_{model}_{fp}{dep_seg}_nsess{N}_{YYYYMMDD_HHMMSS}.jsonl
   # N = concurrency (sustained-N model)

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

## Repository Layout

This repo contains only the host-side files (configuration + setup + docs); all
implementation lives in the `danmcpark84/lbb` Docker image.

```
lbb/
├── config/
│   ├── paths.yaml.sample             # Copy to paths.yaml and edit (or use `lbb init`)
│   ├── sample_paths.yaml             # Minimal example config
│   ├── single_turn_scenarios.yaml    # Built-in single-turn scenarios
│   ├── multi_turn_scenarios.yaml     # Built-in multi-turn scenarios
│   ├── agentic_scenarios.yaml        # Built-in agentic scenarios
│   ├── custom_scenarios.yaml         # Example custom scenarios
│   └── train_100.json                # Bundled ShareGPT replay dataset (100 sessions)
├── docs/
│   └── CLI_USAGE.md                  # Full command reference
├── docker_setup.sh                   # Pull image from Docker Hub + start container
├── docker_setup_with_image.sh        # Use a locally-loaded image instead of pulling
└── README.md
```

Runtime directories `logs/` and `result_data/` are created by the setup script and
bind-mounted into the container.

---

## References

- SGLang: https://github.com/sgl-project/sglang
- vLLM: https://github.com/vllm-project/vllm
