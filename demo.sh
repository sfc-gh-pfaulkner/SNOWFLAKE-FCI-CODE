#!/bin/bash
set -euo pipefail

# =============================================================================
# FCI RBAC Framework — Interactive Demo Script
# =============================================================================
# Deploys three domains through the full pipeline, one at a time:
#   GENERAL → HR → BRF
# Each domain: WIP → TEST → UAT → PREPROD → PROD
#
# Features:
#   - Auto-creates GitHub issues
#   - Checkpoints progress to .demo_progress
#   - On restart, offers to resume from last successful step
#   - Pass --reset to start fresh
#
# Prerequisites:
#   - Both Snowflake accounts deployed (full_reset.sh completed)
#   - Developer roles granted to your user
#   - Self-hosted GitHub Actions runner listening (~/actions-runner/run.sh)
#   - GitHub secrets configured
#   - Must be run from the FCI-CODE repo root directory
# =============================================================================

STATE_FILE=".demo_progress"

# Colours
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

step_num=0
resume_from=0

# --- State management ---
save_state() {
  echo "STEP=${step_num}" > "$STATE_FILE"
  echo "GENERAL_ISSUE=${GENERAL_ISSUE:-}" >> "$STATE_FILE"
  echo "HR_ISSUE=${HR_ISSUE:-}" >> "$STATE_FILE"
  echo "BRF_ISSUE=${BRF_ISSUE:-}" >> "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    resume_from=${STEP:-0}
  fi
}

clear_state() {
  rm -f "$STATE_FILE"
}

# --- Handle --reset flag ---
if [[ "${1:-}" == "--reset" ]]; then
  clear_state
  echo "  State cleared. Starting fresh."
  echo ""
fi

