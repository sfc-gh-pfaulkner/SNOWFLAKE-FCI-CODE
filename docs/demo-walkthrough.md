# FCI RBAC Framework — End-to-End Demo Walkthrough

## Prerequisites

- Both Snowflake accounts deployed (full_reset.sh completed)
- `DEV_HR_DEVELOPER` role granted to your user
- Self-hosted GitHub Actions runner listening (`~/actions-runner/run.sh`)
- GitHub secrets configured: DEV_ACCOUNT, DEV_USER, DEV_PRIVATE_KEY, PROD_ACCOUNT, PROD_USER, PROD_PRIVATE_KEY
- HR definitions stored at `~/hr_backup/` (not yet in the repo)

---

## Part 1: Developer Workflow (WIP Clone)

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 1.1 Create a GitHub issue | `gh issue create --title "Deploy HR base code" --body "Initial HR domain code" --assignee @me` | Issue created (note the number, e.g. #2) |
| 1.2 Create feature branch | `git checkout -b feature/2-deploy-hr-base-code` | Switched to new branch |
| 1.3 Add HR domain code | `cp -r test/hr_definitions/* domains/hr/dcm/sources/definitions/ && rm -f domains/hr/dcm/sources/definitions/.gitkeep` | 31 new files in the definitions folder |
| 1.4 Commit and push | `git add -A && git commit -m "feat(hr): initial HR domain code" && git push -u origin feature/2-deploy-hr-base-code` | Branch pushed to remote |
| 1.5 Create WIP clone | `snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DEPLOY_CLONE('2', 'DEV', 'HR', 'CORE', 'WIP');"` | SUCCESS: WIP clone "WIP_2_HR_CORE_DB" created. SAFE snapshot also created. |
| 1.6 Deploy code to WIP | `snow dcm deploy WIP_2_HR_CORE_DB.DCM.HR_CORE_PROJECT --from domains/hr/dcm --target DEV --variable "db='WIP_2_HR_CORE_DB'" -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH` | Deployed 36 entities (29 created, 7 altered, 0 dropped) |
| 1.7 Load test data | `snow sql -f test/seed_data.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -D "db='WIP_2_HR_CORE_DB'" --enable-templating JINJA` | Seed data loaded (10 jobs, 5 depts, 15 employees, 21 job events, 26 comp events) |
| 1.8 Refresh dynamic tables | `ALTER DYNAMIC TABLE WIP_2_HR_CORE_DB.DM.D_JOB_CURRENT REFRESH;` (repeat for all 5 DM tables) | Each returns insertedRows > 0 |
| 1.9 Verify reporting views | `SELECT * FROM WIP_2_HR_CORE_DB.RPT.VW_HEADCOUNT_BY_DEPARTMENT;` | Returns 4 departments with headcounts (Platform Engineering: 7, Data Engineering: 2, Analytics: 4, People Operations: 2) |
| 1.10 Verify SCD2 history | `SELECT * FROM WIP_2_HR_CORE_DB.STG.V_EMPLOYEES_HISTORY WHERE EMPLOYEE_ID = 'EMP-001';` | Returns 2 rows: Alice Smith (VALID_TO < 9999) and Alice Johnson (IS_CURRENT = true) |
| 1.11 Developer satisfied | Code works in WIP — ready to promote to TEST | History and current views working correctly |

---

## Part 2: Promote to TEST (CI/CD via PR merge)

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 2.1 Create PR to test/main | `gh pr create --base test/main --title "Deploy HR base code to TEST" --body "Issue #2: Initial HR domain deployment"` | PR created with diff showing 31 HR definition files |
| 2.2 Merge the PR | `gh pr merge --merge --admin` | PR merged. GitHub Actions "Deploy to TEST" workflow triggers. |
| 2.3 Self-hosted runner executes | Watch the runner terminal (`~/actions-runner`) | detect-changes runs, only deploy-hr triggered (BRF/GENERAL skipped) |
| 2.4 Workflow completes | `gh run list --limit 1` | deploy-hr: conclusion "success", ~2-3 minutes |
| 2.5 Verify TEST clone exists | `SHOW DATABASES LIKE 'TEST_2%';` | TEST_2_HR_CORE_DB exists, owned by DEV_HR_SYSADMIN |
| 2.6 Verify test data loaded | `USE ROLE DEV_HR_ANALYST; SELECT * FROM TEST_2_HR_CORE_DB.RPT.VW_HEADCOUNT_BY_DEPARTMENT;` | ANALYST can see departments with headcounts (test data seeded by workflow) |

**PAUSE: Manual verification by stakeholders before proceeding to UAT.**

---

## Part 3: Promote to UAT (PROD account clone)

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 3.1 Create PR to uat/main | `gh pr create --base uat/main --head test/main --title "Promote HR to UAT" --body "Approved after TEST verification"` | PR created |
| 3.2 Merge the PR | `gh pr merge --merge --admin` | PR merged. "Deploy to UAT" workflow triggers on PROD account. |
| 3.3 Workflow creates UAT clone | Runner executes DEPLOY_CLONE on PRODACC | SUCCESS: UAT_2_HR_CORE_DB created from PROD_HR_CORE_DB |
| 3.4 Verify UAT clone | `snow sql -c PRODACC --role PROD_HR_ETL --warehouse HR_REPORTING_WH -q "SHOW SCHEMAS IN DATABASE UAT_2_HR_CORE_DB;"` | 5 schemas: RAW, STG, INT, DM, RPT + DCM |

**PAUSE: UAT sign-off by business stakeholders before PREPROD.**

---

## Part 4: Promote to PREPROD

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 4.1 Create PR to preprod/main | `gh pr create --base preprod/main --head uat/main --title "Promote HR to PREPROD" --body "UAT approved"` | PR created |
| 4.2 Merge the PR | `gh pr merge --merge --admin` | "Deploy to PREPROD" workflow triggers. |
| 4.3 Verify PREPROD clone | PREPROD_2_HR_CORE_DB created on PROD account | MANAGER role has read-only access |

**PAUSE: Final review before production deployment.**

---

## Part 5: Deploy to PROD (requires admin approval)

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 5.1 Create PR to prod/main | `gh pr create --base prod/main --head preprod/main --title "Release HR to Production" --body "PREPROD verified, ready for production"` | PR created (requires approval if branch protection enabled) |
| 5.2 Admin approves and merges | Admin reviews PR, approves, merges | "Deploy to Production" workflow triggers |
| 5.3 DCM deploys to PROD base DB | Workflow runs `snow dcm deploy --target PROD` against PROD_HR_CORE_DB | Objects created/altered in production database |
| 5.4 Verify production | `snow sql -c PRODACC --role PROD_HR_ANALYST --warehouse HR_REPORTING_WH -q "SELECT table_schema, count(*) FROM PROD_HR_CORE_DB.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1;"` | 29 objects across 5 schemas in production |

---

## Part 6: Cleanup

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 6.1 Drop WIP clone | `snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('2', 'DEV', 'HR', 'CORE', 'WIP');"` | WIP clone dropped |
| 6.2 Drop TEST clone | `snow sql -c DEVACC --role DEV_HR_ETL --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('2', 'DEV', 'HR', 'CORE', 'TEST');"` | TEST clone dropped |
| 6.3 Drop UAT clone | `snow sql -c PRODACC --role PROD_HR_ETL --warehouse HR_REPORTING_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('2', 'PROD', 'HR', 'CORE', 'UAT');"` | UAT clone dropped |
| 6.4 Drop PREPROD clone | `snow sql -c PRODACC --role PROD_HR_ETL --warehouse HR_REPORTING_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('2', 'PROD', 'HR', 'CORE', 'PREPROD');"` | PREPROD clone dropped |
| 6.5 Delete feature branch | `git checkout main && git branch -D feature/2-deploy-hr-base-code` | Branch deleted |

---

## Key Points for Demo Audience

| Topic | Detail |
|-------|--------|
| **Clone lifecycle** | WIP (dev) → TEST (CI) → UAT (business) → PREPROD (final) → PROD (live) |
| **Who creates clones?** | DEVELOPER role (WIP) or ETL role (TEST/UAT/PREPROD via CI/CD) |
| **Who deploys code?** | DEVELOPER to WIP; ETL to all promotion clones and PROD |
| **Who verifies?** | ANALYST/MANAGER roles on TEST; business stakeholders on UAT; admin sign-off for PROD |
| **What triggers promotion?** | PR merge to test/main, uat/main, preprod/main, or prod/main |
| **How is PROD protected?** | Branch protection on prod/main requiring admin approval |
| **Change detection** | Only domains with modified files are deployed (BRF/GENERAL skipped if unchanged) |
| **Test data** | Automatically seeded into WIP/TEST clones by the workflow (not in UAT/PREPROD — those clone PROD data) |
| **Rollback** | SAFE clone (auto-created with WIP) provides point-in-time snapshot; PREPROD clone available until PROD completes |
| **Self-hosted runner** | Required due to org network policy; runs on VPN-connected machine |
