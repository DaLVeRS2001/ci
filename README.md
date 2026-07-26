# Central CI

This public repository contains reusable GitHub Actions workflows and
project-specific deployment actions. It contains execution mechanics, not
application source, runtime secrets, Compose models, or deployment manifests.

## Repository Layout

```text
.github/workflows/
  pixaeron.yml           reusable Pixaeron backend verify/deploy workflow
  pixaeron-frontend.yml  reusable Pixaeron frontend verify/deploy workflow
  validate.yml           validation for this central repository

actions/pixaeron/deploy-service/
  action.yml         exposes the versioned script path to a workflow job
  deploy-service.sh  remote Compose deployment and rollback implementation
```

There is intentionally no anticipated `actions/shared` abstraction. Shared
actions should be added only after another project has real duplicate
mechanics.

## Pixaeron Ownership Boundary

The Pixaeron application repository owns files that must change atomically with
application code:

```text
.github/workflows/ci.yml       event triggers and caller permission ceiling
.github/deploy-services.json   deployable Nx project metadata
docker-compose.production.yaml production runtime model
apps/*/Dockerfile              service image definitions
```

This repository owns:

```text
.github/workflows/pixaeron.yml
actions/pixaeron/deploy-service/action.yml
actions/pixaeron/deploy-service/deploy-service.sh
```

The reusable workflow runs in the caller repository context. Its
`actions/checkout` steps therefore check out Pixaeron, not this repository.
The composite action is referenced separately by a full commit SHA so GitHub
downloads the action and its co-located shell script from this repository.

## Caller Contract

The Pixaeron caller has this shape:

```yaml
name: CI/CD

on:
  push:
    branches:
      - main
  pull_request:
  workflow_dispatch:
    inputs:
      service:
        description: Deploy service project name or all
        required: true
        default: all
        type: string

permissions:
  actions: read
  contents: read

jobs:
  pipeline:
    permissions:
      actions: read
      contents: read
      id-token: write
      packages: write
    uses: DaLVeRS2001/ci/.github/workflows/pixaeron.yml@FULL_COMMIT_SHA
    with:
      service: ${{ inputs.service || 'all' }}
    secrets:
      VPS_HOST: ${{ secrets.VPS_HOST }}
      VPS_USER: ${{ secrets.VPS_USER }}
      VPS_SSH_PRIVATE_KEY: ${{ secrets.VPS_SSH_PRIVATE_KEY }}
      VPS_KNOWN_HOSTS: ${{ secrets.VPS_KNOWN_HOSTS }}
```

The exact pinned SHA is intentionally maintained in the application repository
instead of this example.

## What The Pixaeron Workflow Does

The `verify` job:

1. starts isolated PostgreSQL 18 and Redis 8 service containers;
2. checks out the complete Pixaeron history;
3. validates `.github/deploy-services.json`;
4. validates `docker-compose.production.yaml`;
5. installs Node.js 24 dependencies with `npm ci`;
6. runs Nx affected lint, test, build, and e2e targets;
7. builds affected deployable Dockerfiles on pull requests;
8. returns an affected deployment matrix.

The `deploy` job runs only after successful verification, outside pull
requests, for `refs/heads/main`, and through the caller's `production`
environment. It:

1. builds and pushes an immutable `sha-<pixaeron-commit>` image to GHCR;
2. obtains temporary AWS credentials through GitHub OIDC;
3. downloads and validates the service's AWS Parameter Store values;
4. creates a mode-0600 runtime env file;
5. configures SSH with a pinned `known_hosts` entry;
6. uploads Compose, runtime env, and the versioned deployment script;
7. logs the VPS into GHCR with the job token;
8. invokes the remote deployment script.

The remote script backs up live deployment files, validates Compose, pulls the
selected service and dependencies, runs an optional backward-compatible
migration, waits for health, restores the prior image/configuration on failure,
and prunes old labeled service images after success.

## Pixaeron Frontend Workflow

The frontend uses Cloudflare Workers Static Assets rather than a frontend Docker
image. Cloudflare recommends Workers Static Assets for new static sites and SPAs;
Pages remains supported but is no longer the preferred starting point. The reusable
workflow is deliberately Pixaeron-specific and does not introduce a speculative
shared frontend action.

The caller supplies only public build-time values and the Cloudflare account ID:

