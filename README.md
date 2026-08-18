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
snow dcm deploy --from functional_roles -c DEVACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
snow dcm deploy --from functional_roles -c PRODACC --role DEPLOYMENT_ADMIN --warehouse ADMIN_WH
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
gh issue create --title "Initial HR domain deployment" --body ""
git checkout main && git pull
git checkout -b feature/1-initial-hr-deployment
```

### 2. Create a WIP clone

```bash
snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DEPLOY_CLONE('1', 'DEV', 'HR', 'CORE', 'WIP');"
```

Creates `WIP_1_HR_CORE_DB` (your workspace) and `SAFE_1_HR_CORE_DB` (rollback snapshot).

### 3. Develop and deploy to your clone

Add/edit DCM definitions in `domains/hr/dcm/sources/definitions/`, then deploy to the WIP clone:

```bash
snow dcm deploy --from domains/hr/dcm --target WIP -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH
```

Note: you'll need a `WIP` target in your domain manifest pointing at the clone database. See the Warehouses section for template variable conventions.

### 4. Push and create a PR

```bash
git add . && git commit -m "Initial HR domain deployment"
git push -u origin feature/1-initial-hr-deployment
gh pr create --title "Initial HR domain deployment" --body ""
```

Merging to `test/*` triggers automated TEST clone deployment.

### 5. Promote through environments

Code moves through environments via PRs to specific branches. CI/CD handles clone creation and deployment automatically at each stage.

| Step | Action | What CI does |
|------|--------|--------------|
| TEST | Merge PR to `test/hr` | Creates TEST clone of DEV_HR_CORE_DB, deploys DCM into it |
| UAT | Merge PR from `test/hr` to `uat/hr` | Creates UAT clone of PROD_HR_CORE_DB in PRODACC, deploys DCM |
| PREPROD | Merge PR from `uat/hr` to `preprod/hr` | Creates PREPROD clone in PRODACC, also deploys to DEV base |
| PROD | Merge PR from `preprod/hr` to `main` | Deploys to PROD_HR_CORE_DB, drops UAT/PREPROD clones |

Each promotion is a PR — reviewers approve before merging triggers the next stage.

### 6. Clean up

After production deployment, drop your WIP and SAFE clones:

```bash
snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('1', 'DEV', 'HR', 'CORE', 'WIP');"
snow sql -c DEVACC --role DEV_HR_DEVELOPER --warehouse HR_DEV_WH -q "call ADMIN_DB.DEPLOY.DROP_CLONE('1', 'DEV', 'HR', 'CORE', 'SAFE');"
```

---

## Adding a New Domain

1. Add domain registration and database/schema/warehouse calls to `setup/provision_databases.sql`
2. Re-run provisioning in both accounts
3. Create `domains/<name>/dcm/manifest.yml` following the existing pattern
4. Add the domain to `functional_roles/` grants
5. Add the domain to the CI/CD workflow jobs in `.github/workflows/`

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
| `test.yml` | `deploy-to-clone.yml` | PR merged to `test/*` — creates TEST clone per domain |
| `uat.yml` | `deploy-to-clone.yml` | PR merged to `uat/*` — creates UAT clone in PRODACC |
| `prod.yml` | `deploy-to-prod.yml` | Push to `main` — deploys to PROD, cleans up clones |

Each workflow runs `snow dcm plan` before deploying, so the PR check shows what would change. If `snow dcm test` expectations are defined, they run after deployment and fail the workflow on violations.

To add a new domain to CI/CD, add a job block to each workflow file.

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
