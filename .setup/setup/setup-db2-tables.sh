#!/bin/env bash
set -e
# =============================================================================
# Script  : setup-db2-tables.sh
# Summary : DB2 table creation
#
# Runs on the remote z/OS USS system after the workspace has been cloned.
# - Drops existing tables
# - Creates tables
# =============================================================================

# =========================
# Source library scripts
# =========================
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/../config/setenv.sh"

# =========================
# Environment
# =========================
export ZOAU_HOME=$(get_section_value 'zoau' 'zoau_home')
export CONFIG_FILE="$SCRIPTS_DIR/../config/config.yaml"

export PATH="$ZOAU_HOME/bin:$PATH"
export LIBPATH="$ZOAU_HOME/lib:${LIBPATH:-}"

# =========================
# Create DB2 tables
# =========================
rm -f "/tmp/IMS-Db2-*"
rm -f "/tmp/Db2-*"

# Render CICS DB2 JCL templates
python "$SCRIPTS_DIR/../lib/render_template.py" --configFile $CONFIG_FILE \
    --extraVar "jobname=DB2DROP" --templateFile "$SCRIPTS_DIR/../jcl/cics/Db2-drop.j2" \
    --outputFile "/tmp/Db2-drop-$$.jcl"

python "$SCRIPTS_DIR/../lib/render_template.py" --configFile $CONFIG_FILE \
    --extraVar "jobname=DB2CREAT" --templateFile "$SCRIPTS_DIR/../jcl/cics/Db2-create.j2" \
    --outputFile "/tmp/Db2-create-$$.jcl"

# Render IMS DB2 JCL templates
python "$SCRIPTS_DIR/../lib/render_template.py" --configFile $CONFIG_FILE \
    --extraVar "jobname=IMSDB2DR" --templateFile "$SCRIPTS_DIR/../jcl/ims/Db2-drop.j2" \
    --outputFile "/tmp/IMS-Db2-drop-$$.jcl"

python "$SCRIPTS_DIR/../lib/render_template.py" --configFile $CONFIG_FILE \
    --extraVar "jobname=IMSDB2CR" --templateFile "$SCRIPTS_DIR/../jcl/ims/Db2-create.j2" \
    --outputFile "/tmp/IMS-Db2-create-$$.jcl"

run_job_and_wait "/tmp/Db2-drop-$$.jcl" "8"
run_job_and_wait "/tmp/Db2-create-$$.jcl"
# IMS DB2 setup
jsub -f "/tmp/IMS-Db2-drop-$$.jcl"
jsub -f "/tmp/IMS-Db2-create-$$.jcl"
exit $?
