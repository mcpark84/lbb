# LBB CLI Usage Guide

## Installation

LBB ships as a prebuilt Docker image on Docker Hub (`danmcpark84/lbb:latest`); no
source build is required. Clone this repo and run the setup script:

```bash
git clone https://github.com/mcpark84/lbb.git
cd lbb
bash docker_setup.sh      # pulls the image, starts lbb-daemon, installs the lbb wrapper
source ~/.bashrc
```

The setup script installs an `lbb` wrapper at `~/.local/bin/lbb` that forwards every
command into the running container, so the CLI experience below is identical whether
you invoke it from the host or inside the container. After setup, `lbb <Tab>` provides
command and option completion.

> **Note:** the `lbb` command is a real script (not a shell alias) so that bash tab
> completion works through `docker exec`.

---

## `lbb init` — Initial Setup

Sets model path, server info, etc. in `config/paths.yaml`.

### Auto-detect (default)

Queries the cluster's DynamoGraphDeployment (DGD) via kubectl and automatically detects model/server settings.

```bash
lbb init
```

Flow:
1. `kubectl get dgd` — list available DGDs
2. User selects a DGD
3. Parse `--model` and `--served-model-name` from DGD annotation
4. Parse frontend pod IP from `kubectl get po -A -o wide`
5. Confirm detected values and update `paths.yaml`

### Interactive manual input

```bash
lbb init -i
# or
lbb init --interactive
```

Prompts:
- SGLang directory (default: existing value)
- Model path (`model_path`)
- `served_model_name`
- Server host
- Server port
- DGD name (saved as `dgd_name`; leave blank to skip)
- Deployment type (`aggregation` or `disaggregation`), with replica/TP counts

> Both modes print the current `config/paths.yaml` after completing.

### `config/paths.yaml` key fields

```yaml
sglang_dir: /home/ubuntu/sglang         # SGLang repository path
model_path: /data/models/Qwen3-0.6B     # Model path (or HF repo ID)
served_model_name: Qwen/Qwen3-0.6B      # Model name used in API calls
model_fp: fp8                            # Model precision (included in result filenames)
result_dir: /data/results               # Directory for result JSONL files
server:
  host: 192.168.1.10                    # Server host
  port: 8000                            # Server port
```

---

## `lbb generate` — Generate Scenario Files

Interactively generates a scenario YAML file. If a target KV cache hit rate is provided, `prompt_length` and `question_len` are calculated automatically.

```bash
lbb generate
```

### Interactive flow

```
Step 1/5: Scenario type
  Type: [single]:

Step 2/5: Basic parameters
  ISL (Input Sequence Length, tokens) [1024]:
  OSL (Output Sequence Length, tokens) [1024]:
  num_groups (number of groups) [8]:
  prompts_per_group (P) [32]:
  Backend [vllm]:

Step 3/5: KV cache hit rate
  Target KV cache hit rate (0.0–1.0, or press Enter to skip) [skip]:
  → Entering 0.7 auto-calculates:
      prompt_length = 692  (shared prefix)
      question_len  = 332  (unique per request)
      Target hit rate ≈ 0.700

Step 4/5: Concurrency range
  Min concurrency [8]:
  Max concurrency [64]:
  → Selected: 8, 16, 32, 64

Step 5/5: Output filename
  Filename (saved as config/{name}_scenarios.yaml) [my_scenarios]:
```

#### Agentic (sharegpt) flow

After choosing `agentic` in Step 1, the subtype prompt defaults to `sharegpt`:

```
Step 1/6: Scenario type
  Type: [single]: agentic

Step 2/6: Agentic subtype
  subtype: [sharegpt]: (openai | sharegpt | mooncake)

Step 3/6: Dataset file (config/*.json)
  [0] train_100.json  (1.5 MB)
  [1] train_500.json  (6.7 MB)
  [2] train_1000.json (13.0 MB)
  Choose index: [0]:

  → Analyzing train_100.json for max ISL+OSL ...
    Sessions scanned: 100
    Max-context session: id=ZbgKKQg, turns=23
    Max ISL: 12450 words   Max OSL: 380 words   Max total: 12830 words
    → Estimated tokens (×1.4 BPE): ~17962 tokens
    → vLLM must run with --max-model-len >= 17962 to avoid prompt-too-long errors on this dataset.

Step 4/6: Backend (used as a label in result filenames)
  Available: ['vllm', 'sglang']
  backend [vllm]:

Step 5/6: num_sessions sweep range
  num_sessions start [8]:
  num_sessions end   [32]:
  → Selected: [8, 16, 32]
  (num_sessions = concurrency; the entire dataset is processed for each)

Step 6/6: Output filename
  Filename (saved as config/{name}_scenarios.yaml):
```

