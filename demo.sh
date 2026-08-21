#!/bin/bash
set -euo pipefail

# =============================================================================
# FCI RBAC Framework — Interactive Demo Script
# =============================================================================
# Usage: ./demo.sh <ISSUE_NUMBER>
#
# Prerequisites:
#   - Both Snowflake accounts deployed (full_reset.sh completed)
#   - DEV_HR_DEVELOPER role granted to your user
#   - Self-hosted GitHub Actions runner listening (~/actions-runner/run.sh)
#   - GitHub secrets configured
#   - Must be run from the FCI-CODE repo root directory
# =============================================================================

if [[ $# -ne 1 ]]; then
  echo "Usage: ./demo.sh <ISSUE_NUMBER>"
  echo "  First create an issue:  gh issue create --title \"Deploy all domain code\" --body \"Initial domain code\" --assignee @me"
  echo "  Then run:               ./demo.sh <issue_number>"
  exit 1
fi

ISSUE_ID="$1"
BRANCH="feature/${ISSUE_ID}-deploy-domain-code"

# Database names for WIP clones
WIP_GENERAL="WIP_${ISSUE_ID}_GENERAL_CORE_DB"
WIP_HR="WIP_${ISSUE_ID}_HR_CORE_DB"
WIP_BRF="WIP_${ISSUE_ID}_BRF_CORE_DB"

# Database names for TEST clones
TEST_GENERAL="TEST_${ISSUE_ID}_GENERAL_CORE_DB"
TEST_HR="TEST_${ISSUE_ID}_HR_CORE_DB"
TEST_BRF="TEST_${ISSUE_ID}_BRF_CORE_DB"

# Database names for PROD clones
UAT_GENERAL="UAT_${ISSUE_ID}_GENERAL_CORE_DB"
UAT_HR="UAT_${ISSUE_ID}_HR_CORE_DB"
UAT_BRF="UAT_${ISSUE_ID}_BRF_CORE_DB"
PREPROD_GENERAL="PREPROD_${ISSUE_ID}_GENERAL_CORE_DB"
PREPROD_HR="PREPROD_${ISSUE_ID}_HR_CORE_DB"
PREPROD_BRF="PREPROD_${ISSUE_ID}_BRF_CORE_DB"

# Colours for output
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
  echo "  Check status: gh run list --limit 1"
  return 1
}

# =============================================================================
section "Part 1: Developer Workflow — Setup and Code"
# =============================================================================

step "Create feature branch" \
  "Branch off main with a name that includes the issue number.
  This links the branch to the GitHub issue for traceability." \
  "git checkout main && git pull && git checkout -b ${BRANCH}"

step "Copy GENERAL domain code" \
  "Copy reference data definitions (date dimension, country codes,
  currency rates) into the GENERAL domain DCM folder." \
  "cp -r test/general_definitions/* domains/general/dcm/sources/definitions/ && rm -f domains/general/dcm/sources/definitions/.gitkeep"

step "Copy HR domain code" \
  "Copy HR definitions (employees, departments, jobs, SCD2 history,
  dynamic tables, reporting views) into the HR domain DCM folder." \
  "cp -r test/hr_definitions/* domains/hr/dcm/sources/definitions/ && rm -f domains/hr/dcm/sources/definitions/.gitkeep"

step "Copy BRF domain code" \
  "Copy Business Reporting Framework definitions (cost centers, GL
  accounts, budgets, variance analysis) into the BRF domain DCM folder." \
  "cp -r test/brf_definitions/* domains/brf/dcm/sources/definitions/ && rm -f domains/brf/dcm/sources/definitions/.gitkeep"

step "Commit and push" \
  "Stage all domain code changes, commit with a conventional message,
  and push the feature branch to origin." \
  "git add -A && git commit -m 'feat: initial domain code for GENERAL, HR, BRF (#${ISSUE_ID})' && git push -u origin ${BRANCH}"

# =============================================================================
section "Part 1b: Deploy GENERAL to WIP"
# =============================================================================

step "Create GENERAL WIP clone" \
  "Create a zero-copy clone of DEV_GENERAL_CORE_DB for development.
  This gives you an isolated sandbox (${WIP_GENERAL})." \
  "snow sql -c DEVACC --role DEV_GENERAL_DEVELOPER --warehouse GENERAL_TRANSFORM_WH -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', 'GENERAL', 'CORE', 'WIP');\""

step "Deploy DCM to GENERAL WIP" \
  "Deploy all GENERAL domain objects (date dimension table, country
  codes, currency rates, staging views, dynamic tables) to the clone." \
  "snow dcm deploy ${WIP_GENERAL}.DCM.GENERAL_CORE_PROJECT --from domains/general/dcm --target DEV --variable \"db='${WIP_GENERAL}'\" -c DEVACC --role DEV_GENERAL_DEVELOPER --warehouse GENERAL_TRANSFORM_WH"

step "Load GENERAL seed data" \
  "Insert reference data: 3 years of dates (2024-2026), 10 countries,
  and 12 currency exchange rate snapshots." \
  "snow sql -f test/seed_general.sql -c DEVACC --role DEV_GENERAL_DEVELOPER --warehouse GENERAL_TRANSFORM_WH -D \"db=${WIP_GENERAL}\" --enable-templating JINJA"

step "Refresh GENERAL dynamic tables" \
  "Materialise the D_DATE and D_COUNTRY dimension tables from the
  staging views." \
  "snow sql -c DEVACC --role DEV_GENERAL_DEVELOPER --warehouse GENERAL_TRANSFORM_WH -q \"ALTER DYNAMIC TABLE ${WIP_GENERAL}.DM.D_DATE REFRESH; ALTER DYNAMIC TABLE ${WIP_GENERAL}.DM.D_COUNTRY REFRESH;\""

step "Verify GENERAL reporting" \
  "Check the country directory report and currency rates summary." \
  "snow sql -c DEVACC --role DEV_GENERAL_DEVELOPER --warehouse GENERAL_TRANSFORM_WH -q \"SELECT * FROM ${WIP_GENERAL}.RPT.VW_COUNTRY_DIRECTORY; SELECT * FROM ${WIP_GENERAL}.RPT.VW_CURRENCY_RATES_SUMMARY LIMIT 10;\""

pause_gate "GENERAL domain deployed and verified. Moving to HR..."

# =============================================================================
section "Part 1c: Deploy HR to WIP"
# =============================================================================

step "Create HR WIP clone" \
  "Create a zero-copy clone of DEV_HR_CORE_DB.
  Sandbox: ${WIP_HR}" \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'WIP');\""

step "Deploy DCM to HR WIP" \
  "Deploy all HR domain objects (raw tables, SCD2 views, intermediate
  views, dynamic tables, reporting views) to the clone." \
  "snow dcm deploy ${WIP_HR}.DCM.HR_CORE_PROJECT --from domains/hr/dcm --target DEV --variable \"db='${WIP_HR}'\" -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH"

step "Load HR seed data" \
  "Insert test data: 15 employees with SCD2 history, 5 departments,
  10 jobs, 21 job events, 26 compensation events." \
  "snow sql -f test/seed_data.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -D \"db=${WIP_HR}\" --enable-templating JINJA"

step "Refresh HR dynamic tables" \
  "Materialise all 5 DM dynamic tables from the upstream views." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"ALTER DYNAMIC TABLE ${WIP_HR}.DM.D_EMPLOYEE_CURRENT REFRESH; ALTER DYNAMIC TABLE ${WIP_HR}.DM.D_DEPARTMENT_CURRENT REFRESH; ALTER DYNAMIC TABLE ${WIP_HR}.DM.D_JOB_CURRENT REFRESH; ALTER DYNAMIC TABLE ${WIP_HR}.DM.F_EMPLOYEE_JOB_HISTORY REFRESH; ALTER DYNAMIC TABLE ${WIP_HR}.DM.F_EMPLOYEE_COMP_HISTORY REFRESH;\""

step "Verify HR reporting" \
  "Check headcount by department and SCD2 history for Alice (EMP-001)." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"SELECT * FROM ${WIP_HR}.RPT.VW_HEADCOUNT_BY_DEPARTMENT; SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, IS_CURRENT, VALID_FROM FROM ${WIP_HR}.STG.V_EMPLOYEES_HISTORY WHERE EMPLOYEE_ID = 'EMP-001';\""

pause_gate "HR domain deployed and verified. Moving to BRF..."

# =============================================================================
section "Part 1d: Deploy BRF to WIP"
# =============================================================================

step "Create BRF WIP clone" \
  "Create a zero-copy clone of DEV_BRF_CORE_DB.
  Sandbox: ${WIP_BRF}" \
  "snow sql -c DEVACC --role DEV_BRF_DEVELOPER --warehouse BRF_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', 'BRF', 'CORE', 'WIP');\""

step "Deploy DCM to BRF WIP" \
  "Deploy Business Reporting Framework objects (cost centers, GL
  accounts, budget items, variance analysis) to the clone." \
  "snow dcm deploy ${WIP_BRF}.DCM.BRF_CORE_PROJECT --from domains/brf/dcm --target DEV --variable \"db='${WIP_BRF}'\" -c DEVACC --role DEV_BRF_DEVELOPER --warehouse BRF_DEV_WH"

step "Load BRF seed data" \
  "Insert test data: 8 cost centers, 10 GL accounts, 20 budget line
  items with actuals for FY2026 Q1-Q3." \
  "snow sql -f test/seed_brf.sql -c DEVACC --role DEV_BRF_DEVELOPER --warehouse BRF_DEV_WH -D \"db=${WIP_BRF}\" --enable-templating JINJA"

step "Refresh BRF dynamic tables" \
  "Materialise D_COST_CENTER and F_BUDGET_VARIANCE from staging." \
  "snow sql -c DEVACC --role DEV_BRF_DEVELOPER --warehouse BRF_DEV_WH -q \"ALTER DYNAMIC TABLE ${WIP_BRF}.DM.D_COST_CENTER REFRESH; ALTER DYNAMIC TABLE ${WIP_BRF}.DM.F_BUDGET_VARIANCE REFRESH;\""

step "Verify BRF reporting" \
  "Check budget variance by division and cost center summary." \
  "snow sql -c DEVACC --role DEV_BRF_DEVELOPER --warehouse BRF_DEV_WH -q \"SELECT * FROM ${WIP_BRF}.RPT.VW_BUDGET_VARIANCE_BY_DIVISION; SELECT * FROM ${WIP_BRF}.RPT.VW_COST_CENTER_SUMMARY;\""

pause_gate "All 3 domains deployed and verified in WIP. Ready to promote to TEST via CI/CD."

# =============================================================================
section "Part 2: Promote to TEST (CI/CD via PR merge)"
# =============================================================================

step "Create PR to test/main" \
  "Create a pull request from the feature branch to test/main.
  When merged, the 'Deploy to TEST' workflow triggers and deploys
  ALL three domains (change detection sees all domains modified)." \
  "gh pr create --base test/main --head ${BRANCH} --title 'Deploy domain code to TEST (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: Initial deployment of GENERAL, HR, and BRF domains to TEST'"

step "Merge the PR (triggers CI/CD)" \
  "Merging triggers GitHub Actions which will:
  1. Detect changes in domains/general, domains/hr, domains/brf
  2. Create TEST clones for all three domains
  3. Deploy DCM code to each clone
  4. Seed test data
  Watch your self-hosted runner terminal for progress." \
  "gh pr merge --merge --admin"

echo ""
echo "  Waiting for the GitHub Actions workflow to complete..."
echo "  (Watch ~/actions-runner terminal for live output)"
echo ""
wait_for_workflow

step "Verify TEST clones exist" \
  "Confirm the workflow created all three TEST clone databases." \
  "snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"SHOW DATABASES LIKE 'TEST_${ISSUE_ID}_%';\""

step "Verify TEST data (GENERAL)" \
  "Check country directory in the GENERAL TEST clone." \
  "snow sql -c DEVACC --role DEV_GENERAL_ANALYST --warehouse GENERAL_REPORTING_WH -q \"SELECT * FROM ${TEST_GENERAL}.RPT.VW_COUNTRY_DIRECTORY LIMIT 5;\""

step "Verify TEST data (HR)" \
  "Check headcount report in the HR TEST clone as ANALYST." \
  "snow sql -c DEVACC --role DEV_HR_ANALYST --warehouse HR_REPORTING_WH -q \"SELECT * FROM ${TEST_HR}.RPT.VW_HEADCOUNT_BY_DEPARTMENT;\""

step "Verify TEST data (BRF)" \
  "Check budget variance in the BRF TEST clone." \
  "snow sql -c DEVACC --role DEV_BRF_ANALYST --warehouse BRF_REPORTING_WH -q \"SELECT * FROM ${TEST_BRF}.RPT.VW_BUDGET_VARIANCE_BY_DIVISION;\""

pause_gate "TEST verified by stakeholders. Ready to promote to UAT (PROD account)."

# =============================================================================
section "Part 3: Promote to UAT (PROD account)"
# =============================================================================

step "Create PR to uat/main" \
  "Promote from test/main to uat/main. This triggers deployment
  on the PROD account — creating UAT clones of all PROD databases." \
  "gh pr create --base uat/main --head test/main --title 'Promote to UAT (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: Approved after TEST verification'"

step "Merge the PR (triggers CI/CD on PROD account)" \
  "The 'Deploy to UAT' workflow creates UAT clones on the PROD
  account, deploys code, and seeds test data for all domains." \
  "gh pr merge --merge --admin"

echo ""
wait_for_workflow

step "Verify UAT clones" \
  "Confirm UAT clones were created on the PROD account." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"SHOW DATABASES LIKE 'UAT_${ISSUE_ID}_%';\""

pause_gate "UAT signed off by business stakeholders. Ready to promote to PREPROD."

# =============================================================================
section "Part 4: Promote to PREPROD"
# =============================================================================

step "Create PR to preprod/main" \
  "Final pre-production gate. Creates PREPROD clones on the PROD
  account for last-stage validation." \
  "gh pr create --base preprod/main --head uat/main --title 'Promote to PREPROD (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: UAT approved'"

step "Merge the PR (triggers CI/CD)" \
  "The 'Deploy to PREPROD' workflow creates PREPROD clones." \
  "gh pr merge --merge --admin"

echo ""
wait_for_workflow

step "Verify PREPROD clones" \
  "Confirm PREPROD clones exist on PROD account." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"SHOW DATABASES LIKE 'PREPROD_${ISSUE_ID}_%';\""

pause_gate "PREPROD verified. Ready for PRODUCTION deployment."

# =============================================================================
section "Part 5: Deploy to PRODUCTION"
# =============================================================================

step "Create PR to prod/main" \
  "This is the production deployment gate. In a real environment,
  branch protection rules would require admin approval before merge.
  This deploys directly to the base PROD databases (no clones)." \
  "gh pr create --base prod/main --head preprod/main --title 'Release to Production (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: PREPROD verified, ready for production'"

step "Merge the PR (deploys to PROD databases)" \
  "The 'Deploy to Production' workflow runs DCM deploy against
  PROD_GENERAL_CORE_DB, PROD_HR_CORE_DB, and PROD_BRF_CORE_DB." \
  "gh pr merge --merge --admin"

echo ""
wait_for_workflow

step "Verify PROD — GENERAL" \
  "Count objects in the GENERAL production database." \
  "snow sql -c PRODACC --role PROD_GENERAL_SYSADMIN --warehouse GENERAL_REPORTING_WH -q \"SELECT table_schema, count(*) as object_count FROM PROD_GENERAL_CORE_DB.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1 ORDER BY 1;\""

step "Verify PROD — HR" \
  "Count objects in the HR production database." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"SELECT table_schema, count(*) as object_count FROM PROD_HR_CORE_DB.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1 ORDER BY 1;\""

step "Verify PROD — BRF" \
  "Count objects in the BRF production database." \
  "snow sql -c PRODACC --role PROD_BRF_SYSADMIN --warehouse BRF_REPORTING_WH -q \"SELECT table_schema, count(*) as object_count FROM PROD_BRF_CORE_DB.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1 ORDER BY 1;\""

pause_gate "Production deployment complete. Ready to clean up."

# =============================================================================
section "Part 6: Cleanup"
# =============================================================================

step "Drop WIP clones (DEV)" \
  "Remove all three developer WIP sandboxes." \
  "snow sql -c DEVACC --role DEV_GENERAL_SYSADMIN --warehouse GENERAL_TRANSFORM_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'GENERAL', 'CORE', 'WIP');\" && snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'WIP');\" && snow sql -c DEVACC --role DEV_BRF_SYSADMIN --warehouse BRF_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'BRF', 'CORE', 'WIP');\""

step "Drop TEST clones (DEV)" \
  "Remove all three TEST clones from the DEV account." \
  "snow sql -c DEVACC --role DEV_GENERAL_SYSADMIN --warehouse GENERAL_TRANSFORM_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'GENERAL', 'CORE', 'TEST');\" && snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'TEST');\" && snow sql -c DEVACC --role DEV_BRF_SYSADMIN --warehouse BRF_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'BRF', 'CORE', 'TEST');\""

step "Drop UAT clones (PROD)" \
  "Remove UAT clones from the PROD account." \
  "snow sql -c PRODACC --role PROD_GENERAL_SYSADMIN --warehouse GENERAL_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'GENERAL', 'CORE', 'UAT');\" && snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'HR', 'CORE', 'UAT');\" && snow sql -c PRODACC --role PROD_BRF_SYSADMIN --warehouse BRF_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'BRF', 'CORE', 'UAT');\""

step "Drop PREPROD clones (PROD)" \
  "Remove PREPROD clones from the PROD account." \
  "snow sql -c PRODACC --role PROD_GENERAL_SYSADMIN --warehouse GENERAL_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'GENERAL', 'CORE', 'PREPROD');\" && snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'HR', 'CORE', 'PREPROD');\" && snow sql -c PRODACC --role PROD_BRF_SYSADMIN --warehouse BRF_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'BRF', 'CORE', 'PREPROD');\""

step "Delete feature branch" \
  "Clean up the feature branch locally and on the remote." \
  "git checkout main && git branch -D ${BRANCH} && git push origin --delete ${BRANCH} 2>/dev/null || true"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Demo complete! Full pipeline for all 3 domains:${RESET}"
echo -e "${GREEN}  GENERAL + HR + BRF: WIP → TEST → UAT → PREPROD → PROD${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
