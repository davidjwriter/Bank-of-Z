# TIVMVS5 Bank of Z Deployment — Ongoing Context

> Last updated: 2026-08-24  
> Branch: `tivmvs5` on `git@github.com:davidjwriter/Bank-of-Z.git`  
> Upstream: `https://github.com/IBM/Bank-of-Z.git`

---

## LPAR Quick Reference

| Property | Value |
|---|---|
| System | TIVMVS5 (`tivmvs5.pok.stglabs.ibm.com`) |
| Shell user | `MEYER` |
| RACF admin | `SYSADM` |
| Sandbox root | `/usr/local/sandboxes/bank-of-z/Bank-of-Z` |
| PROCLIB | `USER.PROCLIB` (not `SYS1.PROCLIB`) |
| Credentials file | `~/.profile.bankz` |
| IMS credentials | `IMS_USER=SYSADM` / `IMS_PASSWORD=TIVMVS` |
| CICS credentials | `CICS_USER=SYSADM` / `CICS_PASSWORD=TIVMVS` |
| z/OS credentials | `ZOS_USER=SYSADM` / `ZOS_USER_PASSWORD=TIVMVS` |

---

## LPAR-Specific HLQs (config.yaml)

| Setting | TIVMVS5 Value | Why it differs from upstream default |
|---|---|---|
| `zoau_home` | `/usr/lpp/IBM/zoautil` | Non-standard install path |
| `wazideploy_home` | `/usr/local/sandboxes/tools/gdp` | Local sandbox install |
| `zosconnect_home` | `/usr/lpp/IBM/zosconnect/v3r0` | |
| `sys_proclib` | `USER.PROCLIB` | No write access to `SYS1.PROCLIB` |
| `tcpip_hlq` | `EZA` | |
| `igzxjni2` | `/usr/lpp/IBM/cobol/V6R5M0/lib/igzxjni2.x` | |
| `igy_hlq` | `IGY.V6R5M0` | COBOL V6R5 |
| `fel_hlq` | `FEL.V17R0M0` | IDz V17 |
| `ipv_hlq` | `IPV.V1R9M0` | |
| `pli_hlq` | `IBMZ.V5R2M0` | |
| `debug_hlq` | `EQAW` | IBM z/OS Debugger IS installed for CICS use |
| `cics_hlq` | `DFH.V6R3M0` | CICS TS 6.3 |
| `cics_uss_dir` | `/usr/lpp/cicsts/dfh630` | |
| `ims_sys_hlq` | `DFS.V15RXM0` | IMS V15 |
| `ims_dfsplex` | `PLEX2` | **PLEX1 is a live system IMS — do not use** |
| `ims_ixvolser` | `TMVS5A` | DASD volume for IMS datasets |
| `db2_hlq` | `DSN131` | DB2 13 instance HLQ (runtime, RUNLIB, etc.) |
| `db2_sdsnload_hlq` | `DSN.V13R1M0` | DB2 **library** HLQ — SDSNLOAD/SDSNEXIT/SDSNLOD2 live here, NOT under `DSN131` |
| `db2_runlib` | `DSN131.RUNLIB.LOAD` | |
| `db2_ssid` | `DBD1` | |
| `zosconnect_https_port` | `9443` | |
| `frontend_https_port` | `9444` | |

---

## Critical TIVMVS5 Quirks

### 1. z/OS file tagging — git pull/checkout do NOT update files
z/OS USS file tagging causes `git pull` and `git checkout` to silently skip updating tagged files.

**Always use `git show` to force-update files after a push:**
```bash
git show tivmvs5:<path/to/file> > <path/to/file>
```

**Always clear the stale `.env` cache after any branch switch or config change:**
```bash
rm -f .setup/config/.env && exec bash -l
source .setup/config/setenv.sh
```

The `:-` pattern in `setenv.sh` means existing env vars are **never overwritten** — a stale `.env` or exported variable will silently win.

### 2. DB2 HLQ split — DSN131 vs DSN.V13R1M0
`DSN131` is the DB2 instance HLQ (RUNLIB, catalog datasets, etc.).  
`DSN.V13R1M0` is the DB2 product library HLQ (SDSNLOAD, SDSNEXIT, SDSNLOD2).

