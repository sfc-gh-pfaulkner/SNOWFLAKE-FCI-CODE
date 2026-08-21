#!/bin/bash
set -euo pipefail

# =============================================================================
# FCI RBAC Framework — PII Governance Demo
# =============================================================================
# Demonstrates tag-based masking on the HR domain.
# Supports resume: saves progress to .demo_pii_progress
# Use --reset to start fresh.
# =============================================================================

STATE_FILE=".demo_pii_progress"

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

step_num=0
resume_from=0

save_state() {
  echo "STEP=${step_num}" > "$STATE_FILE"
  echo "ISSUE_ID=${ISSUE_ID:-}" >> "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    resume_from=${STEP:-0}
  fi
}

clear_state() { rm -f "$STATE_FILE"; }

if [[ "${1:-}" == "--reset" ]]; then
  clear_state
  echo "  State cleared. Starting fresh."
fi

load_state
if [[ $resume_from -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}  Previous run found — completed ${resume_from} steps.${RESET}"
  if [[ -n "${ISSUE_ID:-}" ]]; then echo "    Issue: #${ISSUE_ID}"; fi
  echo ""
  read -rp "  Resume from step $((resume_from + 1))? [Y/n] " choice
  if [[ "$choice" == "n" || "$choice" == "N" ]]; then
    clear_state
    resume_from=0
    ISSUE_ID=""
  fi
  echo ""
fi

step() {
  step_num=$((step_num + 1))
  if [[ $step_num -le $resume_from ]]; then return 0; fi
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
  if [[ $step_num -lt $resume_from ]]; then return 0; fi
  echo ""
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║  $1${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
}

pause_gate() {
  if [[ $step_num -le $resume_from ]]; then return 0; fi
  echo ""
  echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${RESET}"
  echo -e "${YELLOW}  $1${RESET}"
  echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${RESET}"
  echo ""
  read -rp "Press RETURN when ready to continue..."
}

# =============================================================================
clear

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}║   FCI RBAC Framework — PII Governance Demo                               ║${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}║   Shows tag-based dynamic masking on HR personal data.                   ║${RESET}"
echo -e "${BOLD}║   Columns are tagged with PII classification; masking policies           ║${RESET}"
echo -e "${BOLD}║   automatically mask data unless the user holds a PII access role.       ║${RESET}"
echo -e "${BOLD}║                                                                          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${YELLOW}Prerequisites:${RESET}"
echo "  - HR domain deployed (run demo.sh first for the HR domain)"
echo "  - functional_roles redeployed with PII roles"
echo "  - DEV_HR_DEVELOPER role granted to your user"
echo ""

# Create issue if we don't already have one
if [[ -z "${ISSUE_ID:-}" ]]; then
  echo "  Creating GitHub issue for PII update..."
  ISSUE_ID=$(gh issue create --title "Apply PII tags to HR data" --body "Tag personal data columns for automatic masking" --assignee @me 2>&1 | grep -oE '[0-9]+$')
  echo -e "  ${GREEN}Issue #${ISSUE_ID} created${RESET}"
  echo ""
  save_state
  read -rp "  Press RETURN to continue..."
fi

BRANCH="feature/${ISSUE_ID}-hr-pii-tags"
WIP_DB="WIP_${ISSUE_ID}_HR_CORE_DB"

# =============================================================================
section "Part 1: Apply PII Tags"
# =============================================================================

step "Create feature branch" \
  "Branch off main for the PII tagging work." \
  "git checkout main && git pull && git checkout -b ${BRANCH}"

step "Copy HR definitions + PII tags" \
  "Copy the full HR domain code and the PII tagging script.
  The PII script goes into post_deploy/ — the CI/CD workflow
  automatically runs all scripts in that folder after DCM deploys." \
  "mkdir -p domains/hr/dcm/sources/definitions && cp -r test/hr_definitions/* domains/hr/dcm/sources/definitions/ && rm -f domains/hr/dcm/sources/definitions/.gitkeep && mkdir -p domains/hr/post_deploy && cp test/hr_update_01/pii_tags.sql domains/hr/post_deploy/"

step "Commit and push" \
  "Commit the PII tagging update." \
  "git add -A && git commit -m 'feat(hr): apply PII tags to personal data columns (#${ISSUE_ID})' && git push -u origin ${BRANCH}"

step "Create WIP clone" \
  "Clone DEV_HR_CORE_DB to test the PII tags." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'WIP');\""

step "Deploy DCM (creates tables/views)" \
  "DCM deploys the HR domain objects to the WIP clone." \
  "snow dcm deploy ${WIP_DB}.DCM.HR_CORE_PROJECT --from domains/hr/dcm --target DEV --variable \"db='${WIP_DB}'\" -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH"

step "Apply PII tags (post-deploy)" \
  "Run the PII tagging script from post_deploy/. In CI/CD this runs
  automatically. Here we run it manually to show what happens." \
  "snow sql -f domains/hr/post_deploy/pii_tags.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -D \"db=${WIP_DB}\" --enable-templating JINJA"

step "Load test data" \
  "Insert employee data so we can see the masking in action." \
  "snow sql -f test/seed_hr.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -D \"db=${WIP_DB}\" --enable-templating JINJA"

pause_gate "PII tags applied and data loaded. Now let's see the masking in action..."

# =============================================================================
section "Part 2: Verify Masking Behaviour"
# =============================================================================

step "Query as DEVELOPER (owner — sees all)" \
  "The DEVELOPER role owns the objects. Object owners bypass masking
  policies, so all data is visible unmasked." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"select EMPLOYEE_ID, FIRST_NAME, LAST_NAME, EMAIL, DATE_OF_BIRTH, GENDER from ${WIP_DB}.RAW.EMPLOYEES_RAW limit 5;\""

step "Query as ANALYST (no PII role — fully masked)" \
  "The ANALYST role has read access via future grants but does NOT
  hold any PII access role. All PII columns are masked." \
  "snow sql -c DEVACC --role DEV_HR_ANALYST --warehouse HR_REPORTING_WH -q \"select EMPLOYEE_ID, FIRST_NAME, LAST_NAME, EMAIL, DATE_OF_BIRTH, GENDER from ${WIP_DB}.RAW.EMPLOYEES_RAW limit 5;\""

step "Query as MANAGER (partial access — partially masked)" \
  "The MANAGER role holds PII_HR_PARTIAL_ACCESS. CONFIDENTIAL columns
  show first letter + asterisks. SENSITIVE columns are null." \
  "snow sql -c DEVACC --role DEV_HR_MANAGER --warehouse HR_REPORTING_WH -q \"select EMPLOYEE_ID, FIRST_NAME, LAST_NAME, EMAIL, DATE_OF_BIRTH, GENDER from ${WIP_DB}.RAW.EMPLOYEES_RAW limit 5;\""

step "Query as DATASTEWARD (full access — sees everything)" \
  "The DATASTEWARD role holds PII_HR_FULL_ACCESS. All PII data
  is visible unmasked — they need it for data quality work." \
  "snow sql -c DEVACC --role DEV_HR_DATASTEWARD --warehouse HR_REPORTING_WH -q \"select EMPLOYEE_ID, FIRST_NAME, LAST_NAME, EMAIL, DATE_OF_BIRTH, GENDER from ${WIP_DB}.RAW.EMPLOYEES_RAW limit 5;\""

step "Check compensation masking (ANALYST)" \
  "Salary and bonus data is also tagged as SENSITIVE/FINANCIAL_PROFILE.
  ANALYST sees null for these columns." \
  "snow sql -c DEVACC --role DEV_HR_ANALYST --warehouse HR_REPORTING_WH -q \"select EMPLOYEE_ID, SALARY_AMOUNT, BONUS_TARGET_PCT, CURRENCY_CODE from ${WIP_DB}.RAW.COMPENSATION_EVENTS_RAW limit 5;\""

pause_gate "Masking verified across all role levels."

# =============================================================================
section "Part 3: Verify Tag Metadata"
# =============================================================================

step "Show tagged columns" \
  "Query the tag references to see which columns are classified." \
  "snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q \"select TAG_NAME, TAG_VALUE, COLUMN_NAME, OBJECT_NAME from table(${WIP_DB}.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('${WIP_DB}.RAW.EMPLOYEES_RAW', 'table')) order by COLUMN_NAME, TAG_NAME;\""

# =============================================================================
section "Part 4: Cleanup"
# =============================================================================

step "Drop WIP clone" \
  "Remove the WIP sandbox." \
  "snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q \"CALL ADMIN_DB.DEPLOY.DROP_CLONE('${ISSUE_ID}', 'DEV', 'HR', 'CORE', 'WIP');\""

step "Delete feature branch" \
  "Clean up." \
  "git checkout main && git branch -D ${BRANCH} && git push origin --delete ${BRANCH} 2>/dev/null || true"

step "Close issue" \
  "Mark the PII work as done." \
  "gh issue close ${ISSUE_ID}"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  PII Governance Demo Complete!${RESET}"
echo -e "${GREEN}${RESET}"
echo -e "${GREEN}  Key takeaways:${RESET}"
echo -e "${GREEN}    - Tags applied as post-deploy scripts (domains/<name>/post_deploy/)${RESET}"
echo -e "${GREEN}    - Masking is automatic — no per-column policy attachment needed${RESET}"
echo -e "${GREEN}    - Access controlled by PII_<DOMAIN>_FULL/PARTIAL_ACCESS roles${RESET}"
echo -e "${GREEN}    - CI/CD runs post_deploy/*.sql automatically after DCM${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
clear_state
