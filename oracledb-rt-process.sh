!/bin/bash
# Oracle RAC RT Priority — Database + ASM instances
# Covers: _high_priority_processes + _highest_priority_processes
# Oracle 23c — OL9 — chrt via prlimit
#
# EDIT THESE TWO VARIABLES FOR EACH NODE:
#   NODE01: DB_SID=ORCL1  ASM_SID=ASM1
# Authors: Juliano Ribeiro and AI's


DB_SID=<ORACLE_SID>
ASM_SID=<ASM_SID>

# ─────────────────────────────────────────────
# FUNCTION: apply RT to a list of pgrep patterns
# Usage: apply_rt <policy> <priority> <sid> <proc1> [proc2] ...
# policy: -f (FIFO) or -r (RR)
# sid: substring matched against full process cmdline
# ─────────────────────────────────────────────
apply_rt() {
  local policy=$1
  local priority=$2
  local sid=$3
  local label
  label=$([ "$policy" = "-f" ] && echo "FF" || echo "RR")
  shift 3

  for proc in "$@"; do
    for PID in $(pgrep -f "${proc}_.*${sid}" 2>/dev/null); do
      COMM=$(ps -p "$PID" -o comm= 2>/dev/null)
      prlimit --rtprio=99:99 --pid "$PID" 2>/dev/null
      if chrt "$policy" -p "$priority" "$PID" 2>/dev/null; then
        echo "  ${label}: $COMM PID $PID ✅"
      else
        echo "  ${label} FAIL: $COMM PID $PID ❌"
      fi
    done
  done
}

# ─────────────────────────────────────────────
echo "=== [1] Expanding prlimit — ALL Oracle processes ==="
# ─────────────────────────────────────────────
for PID in $(pgrep -f "ora_.*_${DB_SID}" 2>/dev/null) \
           $(pgrep -f "asm_.*_.*${ASM_SID}" 2>/dev/null); do
  prlimit --rtprio=99:99 --pid "$PID" 2>/dev/null
done
echo "  prlimit applied ✅"

# ─────────────────────────────────────────────
echo ""
echo "=== [2] DATABASE: SCHED_FIFO — _highest_priority_processes ==="
# ─────────────────────────────────────────────
# VKTM | LGWR | LMS* | CTWR
apply_rt -f 1 "${DB_SID}" \
  ora_vktm \
  ora_lgwr \
  ora_ctwr \
  "ora_lms[0-9a-z]"

# ─────────────────────────────────────────────
echo ""
echo "=== [3] DATABASE: SCHED_RR — _high_priority_processes ==="
# ─────────────────────────────────────────────
# LM* | LCK* | GCR* | CKPT | DBRM | RMS0 | LG* | CR* | RMV*
apply_rt -r 1 "${DB_SID}" \
  ora_lmon \
  "ora_lmd[0-9]" \
  ora_lmhb \
  ora_lmbr \
  ora_lmcn \
  "ora_lck[0-9]" \
  "ora_gcr[0-9]" \
  ora_ckpt \
  ora_dbrm \
  ora_rms0 \
  "ora_lg[0-9][0-9]" \
  "ora_rmv"

# ─────────────────────────────────────────────
echo ""
echo "=== [4] ASM: SCHED_FIFO — _highest_priority_processes ==="
# ─────────────────────────────────────────────
# ASM_SID matched as substring — no need to escape +
apply_rt -f 1 "${ASM_SID}" \
  asm_vktm \
  asm_lgwr \
  "asm_lms[0-9a-z]"

# ─────────────────────────────────────────────
echo ""
echo "=== [5] ASM: SCHED_RR — _high_priority_processes ==="
# ─────────────────────────────────────────────
apply_rt -r 1 "${ASM_SID}" \
  asm_lmon \
  "asm_lmd[0-9]" \
  asm_lmhb \
  "asm_lck[0-9]" \
  "asm_gcr[0-9]" \
  asm_ckpt

# ─────────────────────────────────────────────
echo ""
echo "=== FINAL VERIFICATION ==="
# ─────────────────────────────────────────────
echo ""
echo "--- FF (SCHED_FIFO) ---"
ps -eo pid,cls,rtprio,ni,comm \
  | awk '$2=="FF" && (/ora_/ || /asm_/)' \
  | sort -k5

echo ""
echo "--- RR (SCHED_RR) ---"
ps -eo pid,cls,rtprio,ni,comm \
  | awk '$2=="RR" && (/ora_/ || /asm_/)' \
  | sort -k5

echo ""
echo "--- Still TS — critical processes (verify) ---"
ps -eo pid,cls,rtprio,ni,comm \
  | awk '$2=="TS"' \
  | grep -E "ora_lms|ora_lmd|ora_lck|ora_gcr|ora_ckpt|ora_dbrm|ora_rms0|ora_lgwr|ora_lg[0-9]|ora_rmv|ora_vktm|asm_vktm|asm_lgwr|asm_lms|asm_lmd|asm_lck|asm_gcr|asm_ckpt" \
  | sort -k5

echo ""
echo "=== DONE ==="