#### Agentic (openai) flow ⭐

Replays **real OpenAI-format coding-agent trajectories** (NVIDIA SWE-Hero and similar
datasets) turn-by-turn against `/v1/chat/completions`. This is the flagship agentic
mode (closest to NVIDIA's AA-AgentPerf). Same sustained-N model as ShareGPT; the
difference is the dataset (OpenAI messages with tool calls) and an ISL/OSL range
analysis step.

```
Step 1/6: Scenario type
  Type: [single]: agentic

Step 2/6: Agentic subtype
  subtype: [sharegpt]: openai

Step 3/6: Dataset file (config/swe_openai_*.json)
  [0] swe_openai_hero_1000.json       (196 MB)
  [1] swe_openai_rebench_1000.json    (257 MB)
  [2] swe_openai_opentraces_1000.json (195 MB)
  ...
  Choose index: [0]:

  → Analyzing swe_openai_hero_1000.json (ISL/OSL ranges) ...
    [openai dataset] swe_openai_hero_1000.json  (1000 trajectories)
      ISL range : 9.4k -> 104.0k tokens  (mean 21.2k)   # peak prefix per trajectory
      OSL range : 3.1k -> 25.2k tokens   (mean 7.5k)
      ! compare ISL max against vLLM --max-model-len

Step 4/6: Backend (used as a label in result filenames)
  Available: ['vllm', 'sglang']
  backend [vllm]:

Step 5/6: num_sessions sweep range
  num_sessions start [8]:
  num_sessions end   [32]:
  → Selected: [8, 16, 32]
  (num_sessions = concurrency; the entire dataset is processed for each)

Step 6/6: Output filename
  Filename (saved as config/{name}_scenarios.yaml):
```

> **Building OpenAI datasets:** `config/swe_openai_*.json` are generated from HuggingFace
> coding-agent datasets (SWE-Hero via `scripts/build_openai_trajectories.py --seed 42`).
> They are large and gitignored. See the README "Agentic (OpenAI Trajectory)" section for
> the per-file trace table and full behavior (Option B, `max_tokens` cap, no `tools` schema).

### Generated scenario naming

With KV cache hit rate: `{filename}_kv{pct}_conc{C}`

```
my_scenarios_kv70_conc8
my_scenarios_kv70_conc16
my_scenarios_kv70_conc32
```

Without hit rate: `{filename}_conc{C}`

```
my_scenarios_conc8
my_scenarios_conc16
```

### Example generated file

```yaml
# config/my_scenarios_scenarios.yaml
scenarios:
  - name: my_scenarios_kv70_conc8
    type: single
    description: "Single (ISL=1024, OSL=1024, KV hit=70%, conc=8)"
    parameters:
      prompt_length: 692
      question_len: 332
      output_len: 1024
      num_turns: 1
      num_groups: 8
      prompts_per_group: 32
      max_concurrency: 8
      request_rate: inf
    backend: vllm
```

### KV cache hit rate formula

```
hit_rate = (1 - 1/P) × prompt_length / ISL
```

- `P` = prompts_per_group
- `prompt_length` = shared prefix length within a group
- `question_len` = unique suffix per request (`ISL - prompt_length`)

Example: ISL=1024, P=32, target hit rate=0.7

```
sharing = 1 - 1/32 = 0.96875
prompt_length = round4(0.7 × 1024 / 0.96875) = 740
question_len  = 1024 - 740 = 284
Target hit rate = 0.96875 × 740/1024 ≈ 0.700
```

### Supported backends

| Backend | Description |
|---------|-------------|
| `vllm` | vLLM (default) |
| `sglang` | SGLang (OpenAI compatible) |
| `sglang-native` | SGLang native API |
| `sglang-oai` | SGLang OpenAI API |
| `lmdeploy` | LMDeploy |
| `trt` | TensorRT-LLM |
| `gserver` | GServer |
| `truss` | Truss |

> **Note (ShareGPT / OpenAI subtypes)**: For `agentic` scenarios with `dataset_name: sharegpt` or `dataset_name: openai`, the backend list is restricted to `vllm` and `sglang` because the replayer always uses `/v1/chat/completions` — the field is a result-filename/analysis label only.

### Concurrency selection range

Values between `min` and `max` are automatically selected from the predefined list:

```
8, 16, 32, 64, 96, 128, 256, 384, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048
```

---

## `lbb run` — Run Benchmarks

Runs scenarios defined in `config/*_scenarios.yaml`. Internally calls SGLang's `bench_serving.py`.

### Basic usage

```bash
# Run all scenarios in a file (Tab completes config/*scenarios.yaml)
lbb run --file config/single_turn_scenarios.yaml
lbb run --file config/je_scenarios.yaml

# Run all single-turn + multi-turn scenarios
lbb run --type all

# Agentic (ShareGPT) example — runs all nsess sweep scenarios from a file
lbb run --file config/my_sharegpt_scenarios.yaml

# Agentic (OpenAI trajectory) example — real coding-agent replay, nsess sweep
lbb run --file config/my_openai_scenarios.yaml

# Single-turn only
lbb run --type single

# Multi-turn only
lbb run --type multi

# Run specific scenarios (comma-separated)
lbb run --scenarios single_turn_1k_1k_conc4
lbb run --scenarios single_turn_1k_1k_conc4,single_turn_8k_1k_conc8
```

> One of `--file`, `--type`, or `--scenarios` is required.

### `--file` option details

`--file` runs all scenarios in the specified YAML file.

> **Path input notes**
>
> - **Tab completion (recommended):** Press Tab after `lbb run --file ` to auto-complete files in `config/` matching `*scenarios.yaml`.
> - **Manual input:** Providing only a filename will not work. Use the full path (`/home/ubuntu/lbb/config/single_turn_scenarios.yaml`) or an accurate relative path from the current directory (`config/single_turn_scenarios.yaml`).

```bash
lbb run --file <Tab>
# → config/custom_scenarios.yaml
# → config/je_scenarios.yaml
# → config/multi_turn_scenarios.yaml
# → config/single_turn_scenarios.yaml
```

### Specify server address directly

```bash
# Use a different server temporarily (overrides paths.yaml)
lbb run --file config/je_scenarios.yaml --server-host 10.233.91.80 --server-port 8001
lbb run --type single --server-host 10.233.91.80 --server-port 8001
```

### Other options

```bash
# Set result output directory (default: result_dir from paths.yaml)
lbb run --file config/je_scenarios.yaml --output-dir /tmp/my_results

# Print the command without executing
lbb run --file config/je_scenarios.yaml --dry-run

# Run in background (prints job ID, PID, log/stop instructions)
lbb run --file config/je_scenarios.yaml --background
```

Background run output example:
```
Job started: 20260326_123456
  PID:  12345
  Logs: lbb logs 20260326_123456
  Stop: lbb stop 20260326_123456
```

Logs are saved to `logs/{job_id}.log`. Check results after completion with `lbb jobs`.

### Options summary

| Option | Default | Description |
|--------|---------|-------------|
| `--file FILE` | none | Scenario YAML file (Tab completion supported) |
| `--type single\|multi\|all` | none | Scenario type |
| `--scenarios NAME,...` | none | Specific scenario names (comma-separated) |
| `--server-host HOST` | paths.yaml | Server host |
| `--server-port PORT` | paths.yaml | Server port |
| `--output-dir DIR` | result_dir from paths.yaml | Result output directory |
| `--dry-run` | False | Print command only, do not execute |
| `--background` | False | Run in background (prints job ID and log path) |

> One of `--file`, `--type`, or `--scenarios` is required.

---

## `lbb jobs` / `lbb logs` / `lbb stop` — Background Job Management

Monitor, inspect, and stop jobs started with `lbb run --background`.
Job metadata is stored in `logs/{job_id}.json`; execution logs in `logs/{job_id}.log`.

### List jobs

```bash
lbb jobs
```

Example output:
```
 Job ID            Status     Mode  Scenarios  Started               PID    Ended                Output Dir
 ────────────────  ─────────  ────  ─────────  ────────────────────  ─────  ────────────────────  ──────────────────────
 20260326_123456   running    bg    single     2026-03-26 12:34:56   12345                         run_20260326_123456
 20260325_090000   completed  bg    all        2026-03-25 09:00:00   -      2026-03-25 10:30:22   run_20260325_090000
 20260324_180000   failed     bg    multi      2026-03-24 18:00:00   -      2026-03-24 18:05:11   -
```

- If a `running` job's PID no longer exists, it is automatically updated to `failed`.
- **Output Dir** shows the run subfolder name where results were saved (the final path component of `output_dir` in job metadata).

### View logs

```bash
# Print last 50 lines (default)
lbb logs 20260326_123456

# Follow log in real time (tail -f)
lbb logs 20260326_123456 --follow

# Specify number of lines to print
lbb logs 20260326_123456 --lines 100
```

### Stop a job

```bash
lbb stop 20260326_123456
# Sent SIGTERM to PID 12345
```

Calling `stop` on an already completed or failed job prints the status and exits.

### Options summary

| Command | Option | Description |
|---------|--------|-------------|
| `lbb jobs` | — | List all jobs with Output Dir (status auto-refreshed) |
| `lbb logs JOB_ID` | `--follow / -f` | Follow log in real time |
| `lbb logs JOB_ID` | `--lines / -n N` | Number of lines to print (default: 50) |
| `lbb stop JOB_ID` | — | Stop a job with SIGTERM |

---

## `lbb analyze` — Analyze Results

Reads JSONL files from a run subfolder and renders an analysis table.

### Basic usage

```bash
# Auto-select the most recent run subfolder (default)
lbb analyze

# List run folders and pick one interactively
lbb analyze --list

# Analyze entire result_dir without subfolder selection (flat mode)
lbb analyze --all

# Analyze a specific directory path
lbb analyze /data/results/my_run
```

**Subfolder auto-detection behavior (when no path argument is given):**

| Condition | Behavior |
|-----------|----------|
| Run subfolders exist | Selects the most recently modified subfolder |
| Both subfolders and flat `.jsonl` files exist | Warns, uses subfolder mode |
| Only flat `.jsonl` files in `result_dir` | Analyzes `result_dir` directly |

### Run header

`lbb analyze` always prints a header showing the run name and DGD name before the results table:

```
Run: run_20260413_120000
DGD: vllm-disagg (snapshot saved)
------------------------------------------------------------
```

The DGD name is read from `dgd_snapshot.yaml` inside the run subfolder. If the snapshot file is absent, the DGD line is omitted.

### Output formats

```bash
# Default: Markdown table in terminal
lbb analyze

# Save as a Markdown report file
lbb analyze --output report.md

# Output as JSON
lbb analyze --format json
```

### Output column descriptions

| Column | Description |
|--------|-------------|
| Eng | Engine (vllm, trt, etc. — parsed from filename) |
| Scenario | `{model}_{fp}_isl{isl}_osl{osl}_conc{conc} ({filename})` |
| ISL | Input Sequence Length (tokens) |
| OSL | Output Sequence Length (tokens) |
| Conc | max_concurrency |
| TTFT Avg/Med | Time To First Token — average / median (ms) |
| ITL Avg/Med | Inter-Token Latency — average / median (ms) |
| Latency Avg/Med | End-to-End Latency — average / median (ms) |
| Throughput (req/s) | Requests processed per second |
| tok/s | Output tokens generated per second |
| Count | Total number of requests processed |

#### ShareGPT / OpenAI result columns (separate table)

When `lbb analyze` encounters sustained-N replay result files (filename starts with `sharegpt_...` or `agentic_openai_...`), they are rendered in a dedicated table with these columns (the `dataset` column shows `sharegpt` or `openai`):

| Column | Description |
|--------|-------------|
| Conc | Concurrency (semaphore slots = num_sessions YAML value) |
| Sess | num_sessions_processed (total sessions submitted in main phase) |
| Fail | num_sessions_failed (sessions that errored — typically 0) |
| TTFT P50/P99 | Time To First Token — median / 99th percentile (ms) |
| tok/s (out) | output_throughput — output tokens per second over total replay time |
| Avg ISL/OSL | Mean tokens per turn (ISL = prompt incl. growing history; OSL = response) |
| Session Time avg (s) | Mean wall clock per session that completed |
| Total Time (s) | total_replay_time_s — main phase wall clock (warmup excluded) |

### Result filename format

Metadata is parsed from filenames during analysis:

```
{type}_{engine}_{model}_{fp}_isl{isl}_osl{osl}_conc{conc}_groups{groups}_ppg{ppg}_{YYYYMMDD_HHMMSS}.jsonl
```

Example:
```
single_vllm_Qwen_Qwen3-0.6B_fp8_isl9216_osl1024_conc32_groups8_ppg4_20260311_120000.jsonl
```

Sustained-N agentic replay results use their own formats (`N` = concurrency):
```
# ShareGPT
sharegpt_{engine}_{model}_{fp}{dep_seg}_nsess{N}_{YYYYMMDD_HHMMSS}.jsonl

# OpenAI trajectory (no engine/backend segment)
agentic_openai_{model}_{fp}{dep_seg}_nsess{N}_{YYYYMMDD_HHMMSS}.jsonl
```

### Options summary

| Option/Argument | Default | Description |
|-----------------|---------|-------------|
| `[RESULTS_DIR]` | auto-detect latest run subfolder | Directory to analyze |
| `--list` | off | List run folders and select interactively |
| `--all` | off | Analyze entire `result_dir` (flat mode) |
| `--output / -o FILE` | none (stdout) | Save Markdown report to file |
| `--format markdown\|json` | markdown | Output format |

---

## `lbb list` — List Resources

### Scenario list

Running without options prints help. Use `--type` or `--file` to display results.

```bash
# No options → prints help
lbb list scenarios

# Filter by type (single)
lbb list scenarios --type single
lbb list scenarios --type agentic

# Filter by type (multiple, comma-separated)
lbb list scenarios --type single,multi
lbb list scenarios --type all        # show all

# Filter by file (Tab completion supported)
lbb list scenarios --file agentic_scenarios.yaml
lbb list scenarios --file agentic_scenarios      # .yaml can be omitted
```

> Both `--type` and `--file` support tab completion:
> ```bash
> lbb list scenarios --type <Tab>   # → all  agentic  multi  single  ...
> lbb list scenarios --file <Tab>   # → agentic_scenarios.yaml  ...
> ```

Example output (`--type single`):
```
Total 5 scenario(s) from 1 file(s):

  ── single_turn_scenarios.yaml (5) ──

 Name                          Type    ISL  OSL  Conc  P.Len  Q.Len  PPG  Backend
 ──────────────────────────── ──────  ───  ───  ────  ─────  ─────  ───  ───────
 single_turn_1k_1k_conc4       single   1K   1K     4   1024    128   10  vllm
 single_turn_1k_1k_conc8       single   1K   1K     8   1024    128   10  vllm
 single_turn_1k_1k_conc16      single   1K   1K    16   1024    128   10  vllm
```

Example output (`--type agentic` with a ShareGPT YAML file):
```
Total 3 scenario(s) from 1 file(s):

  ── my_sharegpt_scenarios.yaml (3) ──

 Name                  Dataset                 NSess  Backend
 ────────────────────  ──────────────────────  ─────  ───────
 my_sharegpt_nsess8    config/train_100.json       8  vllm
 my_sharegpt_nsess16   config/train_100.json      16  vllm
 my_sharegpt_nsess32   config/train_100.json      32  vllm
```

### Result file list

```bash
# List run subfolders from result_dir in paths.yaml
lbb list results

# List from a specific directory
lbb list results /data/results

# Show only the 10 most recent
lbb list results --limit 10
```

**Subfolder mode** (default when run subdirectories exist): shows a table with Run name, file count, DGD, and modification date. DGD is read from `dgd_snapshot.yaml` inside each run folder.

Example output (subfolder mode):
```
Results directory: /data/results
Total 3 run(s):

 Run                       Files  DGD              Date
 ─────────────────────────  ─────  ───────────────  ────────────────
 run_20260413_120000           12  vllm-disagg      2026-04-13 12:00
 run_20260412_090000            8  vllm-agg         2026-04-12 09:00
 run_20260411_180000            5  -                2026-04-11 18:00
```

**Flat mode** (fallback when no subdirectories exist): lists `.jsonl` files directly.

Example output (flat mode):
```
Results directory: /data/results
Total 5 result(s):

  • single_vllm_Qwen_Qwen3-0.6B_fp8_isl9216_osl1024_conc32_groups8_ppg4_20260311_120000.jsonl
    Modified: 2026-03-11 12:00:00
```

### Supported type list

```bash
lbb list types
```

### Options summary

| Command | Option | Description |
|---------|--------|-------------|
| `list scenarios` | `--type TYPE[,TYPE]` | Type filter, comma-separated or `all` (Tab completion) |
| `list scenarios` | `--file FILE` | File filter (`.yaml` optional, Tab completion) |
| `list results` | `[DIR]` | Directory to list (default: result_dir from paths.yaml) |
| `list results` | `--limit N` | Show only the N most recent runs/files |
| `list types` | — | List supported scenario types |

---

## `lbb status` — Check Status

```bash
# Server health check (GET /health)
lbb status server

# Print current paths.yaml settings summary
lbb status config
```

Example output (`lbb status server`):
```
Server: 10.233.91.104:8000

✓ Server connected
  Status: ok
```

---

## `lbb config` — Manage Configuration

Manage `config/paths.yaml` from the CLI.

### View settings

```bash
# Print full config as YAML
lbb config show
```

### Change a specific value

```bash
# Use dot notation for nested keys
lbb config set server.host 10.233.91.80
lbb config set server.port 8001
lbb config set model_fp fp16
lbb config set result_dir /new/result/path

# Numbers are automatically converted
lbb config set server.port 9000   # → stored as int 9000
```

### Edit with an editor

```bash
lbb config edit
# Opens in the editor set by $EDITOR (default: nano)
```

### Reset to defaults

```bash
lbb config reset
# Prompts for confirmation before resetting
```

### Options summary

| Command | Description |
|---------|-------------|
| `config show` | Print full config as YAML |
| `config set KEY VALUE` | Change a specific key |
| `config edit` | Edit directly in an editor |
| `config reset` | Reset to defaults |

---

## Help

Use `--help` on any command to see available options:

```bash
lbb --help
lbb init --help
lbb generate --help
lbb run --help
lbb analyze --help
lbb list --help
lbb list scenarios --help
lbb list results --help
lbb status --help
lbb config --help
lbb config set --help
lbb jobs --help
lbb logs --help
lbb stop --help
```

---

## Typical Workflow

```bash
# 1. Initial setup
lbb init                          # Auto-detect from kubectl DGD
# or
lbb init -i                       # Interactive manual input

# 2. Set model_fp if needed
lbb config set model_fp fp8

# 3. Check server health
lbb status server

# 4. Generate scenarios (optional) or review existing ones
lbb generate                              # Interactively generate a scenario YAML
lbb list scenarios --type single          # Or list existing scenarios

# 5. Run benchmarks
lbb run --file config/single_turn_scenarios.yaml   # Run by file (Tab completion)
lbb run --type all                                  # Or specify type

# 5-b. Run in background + monitor
lbb run --file config/single_turn_scenarios.yaml --background
lbb jobs                             # Check job status
lbb logs 20260326_123456 --follow    # Follow logs in real time
lbb stop 20260326_123456             # Stop if needed

# 6. Review results
lbb list results --limit 5     # List run folders (or flat files) with DGD info
lbb analyze                    # Auto-select latest run subfolder
lbb analyze --list             # Or pick interactively

# 7. Save report
lbb analyze --output report_$(date +%Y%m%d).md
```