Any tool or script that tries to allocate `DSN131.SDSNLOAD` will fail with dataset not found. Everywhere a DB2 library dataset is referenced must use `db2_sdsnload_hlq` (`DSN.V13R1M0`), not `db2_hlq` (`DSN131`).

**Affected files fixed so far:**
- `.setup/zconfig/cics-region.yaml` — `steplib` uses `{{ vars.db2_sdsnload_hlq }}`
- `.setup/zconfig/ims-region.yaml` — `db2_hlq` var set to `DSN.V13R1M0` (zconfig derives SDSNLOD2 from this single field)
- All 6 DB2 JCL templates under `.setup/deploy/` — use `{{ db2.sdsnload }}` / `{{ db2.sdsnexit }}`
- `.setup/build/datasets.yaml.j2` — `SDSNLOAD`/`SDSNEXIT` use `{{ global.db2_sdsnload_hlq }}`
- Wazi Deploy `db2_config.yml` on LPAR — must be patched manually (see below)

### 3. DB2 buffer pool — BP0 only, BP1 not activated
`CREATE DATABASE` JCL templates default to `BUFFERPOOL BP1` in upstream. BP1 is not activated on TIVMVS5.

**Fix:** Use `BUFFERPOOL BP0` in:
- `.setup/deploy/cics/Db2-create.j2`
- `.setup/deploy/ims/Db2-create.j2`

### 4. PLEX1 is a live system IMS — use PLEX2 for Bank of Z
The system IMS (`IMSO`) is already running on `PLEX1`/XCF group `CSLPLEX1`. Starting Bank of Z's `IMSOSCI` with `PLEX1` causes:
```
CSL3000E SCI IMSPLEX INITIALIZATION ERROR IMSPLEX CSLPLEX1 ALREADY MANAGED BY SCI
```

`ims_dfsplex` must be `PLEX2` in `config.yaml`. `CSLPLEX2` is free on TIVMVS5.

### 5. IMS procs — zconfig writes to BANKZ.IMSO.PROCLIB, not USER.PROCLIB
zconfig generates IMS procs into `BANKZ.IMSO.PROCLIB` but cannot write to `SYS1.PROCLIB`. MVS `S` commands search the system PROCLIB concatenation which includes `USER.PROCLIB` but not application-specific libraries.

**Fix in `setup-ims-region.sh`:** After `zconfig apply`, copy all procs to `USER.PROCLIB`:
```bash
for member in IMSOSCI IMSOOM IMSORM IMSOODB IMSOCTL IMSOHWS IMSODLI IMSODRC; do
    dcp "BANKZ.IMSO.PROCLIB(${member})" "/tmp/${member}-$$.jcl"
    dcp "/tmp/${member}-$$.jcl" "USER.PROCLIB(${member})"
done
```

### 6. EQAW debugger — not installed for IMS, installed for CICS
`debug_hlq: EQAW` in `config.yaml` is correct for CICS (the value is passed on the CLI but never consumed by `cics-region.yaml`).

For IMS, `debug_hlq` is a first-class field that triggers `ImsDebugLinkEdit` (assembles EQAOPTS from `EQAW.SEQAMOD`). `EQAW.SEQAMOD` does not exist under the IMS context.

**Fix:** Do NOT pass `-e debug_hlq=...` in the `zconfig apply` call in `setup-ims-region.sh`. The `ims-region.yaml` `vars.debug_hlq` is set to `""` so zconfig skips the task.

Note: `zconfig` rejects `-e key=` (empty value) — omit the argument entirely.

### 7. RACF surrogate submit — MEYER cannot submit jobs as SYSADM by default
zconfig generates `IMSOCTL` JCL with `USER=SYSADM`. Submitting from MEYER hits:
```
ICH408I SUBMITTER IS NOT AUTHORIZED BY USER
```

