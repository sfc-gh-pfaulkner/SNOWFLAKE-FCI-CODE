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
  echo "  First create an issue:  gh issue create --title \"Deploy HR base code\" --body \"Initial HR domain code\" --assignee @me"
  echo "  Then run:               ./demo.sh <issue_number>"
  exit 1
fi

ISSUE_ID="$1"
BRANCH="feature/${ISSUE_ID}-deploy-hr-base-code"
WIP_DB="WIP_${ISSUE_ID}_HR_CORE_DB"
TEST_DB="TEST_${ISSUE_ID}_HR_CORE_DB"
UAT_DB="UAT_${ISSUE_ID}_HR_CORE_DB"
PREPROD_DB="PREPROD_${ISSUE_ID}_HR_CORE_DB"

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
section "Part 1: Developer Workflow (WIP Clone)"
# =============================================================================

step "Create feature branch" \
  "Branch off main with a name that includes the issue number.
  This links the branch to the GitHub issue for traceability." \
  "git checkout main && git pull && git checkout -b ${BRANCH}"

step "Copy HR domain code into place" \
  "The HR definitions live in test/hr_definitions/ as a starting point.
  We copy them into the active DCM definitions folder for the HR domain." \
  "cp -r test/hr_definitions/* domains/hr/dcm/sources/definitions/ && rm -f domains/hr/dcm/sources/definitions/.gitkeep"

step "Commit and push" \
  "Stage all changes, commit with a conventional commit message,
  and push the feature branch to origin." \
  "git add -A && git commit -m 'feat(hr): initial HR domain code (#${ISSUE_ID})' && git push -u origin ${BRANCH}"

step "Create WIP clone" \
  "Call the DEPLOY_CLONE stored procedure to create a zero-copy clone
  of DEV_HR_CORE_DB. This gives you an isolated sandbox (${WIP_DB})
  to develop and test in without affecting the base database." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'WIP');\""

step "Deploy DCM to WIP clone" \
  "Use DCM (Declarative Configuration Management) to deploy all HR
  domain objects (tables, views, dynamic tables) into the WIP clone.
  The --variable override tells DCM to target the clone database." \
  "snow dcm deploy ${WIP_DB}.DCM.HR_CORE_PROJECT --from domains/hr/dcm --target DEV --variable \"db='${WIP_DB}'\" -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH"

step "Load test data" \
  "Insert seed data into the RAW schema tables. This includes 15
  employees, 5 departments, 10 jobs, and SCD2 history events.
  The Jinja template substitutes the database name automatically." \
  "snow sql -f test/seed_data.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -D \"db=${WIP_DB}\" --enable-templating JINJA"

step "Refresh dynamic tables" \
  "Dynamic tables in the DM schema need an initial refresh to
  materialise data from the upstream staging views." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"ALTER DYNAMIC TABLE ${WIP_DB}.DM.D_EMPLOYEE_CURRENT REFRESH; ALTER DYNAMIC TABLE ${WIP_DB}.DM.D_DEPARTMENT_CURRENT REFRESH; ALTER DYNAMIC TABLE ${WIP_DB}.DM.D_JOB_CURRENT REFRESH; ALTER DYNAMIC TABLE ${WIP_DB}.DM.F_EMPLOYEE_JOB_HISTORY REFRESH; ALTER DYNAMIC TABLE ${WIP_DB}.DM.F_EMPLOYEE_COMP_HISTORY REFRESH;\""

step "Verify reporting views" \
  "Query a reporting view to confirm the pipeline works end-to-end.
  Expected: 4 active departments with headcounts." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"SELECT * FROM ${WIP_DB}.RPT.VW_HEADCOUNT_BY_DEPARTMENT;\""

step "Verify SCD2 history" \
  "Check that Slowly Changing Dimension Type 2 logic works.
  EMP-001 (Alice) changed her surname — we expect 2 history rows." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, IS_CURRENT, VALID_FROM, VALID_TO FROM ${WIP_DB}.STG.V_EMPLOYEES_HISTORY WHERE EMPLOYEE_ID = 'EMP-001';\""

pause_gate "Developer satisfied. WIP clone verified. Ready to promote to TEST via CI/CD."

# =============================================================================
section "Part 2: Promote to TEST (CI/CD via PR merge)"
# =============================================================================

step "Create PR to test/main" \
  "Create a pull request from the feature branch into the test/main
  promotion branch. When merged, this triggers the 'Deploy to TEST'
  GitHub Actions workflow." \
  "gh pr create --base test/main --head ${BRANCH} --title 'Deploy HR base code to TEST (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: Initial HR domain deployment to TEST environment'"

step "Merge the PR (triggers CI/CD)" \
  "Merging the PR triggers the GitHub Actions workflow which will:
  1. Detect that HR domain files changed
  2. Create a TEST clone (${TEST_DB})
  3. Deploy DCM code to the clone
  4. Seed test data
  Watch your self-hosted runner terminal for progress." \
  "gh pr merge --merge --admin"

echo ""
echo "  Waiting for the GitHub Actions workflow to complete..."
echo "  (Watch ~/actions-runner terminal for live output)"
echo ""
wait_for_workflow

step "Verify TEST clone exists" \
  "Confirm the workflow created the TEST clone database." \
  "snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"SHOW DATABASES LIKE '${TEST_DB}';\""

step "Verify TEST data (as ANALYST)" \
  "Confirm that a read-only ANALYST role can query the reporting
  views in the TEST clone — proving RBAC is working correctly." \
  "snow sql -c DEVACC --role DEV_HR_ANALYST --warehouse HR_REPORTING_WH -q \"SELECT * FROM ${TEST_DB}.RPT.VW_HEADCOUNT_BY_DEPARTMENT;\""

pause_gate "TEST verified by stakeholders. Ready to promote to UAT (PROD account)."

# =============================================================================
section "Part 3: Promote to UAT (PROD account)"
# =============================================================================

step "Create PR to uat/main" \
  "Promote from test/main to uat/main. This triggers deployment
  on the PROD account — creating a UAT clone of PROD_HR_CORE_DB." \
  "gh pr create --base uat/main --head test/main --title 'Promote HR to UAT (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: Approved after TEST verification'"

step "Merge the PR (triggers CI/CD on PROD account)" \
  "The 'Deploy to UAT' workflow creates ${UAT_DB} on the PROD
  account, deploys code, and seeds test data." \
  "gh pr merge --merge --admin"

echo ""
wait_for_workflow

step "Verify UAT clone" \
  "Confirm the UAT clone was created on the PROD account." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"SHOW DATABASES LIKE '${UAT_DB}';\""

pause_gate "UAT signed off by business stakeholders. Ready to promote to PREPROD."

# =============================================================================
section "Part 4: Promote to PREPROD"
# =============================================================================

step "Create PR to preprod/main" \
  "Final pre-production gate. Creates a PREPROD clone on the PROD
  account for last-stage validation." \
  "gh pr create --base preprod/main --head uat/main --title 'Promote HR to PREPROD (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: UAT approved'"

step "Merge the PR (triggers CI/CD)" \
  "The 'Deploy to PREPROD' workflow creates ${PREPROD_DB}." \
  "gh pr merge --merge --admin"

echo ""
wait_for_workflow

step "Verify PREPROD clone" \
  "Confirm PREPROD clone exists on PROD account." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"SHOW DATABASES LIKE '${PREPROD_DB}';\""

pause_gate "PREPROD verified. Ready for PRODUCTION deployment."

# =============================================================================
section "Part 5: Deploy to PRODUCTION"
# =============================================================================

step "Create PR to prod/main" \
  "This is the production deployment gate. In a real environment,
  branch protection rules would require admin approval before merge." \
  "gh pr create --base prod/main --head preprod/main --title 'Release HR to Production (#${ISSUE_ID})' --body 'Issue #${ISSUE_ID}: PREPROD verified, ready for production'"

step "Merge the PR (deploys to PROD_HR_CORE_DB)" \
  "The 'Deploy to Production' workflow runs DCM deploy directly
  against PROD_HR_CORE_DB (no clone — this is the real thing)." \
  "gh pr merge --merge --admin"

echo ""
wait_for_workflow

step "Verify production objects" \
  "Count objects per schema in the production database." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"SELECT table_schema, count(*) as object_count FROM PROD_HR_CORE_DB.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1 ORDER BY 1;\""

step "Verify production reporting (as ANALYST)" \
  "Confirm the ANALYST role can query production reporting views." \
  "snow sql -c PRODACC --role PROD_HR_ANALYST --warehouse HR_REPORTING_WH -q \"SELECT * FROM PROD_HR_CORE_DB.RPT.VW_HEADCOUNT_BY_DEPARTMENT;\""

pause_gate "Production deployment complete. Ready to clean up."

# =============================================================================
section "Part 6: Cleanup"
# =============================================================================

step "Drop WIP clone (DEV)" \
  "Remove the developer's WIP sandbox." \
  "snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'WIP');\""

step "Drop TEST clone (DEV)" \
  "Remove the TEST clone from the DEV account." \
  "snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'TEST');\""

step "Drop UAT clone (PROD)" \
  "Remove the UAT clone from the PROD account." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'HR', 'CORE', 'UAT');\""

step "Drop PREPROD clone (PROD)" \
  "Remove the PREPROD clone from the PROD account." \
  "snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'PROD', 'HR', 'CORE', 'PREPROD');\""

step "Delete feature branch" \
  "Clean up the feature branch locally and on the remote." \
  "git checkout main && git branch -D ${BRANCH} && git push origin --delete ${BRANCH} 2>/dev/null || true"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Demo complete! Full pipeline: WIP → TEST → UAT → PREPROD → PROD${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
