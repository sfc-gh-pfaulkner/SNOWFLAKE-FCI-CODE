#!/bin/bash
set -euo pipefail

# =============================================================================
# FCI RBAC Framework — Interactive Demo Script
# =============================================================================
# Usage: ./demo.sh
#
# Deploys each domain through the full lifecycle (WIP → TEST → UAT → PREPROD →
# PROD) before moving to the next domain. Order: GENERAL, HR, BRF.
# Pauses for you to create a separate GitHub issue per domain.
#
# Prerequisites:
#   - Both Snowflake accounts deployed (full_reset.sh completed)
#   - Developer roles granted to your user (DEV_GENERAL_DEVELOPER, etc.)
#   - Self-hosted GitHub Actions runner listening (~/actions-runner/run.sh)
#   - GitHub secrets configured
#   - Must be run from the FCI-CODE repo root directory
# =============================================================================

clear

# Colours for output
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

step_num=0

step() {
  step_num=$((step_num + 1))
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
}

section() {
  echo ""
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║  $1${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
}

pause_gate() {
  echo ""
  echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${YELLOW}  PAUSE: $1${RESET}"
  echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  read -rp "Press RETURN when ready to continue..."
}

wait_for_workflow() {
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
        echo -e "  ${YELLOW}Workflow completed with conclusion: ${conclusion}${RESET}"
        echo "  Check logs: gh run view --log-failed"
        return 1
      fi
    fi
    echo "  ... still running (${elapsed}s elapsed)"
  done
  echo "  ERROR: Workflow did not complete within ${max_wait}s"
  return 1
}

# ---------------------------------------------------------------------------
# deploy_domain: Runs the full lifecycle for one domain
# Args: DOMAIN DOMAIN_LOWER ISSUE_ID DEV_ROLE DEV_WH PROD_ROLE PROD_WH SEED_FILE DT_REFRESH_CMD VERIFY_CMD
# ---------------------------------------------------------------------------
deploy_domain() {
  local DOMAIN="$1"
  local DOMAIN_LOWER="$2"
  local ISSUE_ID="$3"
  local DEV_ROLE="$4"
  local DEV_WH="$5"
  local DEV_SYSADMIN="$6"
  local PROD_SYSADMIN="$7"
  local PROD_WH="$8"
  local SEED_FILE="$9"
  local DT_NAMES="${10}"
  local VERIFY_SQL="${11}"

  local BRANCH="feature/${ISSUE_ID}-deploy-${DOMAIN_LOWER}-code"
  local WIP_DB="WIP_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local TEST_DB="TEST_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local UAT_DB="UAT_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local PREPROD_DB="PREPROD_${ISSUE_ID}_${DOMAIN}_CORE_DB"
  local PROD_DB="PROD_${DOMAIN}_CORE_DB"
  local DCM_PROJECT="${WIP_DB}.DCM.${DOMAIN}_CORE_PROJECT"

  # --- WIP ---
  section "${DOMAIN}: Part 1 — Developer Workflow (WIP Clone)"

  step "Create feature branch for ${DOMAIN}" \
    "Branch off main for the ${DOMAIN} domain work." \
    "git checkout main && git pull && git checkout -b ${BRANCH}"

  step "Copy ${DOMAIN} domain code" \
    "Copy ${DOMAIN} definitions into the active DCM folder." \
    "cp -r test/${DOMAIN_LOWER}_definitions/* domains/${DOMAIN_LOWER}/dcm/sources/definitions/ && rm -f domains/${DOMAIN_LOWER}/dcm/sources/definitions/.gitkeep"

  step "Commit and push" \
    "Commit the ${DOMAIN} domain code and push." \
    "git add -A && git commit -m 'feat(${DOMAIN_LOWER}): initial ${DOMAIN} domain code (#${ISSUE_ID})' && git push -u origin ${BRANCH}"

  step "Create ${DOMAIN} WIP clone" \
    "Create a zero-copy clone of DEV_${DOMAIN}_CORE_DB.
  Sandbox: ${WIP_DB}" \
    "snow sql -c DEVACC --role ${DEV_ROLE} --warehouse ${DEV_WH} -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', '${DOMAIN}', 'CORE', 'WIP');\""

  step "Deploy DCM to ${DOMAIN} WIP" \
    "Deploy all ${DOMAIN} objects to the WIP clone." \
    "snow dcm deploy ${DCM_PROJECT} --from domains/${DOMAIN_LOWER}/dcm --target DEV --variable \"db='${WIP_DB}'\" -c DEVACC --role ${DEV_ROLE} --warehouse ${DEV_WH}"

  step "Load ${DOMAIN} seed data" \
    "Insert test data into the ${DOMAIN} WIP clone." \
    "snow sql -f ${SEED_FILE} -c DEVACC --role ${DEV_ROLE} --warehouse ${DEV_WH} -D \"db=${WIP_DB}\" --enable-templating JINJA"

  # Build DT refresh command
  local DT_SQL=""
  for dt in ${DT_NAMES}; do
    DT_SQL="${DT_SQL}ALTER DYNAMIC TABLE ${WIP_DB}.DM.${dt} REFRESH; "
  done

  step "Refresh ${DOMAIN} dynamic tables" \
    "Materialise dynamic tables from upstream views." \
    "snow sql -c DEVACC --role ${DEV_ROLE} --warehouse ${DEV_WH} -q \"${DT_SQL}\""

  # Verification
  local FULL_VERIFY="${VERIFY_SQL//\{DB\}/${WIP_DB}}"
  step "Verify ${DOMAIN} WIP" \
    "Run verification queries against the WIP clone." \
    "snow sql -c DEVACC --role ${DEV_ROLE} --warehouse ${DEV_WH} -q \"${FULL_VERIFY}\""

  pause_gate "${DOMAIN} WIP verified. Promoting to TEST via CI/CD..."

  # --- TEST ---
  section "${DOMAIN}: Part 2 — Promote to TEST (CI/CD)"

  step "Create PR to test/main" \
    "PR from the feature branch to test/main triggers the
  'Deploy to TEST' workflow for the ${DOMAIN} domain." \
    "gh pr create --base test/main --head ${BRANCH} --title 'Deploy ${DOMAIN} to TEST (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: ${DOMAIN} domain deployment'"

  step "Merge the PR" \
    "Merging triggers CI/CD. The workflow will:
  1. Create ${TEST_DB}
  2. Deploy DCM code
  3. Seed test data
  Watch your self-hosted runner for progress." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify TEST clone" \
    "Confirm the TEST clone was created and has data." \
    "snow sql -c DEVACC --role ${DEV_SYSADMIN} --warehouse ${DEV_WH} -q \"SHOW DATABASES LIKE '${TEST_DB}';\""

  pause_gate "${DOMAIN} TEST verified. Promoting to UAT (PROD account)..."

  # --- UAT ---
  section "${DOMAIN}: Part 3 — Promote to UAT"

  step "Create PR to uat/main" \
    "Promote test/main to uat/main. Triggers deployment on PROD account." \
    "gh pr create --base uat/main --head test/main --title 'Promote ${DOMAIN} to UAT (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: TEST approved'"

  step "Merge the PR" \
    "Creates ${UAT_DB} on the PROD account." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify UAT clone" \
    "Confirm the UAT clone on PROD account." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"SHOW DATABASES LIKE '${UAT_DB}';\""

  pause_gate "${DOMAIN} UAT signed off. Promoting to PREPROD..."

  # --- PREPROD ---
  section "${DOMAIN}: Part 4 — Promote to PREPROD"

  step "Create PR to preprod/main" \
    "Final pre-production gate for ${DOMAIN}." \
    "gh pr create --base preprod/main --head uat/main --title 'Promote ${DOMAIN} to PREPROD (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: UAT approved'"

  step "Merge the PR" \
    "Creates ${PREPROD_DB} on PROD account." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify PREPROD clone" \
    "Confirm PREPROD clone on PROD account." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"SHOW DATABASES LIKE '${PREPROD_DB}';\""

  pause_gate "${DOMAIN} PREPROD verified. Deploying to PRODUCTION..."

  # --- PROD ---
  section "${DOMAIN}: Part 5 — Deploy to PRODUCTION"

  step "Create PR to prod/main" \
    "Production deployment for ${DOMAIN}. Deploys directly to ${PROD_DB}." \
    "gh pr create --base prod/main --head preprod/main --title 'Release ${DOMAIN} to Production (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: PREPROD verified'"

  step "Merge the PR" \
    "Deploys to ${PROD_DB} (the real production database)." \
    "gh pr merge --merge --admin"

  echo ""
  wait_for_workflow

  step "Verify PROD — ${DOMAIN}" \
    "Count objects in the ${DOMAIN} production database." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"SELECT table_schema, count(*) as object_count FROM ${PROD_DB}.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1 ORDER BY 1;\""

  # --- CLEANUP ---
  section "${DOMAIN}: Part 6 — Cleanup"

  step "Drop WIP clone" \
    "Remove the ${DOMAIN} WIP sandbox." \
    "snow sql -c DEVACC --role ${DEV_SYSADMIN} --warehouse ${DEV_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', '${DOMAIN}', 'CORE', 'WIP');\""

  step "Drop TEST clone" \
    "Remove the ${DOMAIN} TEST clone." \
    "snow sql -c DEVACC --role ${DEV_SYSADMIN} --warehouse ${DEV_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', '${DOMAIN}', 'CORE', 'TEST');\""

  step "Drop UAT clone" \
    "Remove the ${DOMAIN} UAT clone." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', '${DOMAIN}', 'CORE', 'UAT');\""

  step "Drop PREPROD clone" \
    "Remove the ${DOMAIN} PREPROD clone." \
    "snow sql -c PRODACC --role ${PROD_SYSADMIN} --warehouse ${PROD_WH} -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', '${DOMAIN}', 'CORE', 'PREPROD');\""

  step "Delete feature branch" \
    "Clean up the ${DOMAIN} feature branch." \
    "git checkout main && git pull && git branch -D ${BRANCH} && git push origin --delete ${BRANCH} 2>/dev/null || true"

  echo ""
  echo -e "${GREEN}  ${DOMAIN} domain complete: WIP → TEST → UAT → PREPROD → PROD${RESET}"
  echo ""
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  FCI RBAC Framework — Full Pipeline Demo                               ║${RESET}"
echo -e "${BOLD}║  Deploys: GENERAL → HR → BRF (each through full lifecycle)             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  Ensure your self-hosted runner is listening: ~/actions-runner/run.sh"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# GENERAL DOMAIN
# ─────────────────────────────────────────────────────────────────────────────
section "GENERAL DOMAIN"
echo ""
echo -e "  Create a GitHub issue for the GENERAL domain deployment:"
echo -e "  ${GREEN}gh issue create --title \"Deploy GENERAL reference data\" --body \"Reference data: dates, countries, currencies\" --assignee @me${RESET}"
echo ""
read -rp "  Enter the GENERAL issue number: " GENERAL_ISSUE
echo ""

deploy_domain "GENERAL" "general" "$GENERAL_ISSUE" \
  "DEV_GENERAL_DEVELOPER" "GENERAL_TRANSFORM_WH" \
  "DEV_GENERAL_SYSADMIN" "PROD_GENERAL_SYSADMIN" "GENERAL_REPORTING_WH" \
  "test/seed_general.sql" \
  "D_DATE D_COUNTRY" \
  "SELECT * FROM {DB}.RPT.VW_COUNTRY_DIRECTORY LIMIT 5; SELECT * FROM {DB}.RPT.VW_CURRENCY_RATES_SUMMARY LIMIT 5;"

# ─────────────────────────────────────────────────────────────────────────────
# HR DOMAIN
# ─────────────────────────────────────────────────────────────────────────────
section "HR DOMAIN"
echo ""
echo -e "  Create a GitHub issue for the HR domain deployment:"
echo -e "  ${GREEN}gh issue create --title \"Deploy HR domain code\" --body \"Employees, departments, jobs, SCD2 history\" --assignee @me${RESET}"
echo ""
read -rp "  Enter the HR issue number: " HR_ISSUE
echo ""

deploy_domain "HR" "hr" "$HR_ISSUE" \
  "DEV_HR_DEVELOPER" "HR_DEV_WH" \
  "DEV_HR_SYSADMIN" "PROD_HR_SYSADMIN" "HR_REPORTING_WH" \
  "test/seed_hr.sql" \
  "D_EMPLOYEE_CURRENT D_DEPARTMENT_CURRENT D_JOB_CURRENT F_EMPLOYEE_JOB_HISTORY F_EMPLOYEE_COMP_HISTORY" \
  "SELECT * FROM {DB}.RPT.VW_HEADCOUNT_BY_DEPARTMENT; SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, IS_CURRENT FROM {DB}.STG.V_EMPLOYEES_HISTORY WHERE EMPLOYEE_ID = 'EMP-001';"

# ─────────────────────────────────────────────────────────────────────────────
# BRF DOMAIN
# ─────────────────────────────────────────────────────────────────────────────
section "BRF DOMAIN"
echo ""
echo -e "  Create a GitHub issue for the BRF domain deployment:"
echo -e "  ${GREEN}gh issue create --title \"Deploy BRF finance code\" --body \"Cost centers, GL accounts, budget variance\" --assignee @me${RESET}"
echo ""
read -rp "  Enter the BRF issue number: " BRF_ISSUE
echo ""

deploy_domain "BRF" "brf" "$BRF_ISSUE" \
  "DEV_BRF_DEVELOPER" "BRF_DEV_WH" \
  "DEV_BRF_SYSADMIN" "PROD_BRF_SYSADMIN" "BRF_REPORTING_WH" \
  "test/seed_brf.sql" \
  "D_COST_CENTER F_BUDGET_VARIANCE" \
  "SELECT * FROM {DB}.RPT.VW_BUDGET_VARIANCE_BY_DIVISION; SELECT * FROM {DB}.RPT.VW_COST_CENTER_SUMMARY;"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Demo complete! All 3 domains deployed through full lifecycle:${RESET}"
echo -e "${GREEN}  GENERAL → HR → BRF  (each: WIP → TEST → UAT → PREPROD → PROD)${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
