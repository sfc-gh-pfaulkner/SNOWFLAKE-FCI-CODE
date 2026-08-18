# FCI RBAC Framework — End-to-End Demo Walkthrough

## Prerequisites

- Both Snowflake accounts deployed (`full_reset.sh` completed)
- `DEV_HR_DEVELOPER` role granted to your user
- Self-hosted GitHub Actions runner listening (`~/actions-runner/run.sh`)
- GitHub secrets configured: DEV_ACCOUNT, DEV_USER, DEV_PRIVATE_KEY, PROD_ACCOUNT, PROD_USER, PROD_PRIVATE_KEY
- On `main` branch in the FCI-CODE repo with a clean working tree

---

## Quick Start

```bash
# 1. Create a GitHub issue (note the number it returns)
gh issue create --title "Deploy HR base code" --body "Initial HR domain code" --assignee @me

# 2. Run the interactive demo script with that issue number
./demo.sh <ISSUE_NUMBER>
```

The script walks through the entire pipeline step-by-step, explaining what each command does and waiting for RETURN before executing.

---

## Pipeline Overview

```
WIP Clone (DEV)     — Developer sandbox, manual deploy
       |
    PR merge to test/main
       |
TEST Clone (DEV)    — CI/CD deploys, stakeholders verify
       |
    PR merge to uat/main
       |
UAT Clone (PROD)    — Business sign-off on PROD account
       |
    PR merge to preprod/main
       |
PREPROD Clone (PROD) — Final gate before production
       |
    PR merge to prod/main
       |
PROD_HR_CORE_DB     — Production deployment (no clone)
```

---

## Key Points

| Topic | Detail |
|-------|--------|
| **Clone lifecycle** | WIP (dev) -> TEST (CI) -> UAT (business) -> PREPROD (final) -> PROD (live) |
| **Who creates clones?** | DEVELOPER (WIP) or SYSADMIN via CI/CD (TEST/UAT/PREPROD) |
| **Who deploys code?** | DEVELOPER to WIP; domain SYSADMIN to promotion clones and PROD |
| **Who verifies?** | ANALYST on TEST; business stakeholders on UAT; admin sign-off for PROD |
| **What triggers promotion?** | PR merge to test/main, uat/main, preprod/main, or prod/main |
| **Change detection** | Only domains with modified files are deployed (BRF/GENERAL skipped if unchanged) |
| **Test data** | Automatically seeded into all clones by the workflow |
| **Rollback** | SAFE clone (auto-created with WIP) provides point-in-time snapshot |
| **Self-hosted runner** | Required due to org network policy; runs on local machine |

---

## Manual Execution Reference

If you prefer to run commands individually rather than using the script, the key commands are:

| Action | Command |
|--------|---------|
| Create WIP clone | `snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "CALL ADMIN_DB.DEPLOY.DEPLOY_CLONE('<ID>', 'DEV', 'HR', 'CORE', 'WIP');"` |
| Deploy to WIP | `snow dcm deploy WIP_<ID>_HR_CORE_DB.DCM.HR_CORE_PROJECT --from domains/hr/dcm --target DEV --variable "db='WIP_<ID>_HR_CORE_DB'" -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH` |
| Seed test data | `snow sql -f test/seed_data.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -D "db=WIP_<ID>_HR_CORE_DB" --enable-templating JINJA` |
| Refresh DTs | `snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "ALTER DYNAMIC TABLE WIP_<ID>_HR_CORE_DB.DM.D_EMPLOYEE_CURRENT REFRESH; ..."` |
| Drop clone | `snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH -q "CALL ADMIN_DB.DEPLOY.DROP_CLONE('<ID>', 'DEV', 'HR', 'CORE', 'WIP');"` |

Replace `<ID>` with your issue number throughout.
