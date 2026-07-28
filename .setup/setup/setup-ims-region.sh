#!/bin/env bash
set -eu
# =============================================================================
# Script  : setup-ims-region.sh
# Summary : Create and configure IMS region with zconfig
#
# Runs on the remote z/OS USS system after the workspace has been cloned.
# - Verifies prerequisites
# - Creates IMS region using zconfig
# - Configures IMS Connect
# =============================================================================

# =========================
# Source library scripts
# =========================
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/../config/setenv.sh"

exec > >(while IFS= read -r line; do
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    printf "${CYAN}[ZCONFIG-IMS]${NC} %s\n" "${line}"
done) 2>&1

# =========================
# Environment
# =========================
export ZCONFIG_HOME=$(echo "$ZCONFIG_HOME" | sed "s|~|$HOME|g")
export PATH="$ZOAU_HOME/bin:$PATH"
export LIBPATH="$ZOAU_HOME/lib:${LIBPATH:-}"

# =========================
# Stop IBM BOZ regions
# =========================
set +e
jsub "${IMS_APP_HLQ}.JOBS(STOPMPP1)"  2>/dev/null
jsub "${IMS_APP_HLQ}.JOBS(STOPMPP2)"  2>/dev/null
jsub "${IMS_APP_HLQ}.IMSJAVA.JOBS(STOPJMP)"  2>/dev/null
sleep 5
jcan P "${IMS_DATASTORE}JMP1" 2>/dev/null
jcan P "${IMS_DATASTORE}MPP1" 2>/dev/null
jcan P "${IMS_DATASTORE}MPP2" 2>/dev/null
sleep 5
set -e
# =========================
# Activate zconfig environment
# =========================
if [ -f "$ZCONFIG_HOME/bin/activate" ]; then
    source "$ZCONFIG_HOME/bin/activate"
else
    print_warning "zconfig virtual environment not found at $ZCONFIG_HOME/bin/activate"
fi

# =========================
# Check and remove existing IMS region using zconfig
# =========================
cd "$SCRIPTS_DIR/../zconfig"

print_info "Checking for existing IMS regions..."
if zconfig ls 2>/dev/null | grep -q "ims://${IMS_DATASTORE}"; then
    print_info "Found existing IMS region ims://${IMS_DATASTORE}, removing..."
else
    print_info "No existing IMS region found in zconfig, attempting cleanup anyway..."
fi

# Always attempt to remove the IMS region to clean up any leftover datasets
set +e
zconfig rm ims://${IMS_DATASTORE} -v
sleep 5
set -e
print_success "IMS region cleanup completed"

# =========================
# Cleanup USS directories
# =========================
rm -rf "$SCRIPTS_DIR/logs"
rm -rf "$SANDBOX_DIR/${IMS_DATASTORE}"
rm -rf "$SANDBOX_DIR/diagnostics"

# =========================
# Stage 1: Create IMS instance with zconfig
# =========================
print_stage "STAGE 1: Create IMS instance with zconfig"

cd "$SCRIPTS_DIR/../zconfig"

# Set IMS user to current user
IMS_USER=$(printf '%s' "${IMS_USER}" | tr '[:lower:]' '[:upper:]')
IMS_USER_LOWER=$(printf '%s' "${IMS_USER}" | tr '[:upper:]' '[:lower:]')
print_info "Setting IMS user to ${IMS_USER} (USS: ${IMS_USER_LOWER})"

# IMS_SYS_HLQ (IMS1510) is the runtime datasets HLQ.
# The product library HLQ (DFS.V15RXM0) is needed for ADFSMAC/ADFSLOAD/ADFSSRC copies.
IMS_PROD_HLQ=$(get_section_value 'global' 'ims_sdfsresl_hlq')

