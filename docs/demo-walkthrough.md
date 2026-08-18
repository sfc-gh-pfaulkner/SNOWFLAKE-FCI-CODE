# FCI RBAC Framework — End-to-End Demo Walkthrough

## Prerequisites

- Both Snowflake accounts deployed (full_reset.sh completed)
- `DEV_HR_DEVELOPER` role granted to your user
- Self-hosted GitHub Actions runner listening (`~/actions-runner/run.sh`)
- GitHub secrets configured: DEV_ACCOUNT, DEV_USER, DEV_PRIVATE_KEY, PROD_ACCOUNT, PROD_USER, PROD_PRIVATE_KEY

---

## Part 1: Developer Workflow (WIP Clone)

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 1.1 Create a GitHub issue | `gh issue create --title "Deploy HR base code" --body "Initial HR domain code" --assignee @me` | Issue created (note the number, e.g. #2) |
| 1.2 Create feature branch | `git checkout -b feature/2-deploy-hr-base-code` | Switched to new branch |
| 1.3 Add HR domain code | `cp -r ~/hr_backup/* domains/hr/dcm/sources/definitions/ && rm -f domains/hr/dcm/sources/definitions/.gitkeep` | 31 new files in the definitions folder |
| 1.4 Commit and push | `git add -A && git commit -m "feat(hr): initial HR domain code" && git push -u origin feature/2-deploy-hr-base-code` | Branch pushed to remote |
| 1.5 Create WIP clone | `snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DEPLOY_CLONE('2', 'DEV', 'HR', 'CORE', 'WIP');"` | SUCCESS: WIP clone "WIP_2_HR_CORE_DB" created. SAFE snapshot also created. |
| 1.6 Deploy code to WIP | `snow dcm deploy WIP_2_HR_CORE_DB.DCM.HR_CORE_PROJECT --from domains/hr/dcm --target DEV --variable "db='WIP_2_HR_CORE_DB'" -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH` | Deployed 36 entities (29 created, 7 altered, 0 dropped) |
| 1.7 Insert test data | Connect as DEV_HR_DEVELOPER, insert rows into all 5 RAW tables (JOBS, DEPARTMENTS, EMPLOYEES, EMPLOYEE_JOB_EVENTS, COMPENSATION_EVENTS) | Rows inserted successfully |
| 1.8 Refresh dynamic tables | `ALTER DYNAMIC TABLE WIP_2_HR_CORE_DB.DM.D_JOB_CURRENT REFRESH;` (repeat for all 5 DM tables) | Each returns insertedRows > 0 |
| 1.9 Verify reporting views | `SELECT * FROM WIP_2_HR_CORE_DB.RPT.VW_HEADCOUNT_BY_DEPARTMENT;` | Returns department name(s) with headcount |
| 1.10 Developer satisfied | Code works in WIP — ready to promote to TEST | All RPT views return correct aggregated data |

---

## Part 2: CI/CD Pipeline — Promote to TEST

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 2.1 Create PR to test/main | `gh pr create --base test/main --title "Deploy HR base code to TEST" --body "Issue #2: Initial HR domain deployment"` | PR created with diff showing HR definitions added |
| 2.2 Merge the PR | `gh pr merge --merge --admin` | PR merged. GitHub Actions workflow triggers automatically. |
| 2.3 Self-hosted runner picks up job | Watch the runner terminal (`~/actions-runner`) | Shows "Running job: deploy-hr / deploy-to-clone" |
| 2.4 Observe: Clone creation | Runner executes `DEPLOY_CLONE('2', 'DEV', 'HR', 'CORE', 'TEST')` as DEV_HR_ETL | SUCCESS: TEST clone created |
| 2.5 Observe: DCM deploy | Runner executes `snow dcm deploy` with `--variable "db='TEST_2_HR_CORE_DB'"` | Deployed 36 entities |
| 2.6 Workflow completes | `gh run list --limit 1` | deploy-hr: conclusion "success" |
| 2.7 Verify ANALYST access | `USE ROLE DEV_HR_ANALYST; USE WAREHOUSE HR_REPORTING_WH; SELECT table_schema, count(*) FROM TEST_2_HR_CORE_DB.information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','DCM') GROUP BY 1;` | 5 schemas with 29 total objects visible |

---

## Part 3: Cleanup

| Step | Instructions | Expected Outcome |
|------|-------------|------------------|
| 3.1 Drop WIP clone | `snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('2', 'DEV', 'HR', 'CORE', 'WIP');"` | SUCCESS: WIP clone dropped. Developer grants revoked. |
| 3.2 Drop TEST clone | `snow sql -c DEVACC --role DEV_HR_ETL --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('2', 'DEV', 'HR', 'CORE', 'TEST');"` | SUCCESS: TEST clone dropped. |
| 3.3 Delete feature branch | `git checkout main && git branch -D feature/2-deploy-hr-base-code` | Branch deleted locally |

---

## Key Points for Demo Audience

| Topic | Detail |
|-------|--------|
| **Who creates clones?** | DEVELOPER role (WIP) or ETL role (TEST/UAT/PREPROD via CI/CD) |
| **Who deploys code?** | DEVELOPER to WIP clones; ETL to promotion clones via automated pipeline |
| **Who verifies?** | ANALYST, MANAGER, DATASTEWARD roles have read-only access to TEST/UAT/PREPROD clones |
| **What triggers promotion?** | PR merge to `test/main`, `uat/main`, or `prod/main` branch |
| **How is PROD protected?** | Branch protection on `prod/main` requiring admin approval before merge |
| **What about rollback?** | SAFE clone created automatically with every WIP — provides point-in-time snapshot of source |
| **Multi-domain isolation?** | Each domain deploys independently; BRF/GENERAL failures don't block HR |
| **Warehouse model** | Shared GENERAL_INGEST/TRANSFORM_WH for all domains; dedicated REPORTING and DEV warehouses per domain |
| **Self-hosted runner** | Required due to org network policy; runs on any machine with VPN access |
