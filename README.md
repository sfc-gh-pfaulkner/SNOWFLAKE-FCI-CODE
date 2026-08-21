# SNOWFLAKE-FCI-CODE

All Snowflake domain code for the FCI organisation. Each business domain has its own DCM project under `domains/`. Functional roles and provisioning are managed here.

---

## Repo Structure

```
SNOWFLAKE-FCI-CODE/
├── setup/
│   └── provision_databases.sql       # Environments, domains, databases, warehouses, roles
├── functional_roles/                 # DCM project: grants for DEVELOPER, ANALYST, etc.
├── domains/
│   ├── general/dcm/                  # Cross-domain reference data
│   ├── hr/dcm/                       # Human Resources
│   └── brf/dcm/                      # Business & Retail Finance
└── .github/workflows/                # CI/CD triggers
```

---

## First-Time Setup

Prerequisites: the [snowflake-rbac-framework](https://github.com/sfc-gh-pfaulkner/snowflake-rbac-framework) must be deployed in both accounts first.

### 1. Provision environments, domains, databases, warehouses, and roles

```bash
snow sql -f setup/provision_databases.sql -c DEVACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
snow sql -f setup/provision_databases.sql -c PRODACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
```

### 2. Deploy functional roles (grants)

The DCM project is created automatically by the RBAC framework. Just deploy:
```bash
snow dcm deploy --from functional_roles --target DEV -c DEVACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
snow dcm deploy --from functional_roles --target PROD -c PRODACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
```

### 3. Grant DEVELOPER role to your user (skip if managed by Okta/SCIM)

In production, Okta/SCIM assigns users to roles automatically. For environments without SCIM, grant manually:

```bash
snow sql -c DEVACC --role ACCOUNTADMIN --warehouse COMPUTE_WH -q "grant role DEV_HR_DEVELOPER to user <YOUR_USER>;"
```

Setup is complete. Domain code is deployed through the development workflow below — never directly to base databases.

---

## Development Workflow

### 1. Create a GitHub issue and feature branch

```bash
gh issue create --title "Deploy HR domain code" --body "Initial HR deployment" --assignee @me
# Note the issue number (e.g. 5)
git checkout main && git pull
git checkout -b feature/5-deploy-hr
```

### 2. Create a WIP clone

```bash
snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH \
  -q "call ADMIN_DB.DEPLOY.DEPLOY_CLONE('5', 'DEV', 'HR', 'CORE', 'WIP');"
```

Creates `WIP_5_HR_CORE_DB` (your workspace) and `SAFE_5_HR_CORE_DB` (rollback snapshot).

### 3. Develop and deploy to your clone

Add/edit DCM definitions in `domains/hr/dcm/sources/definitions/`, then deploy:

```bash
snow dcm deploy WIP_5_HR_CORE_DB.DCM.HR_CORE_PROJECT \
  --from domains/hr/dcm \
  --target DEV \
  --variable "db='WIP_5_HR_CORE_DB'" \
  -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH
```

Load test data (if applicable):
```bash
snow sql -f test/seed_hr.sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH \
  -D "db=WIP_5_HR_CORE_DB" --enable-templating JINJA
```

Note: `--variable` uses inner quotes (`db='VALUE'`), but `-D` does not (`db=VALUE`).

### 4. Push and create a PR to test/main

```bash
git add -A && git commit -m "feat(hr): initial HR domain code (#5)"
git push -u origin feature/5-deploy-hr
gh pr create --base test/main --head feature/5-deploy-hr \
  --title "Deploy HR to TEST (#5)" --body "Issue #5"
```

### 5. Promote through environments

Code moves through environments via PRs to promotion branches. CI/CD handles clone creation, DCM deployment, and test data seeding automatically.

| Step | Action | What CI does |
|------|--------|--------------|
| TEST | Merge PR to `test/main` | Creates TEST clone of DEV_HR_CORE_DB, deploys DCM, seeds data |
| UAT | PR from `test/main` to `uat/main`, merge | Creates UAT clone of PROD_HR_CORE_DB on PROD account |
| PREPROD | PR from `uat/main` to `preprod/main`, merge | Creates PREPROD clone on PROD account |
| PROD | PR from `preprod/main` to `prod/main`, merge | Deploys directly to PROD_HR_CORE_DB (no clone) |

Each promotion is a PR merge. The CI/CD workflow uses change detection — only domains with modified files are deployed.

### 6. Clean up

After production deployment, drop clones:

```bash
# DEV account
snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH \
  -q "call ADMIN_DB.DEPLOY.DROP_CLONE('5', 'DEV', 'HR', 'CORE', 'WIP');"
snow sql -c DEVACC --role DEV_HR_SYSADMIN --warehouse HR_DEV_WH \
  -q "call ADMIN_DB.DEPLOY.DROP_CLONE('5', 'DEV', 'HR', 'CORE', 'TEST');"
# PROD account
snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH \
  -q "call ADMIN_DB.DEPLOY.DROP_CLONE('5', 'PROD', 'HR', 'CORE', 'UAT');"
snow sql -c PRODACC --role PROD_HR_SYSADMIN --warehouse HR_REPORTING_WH \
  -q "call ADMIN_DB.DEPLOY.DROP_CLONE('5', 'PROD', 'HR', 'CORE', 'PREPROD');"
```

Delete the feature branch:
```bash
git checkout main && git branch -D feature/5-deploy-hr
git push origin --delete feature/5-deploy-hr
```

---

## Adding a New Domain

1. Add domain registration and database/schema/warehouse calls to `setup/provision_databases.sql`
2. Re-run provisioning in both accounts
3. Create `domains/<name>/dcm/manifest.yml` following the existing pattern (must include `defaults` section with `db` for `--variable` override)
4. Add the domain to `functional_roles/manifest.yml` under `templating.defaults.domains` (include `reporting_wh` and `dev_wh`)
5. Redeploy functional_roles to both accounts:
   ```
   snow dcm deploy --from functional_roles --target DEV -c DEVACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
   snow dcm deploy --from functional_roles --target PROD -c PRODACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
   ```
6. Add the domain to the CI/CD workflow jobs in `.github/workflows/` (test.yml, uat.yml, preprod.yml, prod.yml)
7. Grant roles to users — DCM cannot do `GRANT ROLE ... TO USER`. Either:
   - Manually: `grant role <ENV>_<DOMAIN>_DEVELOPER to user <USERNAME>;`
   - Via SCIM/IdP: map identity provider groups to Snowflake roles

---

## Warehouses

Each domain has access to both **shared** warehouses (owned by GENERAL) and **dedicated** warehouses. The DCM manifest is the single switch point — developers never hardcode warehouse names.

### Template variables

| Variable | Purpose |
|----------|---------|
| `{{ingest_wh}}` | Ingestion tasks (COPY INTO, Snowpipe refresh) |
| `{{transform_wh}}` | Dynamic tables, transformation tasks |
| `{{reporting_wh}}` | Reporting views, BI-facing workloads |
| `{{dev_wh}}` | Developer ad-hoc use (DEV only) |

Example:
```sql
DEFINE DYNAMIC TABLE {{db}}.DM.D_EMPLOYEE_CURRENT
    WAREHOUSE = {{transform_wh}}
    TARGET_LAG = '1 hour'
AS
    select ...
```

### Switching between shared and dedicated

In the domain manifest (`domains/<name>/dcm/manifest.yml`):

```yaml
# Shared (all domains use GENERAL warehouses):
      ingest_wh: GENERAL_INGEST_WH

# Dedicated (domain has its own):
      ingest_wh: HR_INGEST_WH
```

Redeploy to apply: `snow dcm deploy --target DEV --project-dir domains/hr/dcm`

Both shared and dedicated warehouses are pre-provisioned. Unused ones auto-suspend and cost nothing.

---

## CI/CD

This repo contains **trigger workflows** that define *when* to deploy and *which domains*. The deployment logic lives in reusable templates in [snowflake-rbac-framework](https://github.com/sfc-gh-pfaulkner/snowflake-rbac-framework).

| This repo (trigger) | Calls (template) | When |
|---------------------|------------------|------|
| `test.yml` | `deploy-to-clone.yml` | PR merged to `test/main` — creates TEST clone in DEV |
| `uat.yml` | `deploy-to-clone.yml` | PR merged to `uat/main` — creates UAT clone in PROD |
| `preprod.yml` | `deploy-to-clone.yml` | PR merged to `preprod/main` — creates PREPROD clone in PROD |
| `prod.yml` | `deploy-to-prod.yml` | PR merged to `prod/main` — deploys directly to PROD databases |

Each workflow runs change detection first — only domains with modified files are deployed. Seed data (`test/seed_<domain>.sql`) is loaded automatically into clones if the file exists.

A self-hosted GitHub Actions runner is required (org network policy blocks hosted runners). Start with: `~/actions-runner/run.sh`

To add a new domain to CI/CD, add a job block to each workflow file (test.yml, uat.yml, preprod.yml, prod.yml).

---

## Branch Protection

Configure these rules in GitHub (Settings → Branches → Branch protection rules) to enforce the promotion workflow:

| Branch pattern | Required reviewers | Additional checks |
|---------------|-------------------|-------------------|
| `main` | 2 | Lint must pass |
| `preprod/*` | 1 | Lint must pass |
| `uat/*` | 1 | Lint must pass |
| `test/*` | 1 | Lint must pass |

This ensures:
- No one can push directly to protected branches — all changes go through PRs
- Production deployments require two sign-offs
- Linting and DCM plan checks must pass before merge is allowed

To configure via CLI:
```bash
gh api repos/sfc-gh-pfaulkner/SNOWFLAKE-FCI-CODE/branches/main/protection -X PUT -f 'required_pull_request_reviews[required_approving_review_count]=2' -f 'required_status_checks[strict]=true' -f 'required_status_checks[contexts][]=lint'
```

---

## Linting

```bash
pip install pre-commit
pre-commit install
```

Runs SQLFluff and yamllint on commit. Manual run:

```bash
pre-commit run --all-files
```
