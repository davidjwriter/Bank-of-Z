#!/bin/env bash
set -e
# =============================================================================
# Script  : setup-application.sh
# Summary : Full application installation orchestrator
#
# Runs on the remote z/OS USS system after the workspace has been cloned.
# Sequentially executes all installation stages in the following order:
#
# 1. Install/Setup Middleware (CICS, IMS, z/OS Connect, DB2 Tables)
# 2. DBB Build (LOAD, DBRM, PSB, DBD, WAR - API & Frontend)
# 3. Wazi Deploy (deploys all artifacts including z/OS Connect)
# =============================================================================

# =========================
# Source library scripts
# =========================
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPTS_DIR/../lib"
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/prerequisites.sh"
chmod +x $SCRIPTS_DIR/*.sh

# =============================================================================
# PHASE 1: DBB Build
# =============================================================================
cd "$SCRIPTS_DIR"
print_stage "PHASE 1: DBB Build"
bash ../tasks/task-dbb-build.sh full

print_success "PHASE 1: DBB Build completed"

# =============================================================================
# PHASE 2: Wazi Deploy
# =============================================================================
cd "$SCRIPTS_DIR"
print_stage "PHASE 2: Wazi Deploy"
bash ../tasks/task-wazi-deploy.sh&
# ZOAU Issue with ZOWE
PID=$!
wait $PID
RC=$?

print_success "PHASE 2: Wazi Deploy completed with RC=$RC"

# =========================
# PHASE 3: Populate DB2 database
# =========================
cd "$SCRIPTS_DIR"
print_stage "PHASE 3: Populate DB2 database"
bash ./populate-db2-tables.sh
print_success "PHASE 3: Populate DB2 database completed"

exit $RC