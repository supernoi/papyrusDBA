#!/bin/bash

################################################################################
# SCRIPT: oracle_mbrc_calc.sh
# DESCRIPTION: Calculates the optimal db_file_multiblock_read_count (MBRC) by 
#              finding the "Common Denominator" between Database, ASM, and OS.
#
# USAGE: ./mbrc_analyser.sh <ORACLE_SID>
#
# PRE-REQUISITES:
#   1. Execute preferably as the ORACLE OWNER user (e.g., oracle).
#   2. The instance must be UP and accessible via 'sqlplus / as sysdba'.
#   3. Environment variables (ORACLE_SID/ORACLE_HOME) should be set or 
#      accessible via the provided SID.
#
# FORMULA: MBRC = [ min(Oracle_Cap, ASM_AU, OS_Max_Sectors) / db_block_size ]
# Author: Gemini
# Co-Author: Juliano Ribeiro (https://github.com/supernoi/papyrusDBA)
################################################################################

# --- Input Validation ---
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <ORACLE_SID>"
    echo "Example: $0 cdrcol1"
    exit 1
fi

export ORACLE_SID=$1

# Ensure ORACLE_HOME is set
if [ -z "$ORACLE_HOME" ]; then
    SQLPLUS_PATH=$(which sqlplus 2>/dev/null)
    [ -n "$SQLPLUS_PATH" ] && export ORACLE_HOME=$(echo "$SQLPLUS_PATH" | sed 's/\/bin\/sqlplus//')
fi

if [ -z "$ORACLE_HOME" ]; then
    echo "ERROR: ORACLE_HOME not found. Please run as 'oracle' user or set your environment."
    exit 1
fi

echo "--------------------------------------------------------------------------"
echo "I/O BOUNDARY ANALYSIS PER DISKGROUP (SID: $ORACLE_SID)"
echo "Formula: MBRC = [ min(1024KB, ASM_AU, OS_Max_Sectors) / db_block_size ]"
echo "--------------------------------------------------------------------------"

# 1. Data Collection (Bypassing glogin.sql timing/prompt noise)
RAW_DATA=$($ORACLE_HOME/bin/sqlplus -S / as sysdba <<EOF
set heading off feedback off pagesize 0 linesize 1000 termout off verify off timing off time off
WHENEVER SQLERROR EXIT 1;
SELECT dg.name || '#' || (dg.allocation_unit_size/1024) || '#' || p.value || '#' || 
       (SELECT MIN(path) FROM v\$asm_disk WHERE group_number = dg.group_number AND header_status = 'MEMBER')
FROM v\$asm_diskgroup dg, v\$parameter p
WHERE p.name = 'db_block_size';
EXIT;
EOF
)

if [ $? -ne 0 ] || [ -z "$RAW_DATA" ]; then
    echo "ERROR: Connection failed. Ensure you are running as the Oracle Owner."
    exit 1
fi

echo -e "DISKGROUP\tAU_SIZE\t\tMAX_SECTORS\tBLOCK_SIZE\tCALCULATED_MBRC"
echo "--------------------------------------------------------------------------"

# 2. Secure Processing
echo "$RAW_DATA" | grep "#" | while read -r LINE; do
    
    DG_NAME=$(echo "$LINE" | cut -d'#' -f1 | tr -d '[:space:]')
    AU_KB=$(echo "$LINE" | cut -d'#' -f2 | tr -d '[:space:]')
    BLOCK_SIZE=$(echo "$LINE" | cut -d'#' -f3 | tr -d '[:space:]')
    ASM_PATH=$(echo "$LINE" | cut -d'#' -f4 | tr -d '[:space:]')

    [[ ! "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || [ "$BLOCK_SIZE" -eq 0 ] && continue

    # 3. OS Mapping (Resolving physical block device limits)
    OS_MAX_KB=1024
    if [[ "$ASM_PATH" == /dev/* ]]; then
        REAL_PATH=$(readlink -f "$ASM_PATH")
        DEVICE_NAME=$(basename "$REAL_PATH")
        PARENT_DEV=$(echo "$DEVICE_NAME" | sed 's/[0-9]*$//')
        SYS_FILE="/sys/block/$PARENT_DEV/queue/max_sectors_kb"
        [ -f "$SYS_FILE" ] && OS_MAX_KB=$(cat "$SYS_FILE")
    fi

    # 4. The Funnel Logic
    ORACLE_CAP=1024
    FINAL_CAP=$ORACLE_CAP
    [ "$AU_KB" -lt "$FINAL_CAP" ] && FINAL_CAP=$AU_KB
    [ "$OS_MAX_KB" -lt "$FINAL_CAP" ] && FINAL_CAP=$OS_MAX_KB

    # Convert KB to Bytes for the division
    CALCULATED_MBRC=$(( FINAL_CAP * 1024 / BLOCK_SIZE ))

    # 5. Formatted Output
    printf "%-15s\t%-10s\t%-15s\t%-10s\t%s\n" \
        "$DG_NAME" "${AU_KB}KB" "${OS_MAX_KB}KB" "${BLOCK_SIZE}B" "$CALCULATED_MBRC"

done

echo "--------------------------------------------------------------------------"
echo "INFO: If Calculated MBRC is lower than your 'db_file_multiblock_read_count',"
echo "      physical I/O splitting is occurring at the OS or ASM layer."