**Fix:** Define the SURROGAT profile and grant MEYER:
```bash
tsocmd "RDEFINE SURROGAT SYSADM.SUBMIT UACC(NONE)"
tsocmd "PERMIT SYSADM.SUBMIT CLASS(SURROGAT) ID(MEYER) ACCESS(READ)"
tsocmd "SETROPTS RACLIST(SURROGAT) REFRESH"
```
This is a one-time LPAR setup — once done it persists.

**Do not run setup scripts as SYSADM directly** — SYSADM has superuser authority that can bypass read-only filesystem protections, and zconfig's `rm` cleanup can delete system files (this wiped `/etc/ssh` once, forcing SSH host key regeneration).

### 8. Wazi Deploy db2_config.yml — must be patched on LPAR
Wazi Deploy reads `sdsnload` from its own config file. The `-e key=value` CLI override does not support nested dot-notation keys in this version. The file must be patched directly:
```bash
sed -i 's|DSN131\.SDSNLOAD|DSN.V13R1M0.SDSNLOAD|g' \
  /usr/local/sandboxes/bank-of-z/dbb/WaziDeploy/zDeploy/deployment-configuration/global/db2_config.yml
```
This is a one-time LPAR fix that persists across re-runs.

---

## Debugging Commands

### Job logs
```bash
# List all recent IMS/CICS jobs
jls | grep -E "IMSO|CICS|IMS"

# Read JES message log for a job
pjdd STC06707 JESMSGLG

# Read system messages (allocations, JCL errors)
pjdd STC06707 JESYSMSG

# Read program output
pjdd STC06707 SYSPRINT

# List all DDs for a job
ddls STC06707
```

### IMS status
```bash
# Check which XCF groups are active
opercmd "D XCF,GROUP,CSLPLEX1"   # system IMS
opercmd "D XCF,GROUP,CSLPLEX2"   # Bank of Z IMS

# Check running jobs
jls | grep -E "IMSO|IMS"
```

### CICS CMCI
```bash
# Poll CMCI readiness
curl -s -o /dev/null -w "%{http_code}" \
  http://127.0.0.1:27100/CICSSystemManagement/CICSProgram/CICSBOZ
```

### z/OS datasets
```bash
# Check if a dataset exists
dls DSN.V13R1M0.SDSNLOAD

# Copy between LPAR datasets and USS
dcp "BANKZ.IMSO.PROCLIB(IMSOOM)" /tmp/IMSOOM.jcl
dcp /tmp/IMSOOM.jcl "USER.PROCLIB(IMSOOM)"

# Delete dataset member
mrm "USER.PROCLIB(IMSOOM)"
```

### zconfig
```bash
# List configured instances
zconfig ls

# Remove an IMS instance (careful as SYSADM — see quirk #7)
zconfig rm ims://IMSO -v

# View zconfig logs
ls -lt /u/meyer/.zconfig/logs/ | head -5
cat /u/meyer/.zconfig/logs/ims_IMSO-<timestamp>.txt
```

### JES2 job management
```bash
# Release a held job
opercmd "\$A JOB06716"

# Cancel a job
opercmd "\$C JOB06716"

# Purge a job from queue
opercmd "\$P JOB06716"
```

### SSH host key reset (if /etc/ssh gets wiped)
```bash
# On your Mac — remove stale known_hosts entry
ssh-keygen -R tivmvs5.pok.stglabs.ibm.com
ssh meyer@tivmvs5.pok.stglabs.ibm.com   # accept new fingerprint
```

---

## Deployment Status as of 2026-08-24

| Component | Status | Notes |
|---|---|---|
| CICS (CICSBOZ) | ✅ Running | `STC06694 AC`, CMCI on port 27100 |
| DB2 tables | ✅ Created | BANKZ and IMSBANK databases |
| IMS SCI/OM/RM | ✅ Running | CSLPLEX2 XCF group active |
| IMS CTL (IMSOCTL) | ⏳ Pending | Surrogate permit in place, needs clean re-run |
| DBB Build | ✅ Passing | Full build clean |
| Wazi Deploy | ⏳ In progress | Blocked on `DSN131.SDSNLOAD` in db2_config.yml — fix with `sed` on LPAR |
| z/OS Connect | ⏳ Not yet attempted | |
| Frontend | ⏳ Not yet attempted | |