```text
GRAPHQL_API_URL
GOOGLE_CLIENT_ID
TURNSTILE_SITE_KEY
CLOUDFLARE_ACCOUNT_ID
```

Only `CLOUDFLARE_API_TOKEN` is secret. Store it exclusively as the frontend
repository's protected `production` environment secret and scope it to Edit
Cloudflare Workers for the Pixaeron Cloudflare account. It does not need DNS,
Tunnel, billing, or account administration permissions.

Pull requests run `npm ci` and `npm run check` without receiving the Cloudflare
token. A trusted push to `main`, or a manual run on `main`, repeats the complete
verification under the caller repository's protected `production` environment.
The token is exposed only to the final `wrangler deploy` step, and the resulting
Cloudflare version message records the caller repository and Git commit SHA.
Production deployments use a non-cancelling concurrency group. Preview
deployment is intentionally not enabled until Pixaeron has a non-production
backend, stable preview Google OAuth origin, and preview Turnstile hostname.

The frontend caller must reference this workflow by a full commit SHA. The
central workflow requires Node.js 24 and expects the caller repository to own
`wrangler.jsonc`, the exact Wrangler dependency, the Webpack build, and all
application tests.

## Permissions And Secrets

The caller job provides the maximum permission ceiling because a called
workflow can reduce permissions but cannot elevate them.

- `actions: read` supports workflow/Nx metadata reads.
- `contents: read` supports checkout.
- `id-token: write` allows only the deploy job to request a short-lived OIDC
  token; AWS IAM defines the real cloud permissions.
- `packages: write` allows only the deploy job to publish the Docker image to
  GHCR.

Application runtime secrets do not belong in this public repository.
`VPS_HOST`, `VPS_USER`, `VPS_SSH_PRIVATE_KEY`, and `VPS_KNOWN_HOSTS` remain in
the Pixaeron repository/environment. Runtime application values remain in AWS
Systems Manager Parameter Store.

The reusable deploy jobs declare `environment: production`. Environment
protection, variables such as `AWS_DEPLOY_ROLE_ARN`/`AWS_REGION`, and
environment secrets are resolved in the Pixaeron caller context. The frontend
Cloudflare token is not part of the `workflow_call` contract: the called deploy
job reads the caller repository's `production` environment secret directly.

## SHA Versioning

Never reference the central workflow or deploy action with `@main` in a
production caller.

A full commit SHA is an immutable dependency version. Pixaeron does not need to
update its SHA for every commit in this repository. Documentation changes and
changes for another product do not affect an already pinned Pixaeron workflow.

### Workflow-only update

1. Create a branch in this repository.
2. Change `.github/workflows/pixaeron.yml`.
3. Open a pull request and wait for `Validate CI repository`.
4. Merge the change.
5. Copy the full merge commit SHA.
6. Update the Pixaeron caller `uses` reference in a dedicated pull request.
7. Merge the dependency bump only after Pixaeron verification succeeds.

### Deployment-action update

The action and reusable workflow use separate immutable pins:

1. update `action.yml` and/or `deploy-service.sh`;
2. validate and commit that action change;
3. copy the full action commit SHA;
4. update the action `uses` reference inside `pixaeron.yml`;
5. validate and commit the workflow change;
6. copy the resulting workflow commit SHA;
7. update the Pixaeron caller in a dedicated pull request.

This two-stage sequence prevents a mutable branch from silently replacing the
script used by an already-reviewed Pixaeron workflow.

## Validation

`Validate CI repository` runs on pull requests and pushes to `main`. It:

- parses the workflow files through GitHub Actions;
- runs `bash -n` against the Pixaeron deployment script;
- invokes the composite action locally;
- verifies that the action returns an existing script path.

Application-specific behavior is verified by the Pixaeron caller because only
the application repository contains its Nx workspace, Compose file, manifest,
Dockerfiles, and tests.

## Adding Another Project

Add a separate reusable workflow and project directory:

```text
.github/workflows/another-project.yml
actions/another-project/deploy-service/
```

Do not change the Pixaeron workflow or action merely to make another project's
deployment fit. Extract a shared action only after both implementations have
demonstrably identical mechanics.

## Official GitHub References

- [Reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)
- [Cloudflare SPA routing](https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/)
- [Cloudflare external CI/CD](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/)
- [Reusable workflow behavior and permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [OIDC token permissions](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub Packages permissions](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions)