# --- Check for resume ---
load_state
if [[ $resume_from -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}  Previous run found — completed ${resume_from} steps.${RESET}"
  if [[ -n "${GENERAL_ISSUE:-}" ]]; then echo "    GENERAL issue: #${GENERAL_ISSUE}"; fi
  if [[ -n "${HR_ISSUE:-}" ]]; then echo "    HR issue: #${HR_ISSUE}"; fi
  if [[ -n "${BRF_ISSUE:-}" ]]; then echo "    BRF issue: #${BRF_ISSUE}"; fi
  echo ""
  read -rp "  Resume from step $((resume_from + 1))? [Y/n] " choice
  if [[ "$choice" == "n" || "$choice" == "N" ]]; then
    clear_state
    resume_from=0
    GENERAL_ISSUE=""
    HR_ISSUE=""
    BRF_ISSUE=""
  fi
  echo ""
fi

# --- Core functions ---
step() {
  step_num=$((step_num + 1))

  # Skip already-completed steps
  if [[ $step_num -le $resume_from ]]; then
    return 0
  fi

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}Step ${step_num}: $1${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "${YELLOW}$2${RESET}"
  echo ""
  echo -e "  ${GREEN}\$ $3${RESET}"
  echo ""
  read -rp "Press RETURN to execute..."
  echo ""
  eval "$3"
  save_state
}

section() {
  # Skip section headers if we're still catching up
  if [[ $step_num -lt $resume_from ]]; then
    return 0
  fi
  echo ""
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║  $1${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
}

pause_gate() {
  # Skip if catching up
  if [[ $step_num -le $resume_from ]]; then
    return 0
  fi
  echo ""
  echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${YELLOW}  $1${RESET}"
  echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  read -rp "Press RETURN when ready to continue..."
}

wait_for_workflow() {
  # Skip if catching up
  if [[ $step_num -le $resume_from ]]; then
    return 0
  fi
  local max_wait=300
  local interval=10
  local elapsed=0
  echo "  Waiting for GitHub Actions workflow to complete..."
  while [[ $elapsed -lt $max_wait ]]; do
    sleep $interval
    elapsed=$((elapsed + interval))
    local status
    status=$(gh run list --limit 1 --json conclusion,status --jq '.[0].status')
    if [[ "$status" == "completed" ]]; then
      local conclusion
      conclusion=$(gh run list --limit 1 --json conclusion --jq '.[0].conclusion')
      if [[ "$conclusion" == "success" ]]; then
        echo -e "  ${GREEN}Workflow completed successfully (${elapsed}s)${RESET}"
        return 0
      else
        echo -e "  ${RED}Workflow FAILED (conclusion: ${conclusion})${RESET}"
        echo "  Check logs: gh run view --log-failed"
        read -rp "  Press RETURN to continue anyway, or Ctrl+C to abort..."
        return 0
      fi
    fi
    echo "  ... still running (${elapsed}s elapsed)"
  done
  echo -e "  ${RED}Workflow did not complete within ${max_wait}s${RESET}"
  echo "  Check status: gh run list --limit 1"
  read -rp "  Press RETURN to continue anyway, or Ctrl+C to abort..."
}

# =============================================================================
# deploy_domain — runs one domain through the full pipeline
# =============================================================================
deploy_domain() {
  local DOMAIN="$1"
  local DOMAIN_LOWER="$2"
  local DEV_WH="$3"
  local PROD_WH="$4"
  local SEED_FILE="$5"
  local DT_REFRESH="$6"
  local VERIFY_SQL="$7"
  local ISSUE_ID="$8"

  local BRANCH="feature/${ISSUE_ID}-deploy-${DOMAIN_LOWER}"
  local WIP_DB="WIP_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local TEST_DB="TEST_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local UAT_DB="UAT_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local PREPROD_DB="PREPROD_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local PROD_DB="PROD_${DOMAIN}_CORE_DB"
  local DEV_DB="DEV_${DOMAIN}_CORE_DB"
  local DCM_PROJECT="${DOMAIN}_CORE_PROJECT"

  local DEV_DEVELOPER="DEV_${DOMAIN}_DEVELOPER"
  local DEV_SYSADMIN="DEV_${DOMAIN}_SYSADMIN"
  local PROD_SYSADMIN="PROD_${DOMAIN}_SYSADMIN"

  # --- WIP ---
  section "${DOMAIN} Domain — Part 1: Developer Workflow (WIP)"

  step "Create feature branch for ${DOMAIN}" \
    "Branch off main to isolate ${DOMAIN} domain changes." \
    "git checkout main && git pull && git checkout -b ${BRANCH}"

  step "Copy ${DOMAIN} definitions" \
    "Copy ${DOMAIN} definitions from test/${DOMAIN_LOWER}_definitions/
  into the active DCM folder for deployment." \
    "cp -r test/${DOMAIN_LOWER}_definitions/* domains/${DOMAIN_LOWER}/dcm/sources/definitions/ && rm -f domains/${DOMAIN_LOWER}/dcm/sources/definitions/.gitkeep"

  step "Commit and push" \
    "Commit the ${DOMAIN} domain code and push the feature branch." \
    "git add -A && git commit -m 'feat(${DOMAIN_LOWER}): initial ${DOMAIN} domain code (#${ISSUE_ID})' && git push -u origin ${BRANCH}"

  step "Create WIP clone" \
    "Create a zero-copy clone of ${DEV_DB} for development.
  Clone name: ${WIP_DB}" \
    "snow sql -c DEVACC --role ${DEV_DEVELOPER} --warehouse ${DEV_WH} -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', '${DOMAIN}', 'CORE', 'WIP');\""

  step "Deploy DCM to WIP" \
    "Deploy all ${DOMAIN} objects to the WIP clone via DCM." \
    "snow dcm deploy ${WIP_DB}.DCM.${DCM_PROJECT} --from domains/${DOMAIN_LOWER}/dcm --target DEV --variable \"db='${WIP_DB}'\" -c DEVACC --role ${DEV_DEVELOPER} --warehouse ${DEV_WH}"

  step "Load seed data" \
    "Insert test data into the WIP clone RAW tables." \
    "snow sql -f ${SEED_FILE} -c DEVACC --role ${DEV_DEVELOPER} --warehouse ${DEV_WH} -D \"db=${WIP_DB}\" --enable-templating JINJA"

  step "Refresh dynamic tables" \
    "Materialise dynamic tables from upstream views." \
    "snow sql -c DEVACC --role ${DEV_DEVELOPER} --warehouse ${DEV_WH} -q \"${DT_REFRESH//__DB__/${WIP_DB}}\""

  step "Verify WIP deployment" \
    "Query reporting views to confirm the pipeline works." \
    "snow sql -c DEVACC --role ${DEV_DEVELOPER} --warehouse ${DEV_WH} -q \"${VERIFY_SQL//__DB__/${WIP_DB}}\""

  pause_gate "${DOMAIN} WIP verified. Promoting to TEST via CI/CD..."

  # --- TEST ---
  section "${DOMAIN} Domain — Part 2: Promote to TEST"

  step "Create PR to test/main" \
    "PR the feature branch into test/main. When merged, the CI/CD
  workflow creates a TEST clone and deploys ${DOMAIN} code." \
    "gh pr create --base test/main --head ${BRANCH} --title 'Deploy ${DOMAIN} to TEST (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: ${DOMAIN} domain deployment'"

  step "Merge PR (triggers CI/CD)" \
    "Merging triggers the 'Deploy to TEST' workflow.
  Watch ~/actions-runner terminal for progress." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify TEST clone" \
    "Confirm the TEST clone was created and has data." \
    "snow sql -c DEVACC --role ${DEV_SYSADMIN} --warehouse ${DEV_WH} -q \"SHOW DATABASES LIKE '${TEST_DB}'; ${VERIFY_SQL//__DB__/${TEST_DB}}\""

  pause_gate "${DOMAIN} TEST verified. Promoting to UAT (PROD account)..."

  # --- UAT ---
  section "${DOMAIN} Domain — Part 3: Promote to UAT"

  step "Create PR to uat/main" \
    "Promote test/main to uat/main. Triggers deployment on PROD account." \
    "gh pr create --base uat/main --head test/main --title 'Promote ${DOMAIN} to UAT (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: TEST approved'"

  step "Merge PR (triggers CI/CD on PROD)" \
    "Creates ${UAT_DB} on the PROD account." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify UAT clone" \
    "Confirm UAT clone on PROD account." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"SHOW DATABASES LIKE '${UAT_DB}';\""

  pause_gate "${DOMAIN} UAT verified. Promoting to PREPROD..."

  # --- PREPROD ---
  section "${DOMAIN} Domain — Part 4: Promote to PREPROD"

  step "Create PR to preprod/main" \
    "Final pre-production gate." \
    "gh pr create --base preprod/main --head uat/main --title 'Promote ${DOMAIN} to PREPROD (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: UAT approved'"

  step "Merge PR (triggers CI/CD)" \
    "Creates ${PREPROD_DB} on PROD account." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify PREPROD clone" \
    "Confirm PREPROD clone on PROD account." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"SHOW DATABASES LIKE '${PREPROD_DB}';\""

  pause_gate "${DOMAIN} PREPROD verified. Deploying to PRODUCTION..."

  # --- PROD ---
  section "${DOMAIN} Domain — Part 5: Deploy to PRODUCTION"

  step "Create PR to prod/main" \
    "Production deployment — deploys directly to ${PROD_DB}." \
    "gh pr create --base prod/main --head preprod/main --title 'Release ${DOMAIN} to Production (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: PREPROD verified'"

  step "Merge PR (deploys to PROD)" \
    "DCM deploys to the base production database." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify PRODUCTION" \
    "Count objects in ${PROD_DB}." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"SELECT table_schema, count(*) as object_count FROM ${PROD_DB}.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1 ORDER BY 1;\""

  # --- CLEANUP ---
  section "${DOMAIN} Domain — Part 6: Cleanup"

  step "Drop WIP clone" \
    "Remove the developer WIP sandbox." \
    "snow sql -c DEVACC --role ${DEV_SYSADMIN} --warehouse ${DEV_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', '${DOMAIN}', 'CORE', 'WIP');\""

  step "Drop TEST clone" \
    "Remove the TEST clone from DEV." \
    "snow sql -c DEVACC --role ${DEV_SYSADMIN} --warehouse ${DEV_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', '${DOMAIN}', 'CORE', 'TEST');\""

  step "Drop UAT clone" \
    "Remove UAT from PROD." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', '${DOMAIN}', 'CORE', 'UAT');\""

  step "Drop PREPROD clone" \
    "Remove PREPROD from PROD." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', '${DOMAIN}', 'CORE', 'PREPROD');\""

  step "Delete feature branch" \
    "Clean up the ${DOMAIN} feature branch." \
    "git checkout main && git pull && git branch -D ${BRANCH} && git push origin --delete ${BRANCH} 2>/dev/null || true"

  echo ""
  echo -e "${GREEN}  ${DOMAIN} domain complete: WIP → TEST → UAT → PREPROD → PROD${RESET}"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
clear

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}║   FCI RBAC Framework — Full Pipeline Demo                                ║${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}║   Deploys three domains through the complete lifecycle:                   ║${RESET}"
echo -e "${BOLD}║     1. GENERAL  (reference data: dates, countries, currencies)            ║${RESET}"
echo -e "${BOLD}║     2. HR       (employees, departments, SCD2 history)                    ║${RESET}"
echo -e "${BOLD}║     3. BRF      (budgets, cost centers, variance analysis)                ║${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}║   Each domain: WIP → TEST → UAT → PREPROD → PROD                        ║${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${YELLOW}Prerequisites:${RESET}"
echo "  - Both accounts deployed (full_reset.sh)"
echo "  - Self-hosted runner listening (~/actions-runner/run.sh)"
echo "  - GitHub secrets configured"
echo ""
echo -e "${YELLOW}Usage:${RESET}  ./demo.sh          (run or resume)"
echo "        ./demo.sh --reset  (start fresh)"
echo ""

# --- GENERAL ---
# Create issue if we don't already have one from a previous run
if [[ -z "${GENERAL_ISSUE:-}" ]]; then
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}Domain 1 of 3: GENERAL${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo "  Next: Create a GitHub issue for the GENERAL domain."
  read -rp "  Press RETURN to create issue..."
  echo ""
  GENERAL_ISSUE=$(gh issue create --title "Deploy GENERAL domain code" --body "Reference data: dates, countries, currencies" --assignee @me 2>&1 | grep -oE '[0-9]+$')
  echo -e "  ${GREEN}Issue #${GENERAL_ISSUE} created${RESET}"
  echo ""
  gh issue list
  echo ""
  save_state
  read -rp "  Press RETURN to continue..."
  echo ""
fi

GENERAL_DT="ALTER DYNAMIC TABLE __DB__.DM.D_DATE REFRESH; ALTER DYNAMIC TABLE __DB__.DM.D_COUNTRY REFRESH;"
GENERAL_VERIFY="SELECT * FROM __DB__.RPT.VW_COUNTRY_DIRECTORY; SELECT * FROM __DB__.RPT.VW_CURRENCY_RATES_SUMMARY LIMIT 10;"

deploy_domain "GENERAL" "general" "GENERAL_DEV_WH" "GENERAL_REPORTING_WH" \
  "test/seed_general.sql" "$GENERAL_DT" "$GENERAL_VERIFY" "$GENERAL_ISSUE"

# --- HR ---
if [[ -z "${HR_ISSUE:-}" ]]; then
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}Domain 2 of 3: HR${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo "  Next: Create a GitHub issue for the HR domain."
  read -rp "  Press RETURN to create issue..."
  echo ""
  HR_ISSUE=$(gh issue create --title "Deploy HR domain code" --body "Employees, departments, jobs, SCD2 history" --assignee @me 2>&1 | grep -oE '[0-9]+$')
  echo -e "  ${GREEN}Issue #${HR_ISSUE} created${RESET}"
  echo ""
  gh issue list
  echo ""
  save_state
  read -rp "  Press RETURN to continue..."
  echo ""
fi

HR_DT="ALTER DYNAMIC TABLE __DB__.DM.D_EMPLOYEE_CURRENT REFRESH; ALTER DYNAMIC TABLE __DB__.DM.D_DEPARTMENT_CURRENT REFRESH; ALTER DYNAMIC TABLE __DB__.DM.D_JOB_CURRENT REFRESH; ALTER DYNAMIC TABLE __DB__.DM.F_EMPLOYEE_JOB_HISTORY REFRESH; ALTER DYNAMIC TABLE __DB__.DM.F_EMPLOYEE_COMP_HISTORY REFRESH;"
HR_VERIFY="SELECT * FROM __DB__.RPT.VW_HEADCOUNT_BY_DEPARTMENT; SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, IS_CURRENT FROM __DB__.STG.V_EMPLOYEES_HISTORY WHERE EMPLOYEE_ID = 'EMP-001';"

deploy_domain "HR" "hr" "HR_DEV_WH" "HR_REPORTING_WH" \
  "test/seed_hr.sql" "$HR_DT" "$HR_VERIFY" "$HR_ISSUE"

# --- BRF ---
if [[ -z "${BRF_ISSUE:-}" ]]; then
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}Domain 3 of 3: BRF${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo "  Next: Create a GitHub issue for the BRF domain."
  read -rp "  Press RETURN to create issue..."
  echo ""
  BRF_ISSUE=$(gh issue create --title "Deploy BRF domain code" --body "Budgets, cost centers, GL accounts, variance analysis" --assignee @me 2>&1 | grep -oE '[0-9]+$')
  echo -e "  ${GREEN}Issue #${BRF_ISSUE} created${RESET}"
  echo ""
  gh issue list
  echo ""
  save_state
  read -rp "  Press RETURN to continue..."
  echo ""
fi

BRF_DT="ALTER DYNAMIC TABLE __DB__.DM.D_COST_CENTER REFRESH; ALTER DYNAMIC TABLE __DB__.DM.F_BUDGET_VARIANCE REFRESH;"
BRF_VERIFY="SELECT * FROM __DB__.RPT.VW_BUDGET_VARIANCE_BY_DIVISION; SELECT * FROM __DB__.RPT.VW_COST_CENTER_SUMMARY;"

deploy_domain "BRF" "brf" "BRF_DEV_WH" "BRF_REPORTING_WH" \
  "test/seed_brf.sql" "$BRF_DT" "$BRF_VERIFY" "$BRF_ISSUE"

# --- DONE ---
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Demo complete!${RESET}"
echo -e "${GREEN}  All 3 domains deployed through the full pipeline:${RESET}"
echo -e "${GREEN}    GENERAL: WIP → TEST → UAT → PREPROD → PROD${RESET}"
echo -e "${GREEN}    HR:      WIP → TEST → UAT → PREPROD → PROD${RESET}"
echo -e "${GREEN}    BRF:     WIP → TEST → UAT → PREPROD → PROD${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
clear_state