---

## Next Steps

1. **Patch Wazi Deploy db2_config.yml on LPAR** (one-time):
   ```bash
   sed -i 's|DSN131\.SDSNLOAD|DSN.V13R1M0.SDSNLOAD|g' \
     /usr/local/sandboxes/bank-of-z/dbb/WaziDeploy/zDeploy/deployment-configuration/global/db2_config.yml
   ```

2. **Re-run Wazi Deploy** (no need to rebuild):
   ```bash
   source .setup/config/setenv.sh
   .setup/tasks/task-wazi-deploy.sh
   ```

3. **If IMSOCTL is not running**, re-run IMS setup as MEYER (surrogate now in place):
   ```bash
   git show tivmvs5:.setup/setup/setup-ims-region.sh > .setup/setup/setup-ims-region.sh
   rm -f .setup/config/.env && exec bash -l
   source .setup/config/setenv.sh
   .setup/setup/setup-ims-region.sh
   ```

4. **Continue with z/OS Connect and frontend** via remaining setup scripts.

---

## Key Files Changed on tivmvs5 Branch

| File | What changed |
|---|---|
| `.setup/config/config.yaml` | All LPAR HLQs, `ims_dfsplex=PLEX2`, `db2_sdsnload_hlq=DSN.V13R1M0`, ports, credentials |
| `.setup/config/setenv.sh` | `ZOS_CURRENT_USER` from env not yaml; `~/.profile.bankz` fallback; `DB2_SDSNLOAD_HLQ` export; cert vars removed |
| `.setup/zconfig/cics-region.yaml` | LPAR HLQs; `db2_sdsnload_hlq` for steplib; `BP0`; single JVM profile; `pltpi/pltsd=NO` |
| `.setup/zconfig/ims-region.yaml` | LPAR HLQs; `debug_hlq=""`; `db2_hlq=DSN.V13R1M0`; `ims_plex=PLEX2` |
| `.setup/setup/setup-cics-region.sh` | RACF STARTED profile; write CICS proc to USER.PROCLIB; `opercmd "S CICSBOZ"` (Stages 4-6 were missing) |
| `.setup/setup/setup-ims-region.sh` | Drop `debug_hlq` from zconfig apply args; copy procs to USER.PROCLIB; use `DB2_SDSNLOAD_HLQ` for db2_hlq |
| `.setup/tasks/task-wazi-deploy.sh` | CMCI poll before wazideploy fires; temp file fix (`.j2` not `.j2.$$`) |
| `.setup/build/datasets.yaml.j2` | `SDSNLOAD`/`SDSNEXIT` use `global.db2_sdsnload_hlq` |
| `.setup/deploy/cics/Db2-create.j2` | `BUFFERPOOL BP0` |
| `.setup/deploy/ims/Db2-create.j2` | `BUFFERPOOL BP0` |
| All 6 DB2 JCL `.j2` templates | Use `{{ db2.sdsnload }}` / `{{ db2.sdsnexit }}` instead of `{{ db2.db2_hlq }}.SDSNLOAD` |

---

## One-Time LPAR Fixes (not in git — apply manually after fresh clone)

```bash
# 1. Patch Wazi Deploy db2_config.yml
sed -i 's|DSN131\.SDSNLOAD|DSN.V13R1M0.SDSNLOAD|g' \
  /usr/local/sandboxes/bank-of-z/dbb/WaziDeploy/zDeploy/deployment-configuration/global/db2_config.yml

# 2. RACF surrogate permit (allows MEYER to submit jobs as SYSADM)
tsocmd "RDEFINE SURROGAT SYSADM.SUBMIT UACC(NONE)"
tsocmd "PERMIT SYSADM.SUBMIT CLASS(SURROGAT) ID(MEYER) ACCESS(READ)"
tsocmd "SETROPTS RACLIST(SURROGAT) REFRESH"

# 3. Sandbox permissions (allows SYSADM to read files owned by MEYER if needed)
chmod -R 755 /usr/local/sandboxes/bank-of-z/Bank-of-Z
```

---

*Made with IBM Bob*
