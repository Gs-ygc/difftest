#!/usr/bin/env bash

set -u

asset_dir=${1:-assets}
result_dir=${2:-results}
asset_dir=$(cd "$asset_dir" && pwd)
mkdir -p "$result_dir"
result_dir=$(cd "$result_dir" && pwd)

payload="$asset_dir/coremark-2-iteration.bin"
ref="$asset_dir/ref/riscv64-nemu-interpreter-so-arm64-834bcdc2"
csv="$result_dir/summary.csv"
hardware="$result_dir/hardware.txt"

variants=(
  "emu-vlt-min-zhuj-t2-o3|Verilator|Minimal|O3 (2T)"
  "emu-vlt-min-zhuj-t4-o3|Verilator|Minimal|O3"
  "emu-vlt-min-zhuj-t4-pgo-o3|Verilator|Minimal|PGO+O3"
  "emu-vlt-default-openllc-t4-o3|Verilator|Default/OpenLLC|O3"
  "emu-vlt-default-openllc-t4-pgo-o3|Verilator|Default/OpenLLC|PGO+O3"
  "emu-gsim-min-o3|GSIM|Minimal|O3"
  "emu-gsim-min-pgo|GSIM|Minimal|PGO+O3"
  "emu-gsim-def-o3|GSIM|Default/OpenLLC|O3"
  "emu-gsim-def-pgo|GSIM|Default/OpenLLC|PGO+O3"
)

{
  date -u '+utc=%Y-%m-%dT%H:%M:%SZ'
  uname -a
  sw_vers
  system_profiler SPHardwareDataType
  for key in hw.model hw.ncpu hw.physicalcpu hw.logicalcpu hw.memsize; do
    printf '%s=' "$key"
    sysctl -n "$key" 2>/dev/null || true
  done
  printf 'shell_nice='
  ps -p $$ -o nice= | tr -d ' '
  uptime
  df -h .
} > "$hardware"

printf '%s\n' \
  'binary,backend,config,optimization,run,mode,guest_cycles,wall_seconds,sim_hz,sim_khz,max_rss_bytes,status' \
  > "$csv"

run_one() {
  local binary_name=$1
  local backend=$2
  local config=$3
  local optimization=$4
  local label=$5
  local mode=$6
  local binary="$asset_dir/bin/$binary_name"
  local run_dir="$result_dir/$binary_name/$label"
  local log="$run_dir/run.log"
  local status guest_cycles wall_seconds sim_hz sim_khz max_rss

  mkdir -p "$run_dir"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$run_dir/started-at"
  uptime > "$run_dir/uptime-before.txt"

  if [[ "$mode" == diff ]]; then
    (
      cd "$run_dir" || exit 1
      /usr/bin/time -l "$binary" -i "$payload" --diff="$ref" > "$log" 2>&1
    )
  else
    (
      cd "$run_dir" || exit 1
      /usr/bin/time -l "$binary" -i "$payload" --no-diff > "$log" 2>&1
    )
  fi
  status=$?

  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$run_dir/finished-at"
  uptime > "$run_dir/uptime-after.txt"
  guest_cycles=$(sed -nE 's/.*Guest cycle spent: ([0-9,]+).*/\1/p' "$log" | tail -1 | tr -d ',')
  wall_seconds=$(awk '$2 == "real" { print $1; exit }' "$log")
  max_rss=$(awk '$2 == "maximum" && $3 == "resident" { print $1; exit }' "$log")

  sim_hz=
  sim_khz=
  if [[ -n "$guest_cycles" && -n "$wall_seconds" ]]; then
    sim_hz=$(awk -v cycles="$guest_cycles" -v seconds="$wall_seconds" \
      'BEGIN { printf "%.2f", cycles / seconds }')
    sim_khz=$(awk -v hz="$sim_hz" 'BEGIN { printf "%.3f", hz / 1000 }')
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$binary_name" "$backend" "$config" "$optimization" "$label" "$mode" \
    "$guest_cycles" "$wall_seconds" "$sim_hz" "$sim_khz" "$max_rss" "$status" \
    >> "$csv"

  printf '%-42s %-13s cycles=%-8s wall=%-8ss speed=%s kHz status=%s\n' \
    "$binary_name" "$label" "$guest_cycles" "$wall_seconds" "$sim_khz" "$status"

  if [[ "$status" -ne 0 ]] || ! grep -Fq 'HIT GOOD TRAP' "$log"; then
    tail -80 "$log"
    return 1
  fi
}

overall_status=0
for variant in "${variants[@]}"; do
  IFS='|' read -r binary_name backend config optimization <<< "$variant"
  if [[ -n "${BENCH_FILTER:-}" && "$binary_name" != "$BENCH_FILTER" ]]; then
    continue
  fi
  run_one "$binary_name" "$backend" "$config" "$optimization" diff-first diff || overall_status=1
  sleep 15
  run_one "$binary_name" "$backend" "$config" "$optimization" nodiff-middle nodiff || overall_status=1
  sleep 15
  run_one "$binary_name" "$backend" "$config" "$optimization" diff-last diff || overall_status=1
done

markdown="$result_dir/summary.md"
{
  printf '# macOS M1 prebuilt emulator benchmark\n\n'
  printf 'The same M4-built binaries run sequentially on a GitHub-hosted 3-core M1 runner.\n\n'
  printf '| Backend | Config | Optimization | Run | Mode | Cycles | Wall (s) | Speed (kHz) | Peak RSS (bytes) | Status |\n'
  printf '| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |\n'
  tail -n +2 "$csv" | while IFS=, read -r binary_name backend config optimization label mode cycles wall hz khz rss status; do
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$backend" "$config" "$optimization" "$label" "$mode" "$cycles" "$wall" "$khz" "$rss" "$status"
  done
} > "$markdown"

cat "$hardware"
cat "$markdown"
exit "$overall_status"