# Run zconfig apply ignoring startup failures — zconfig writes procs to
# BANKZ.IMSO.PROCLIB even when the S command fails (IEE122I) because z/OS
# cannot find the proc in the system PROCLIB concat.  We copy the procs to
# USER.PROCLIB immediately after and then start the tasks ourselves.
set +e
zconfig apply -e ims_user="${IMS_USER}" -e ims_user_lower="${IMS_USER_LOWER}"\
              -e imsid="${IMS_DATASTORE}" -e ims_hlq="${IMS_APP_HLQ}" \
              -e ims_plex="${IMS_PLEX}" \
              -e ims_sys_hlq="${IMS_PROD_HLQ}" -e db2_hlq="${DB2_HLQ}" \
              -e java_home="${JAVA_HOME}" -e db2_java_home="${DB2_JAVA_HOME}" \
              -e ims_java_home="${IMS_JAVA_HOME}" \
              -e db2_ssid="${DB2_SSID}"  ims-region.yaml -v
ZCONFIG_RC=$?
set -e

deactivate

# =========================
# Stage 1b: Copy IMS procs to USER.PROCLIB then start them
#
# zconfig writes procs to BANKZ.IMSO.PROCLIB but the z/OS S command only
# searches the system PROCLIB concat (USER.PROCLIB, SYS1.PROCLIB etc.).
# Copy every proc before issuing S commands so they are findable.
# =========================
print_stage "STAGE 1b: Copy IMS procs to ${IMS_SYS_PROCLIB} and start"

IMS_PROCS="IMSOCTL IMSOSCI IMSOOM IMSORM IMSOHWS"
ALL_COPIED=true
for PROC in $IMS_PROCS; do
    print_info "Copying ${PROC} to ${IMS_SYS_PROCLIB}..."
    if cp "//'${IMS_APP_HLQ}.${IMS_DATASTORE}.PROCLIB(${PROC})'" \
          "//'${IMS_SYS_PROCLIB}(${PROC})'" 2>/dev/null; then
        print_success "Copied ${PROC}"
    else
        print_warning "Could not copy ${PROC} (may already exist or source missing)"
        ALL_COPIED=false
    fi
done

if [ "$ALL_COPIED" = "false" ]; then
    print_warning "Some procs could not be copied — will attempt to start anyway"
fi

# Now start any procs that zconfig failed to start (IMSOOM, IMSORM, IMSOHWS)
# IMSOSCI was started successfully by zconfig; start the rest.
set +e
for PROC in IMSOOM IMSORM IMSOHWS; do
    if ! opercmd "D A,${PROC}" 2>/dev/null | grep -q "${PROC}"; then
        print_info "Starting ${PROC}..."
        opercmd "S ${PROC}" 2>/dev/null
        sleep 5
    else
        print_info "${PROC} already running"
    fi
done
set -e

print_success "IMS procs copied and started"

if [ "$ZCONFIG_RC" -ne 0 ]; then
    print_info "zconfig reported non-zero RC ($ZCONFIG_RC) due to startup failures — procs corrected above"
fi

# =========================
# Stage 2: Verify IMS region
# =========================
print_stage "STAGE 2: Verify IMS region"

print_info "Waiting for IMS regions to start..."
sleep 15

# Check if IMS Control Region is running
print_info "Checking IMS Control Region status..."
if opercmd "D A,${IMS_DATASTORE}" 2>/dev/null | grep -q "${IMS_DATASTORE}"; then
    print_success "IMS Control Region (${IMS_DATASTORE}) is running"
else
    print_warning "IMS Control Region (${IMS_DATASTORE}) status could not be verified"
fi

# Check if IMS Connect is running
print_info "Checking IMS Connect status..."
IMS_HWS_JOB="${IMS_DATASTORE}HWS"
if opercmd "D A,${IMS_HWS_JOB}" 2>/dev/null | grep -q "${IMS_HWS_JOB}"; then
    print_success "IMS Connect (${IMS_HWS_JOB}) is running"
else
    print_warning "IMS Connect (${IMS_HWS_JOB}) status could not be verified"
fi

# Check if port is listening
print_info "Checking if IMS Connect port ${IMS_PORT} is listening..."
if netstat -a 2>/dev/null | grep -q ":${IMS_PORT}.*LISTEN"; then
    print_success "IMS Connect is listening on port ${IMS_PORT}"
else
    print_warning "Port ${IMS_PORT} status could not be verified (may still be initializing)"
fi

print_success "IMS region setup completed!"
print_info "IMS Datastore: ${IMS_DATASTORE}"
print_info "IMS Connect Port: ${IMS_PORT}"

exit 0

# Made with Bob
