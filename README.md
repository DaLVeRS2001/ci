# Central CI

This public repository contains reusable GitHub Actions workflows and
project-specific deployment actions. It contains execution mechanics, not
application source, runtime secrets, Compose models, or deployment manifests.

## Repository Layout

```text
.github/workflows/
  pixaeron.yml           reusable Pixaeron backend verify/deploy workflow
  pixaeron-frontend.yml  reusable Pixaeron frontend verification workflow
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
      apollo_graph_ref: ${{ vars.APOLLO_GRAPH_REF }}
    secrets:
      APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
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
6. runs Nx affected lint, test, build, e2e, and GraphQL schema-check targets;
7. builds affected deployable Dockerfiles on pull requests;
8. validates that every discovered subgraph has one manifest row before the single Gateway row, then returns affected deployment and GraphOS subgraph matrices;
9. runs a synchronous GraphOS check for every affected subgraph in a separate secret-bearing matrix job on trusted runs;
10. reports one stable `Backend verification gate` for branch protection and deployment dependencies.

Production rollout is split into two explicit jobs and runs only after
successful verification, outside pull requests, for `refs/heads/main`:

1. `build-images` builds every selected service in a matrix and pushes only the
   immutable `sha-<pixaeron-commit>` tag to GHCR. Production CI neither
   publishes nor deploys a mutable `latest` tag.
2. One `deploy-release` job starts only after the complete image matrix
   succeeds. It enters the caller's protected `production` environment,
   obtains temporary AWS credentials through GitHub OIDC, validates every
   manifest service's Parameter Store hierarchy before changing a container,
   stages all mode-0600 runtime env files, and then deploys only the selected
   services sequentially. After every remote health check succeeds, the same
   job publishes each affected subgraph SDL from the deployed commit with
   GraphOS checks enabled.

The application-owned deployment manifest provides a unique integer
`deploymentOrder`. The workflow sorts by that field before deployment. The
current manifest assigns Auth order 10 and Gateway order 100, so Gateway and
its static Router supergraph are replaced last. CI requires exactly one Gateway
row, exactly one manifest row for every discovered subgraph, and a lower order
for every subgraph. A push that affects a subgraph automatically adds Gateway
to the release selection even if the Nx dependency graph is incomplete.
When another service is added, its manifest row joins the image matrix and the
same ordered release without another copied deploy job.

`deploy-release` owns the single non-cancelling `pixaeron-production`
concurrency queue for both deployment and GraphOS publication. Once it acquires
the queue, its stale-main guard compares the workflow commit with the current
remote `main`; an older queued run exits without changing production. A manual
release of a GraphQL subgraph or Gateway must use `service=all`, because either
partial release could leave the static Gateway supergraph out of sync. Manual
releases of unrelated non-subgraph services may remain service-specific.

Before the first release step, CI uploads every validated runtime env. A missing
live env is bootstrapped from that staged copy so Compose can resolve the whole
project; an existing live env is not replaced until its service is selected for
deployment. For every selected release step, the remote script backs up live
deployment files, validates Compose, pulls the immutable image and dependencies,
runs an optional backward-compatible migration, and waits for health. On
failure it reports the failed phase before rollback and restores the prior
service image/configuration. If no prior image exists, rollback removes the failed
new service container. An `always()` final step attempts to remove staged
runtime env copies after successful, failed, or cancelled releases; cleanup
failures are warnings. Old labeled service images are pruned only after success.

Rollback is deliberately per service, not a distributed transaction. If Auth
is healthy and a later Gateway deployment fails, Auth remains on the new
version. Every cross-service change must therefore use expand/contract: deploy
a backward-compatible provider first, deploy its consumers afterward, and
remove the old contract only in a later release. This keeps rollback readable
without a custom cross-service rollback framework.

## Pixaeron Frontend Workflow

The frontend uses Cloudflare Workers Static Assets rather than a frontend Docker
image. Cloudflare recommends Workers Static Assets for new static sites and SPAs;
Pages remains supported but is no longer the preferred starting point. The reusable
workflow is deliberately Pixaeron-specific and does not introduce a speculative
shared frontend action.

The caller supplies public build values plus the non-secret GraphOS graph reference:

```text
APOLLO_GRAPH_REF=pixaeron@production
GRAPHQL_API_URL
GOOGLE_CLIENT_ID
TURNSTILE_SITE_KEY
```

Trusted runs use a dedicated `APOLLO_KEY` only to fetch the composed API schema
with Rover before `npm ci`. The workflow requires the committed frontend schema
snapshot to match GraphOS, then executes `npm run check` and a Wrangler dry run.
Fork and Dependabot pull requests cannot receive repository secrets, so they use
the committed snapshot while retaining the same non-writing `codegen:check` and build checks.
A trusted `main` run uploads the exact verified `build/` directory as a one-day
workflow artifact.
The frontend repository then owns a small local deploy job. That job downloads
the verified artifact and targets its protected `production` environment, where
`CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` are resolved.

This boundary is required by GitHub Actions: environment secrets cannot be
passed through `workflow_call`, and a caller job that uses a reusable workflow
cannot itself declare `environment`. Keeping the deployment job in the
application repository preserves environment approvals and avoids placing
project credentials in this central CI repository.

The Cloudflare token is exposed only to the local frontend job's final
`wrangler deploy` step. Production deployments use a non-cancelling concurrency
group. Preview deployment is intentionally not enabled until Pixaeron has a
non-production backend, stable preview Google OAuth origin, and preview
Turnstile hostname.

The frontend caller must reference this workflow by a full commit SHA. The
central workflow requires Node.js 24 and expects the caller repository to own
`wrangler.jsonc`, the exact Wrangler dependency, the Webpack build, and all
application tests.

## GraphOS Schema Registry

Rover is pinned to 0.41.0: checks use Apollo's official Action at an immutable
commit SHA, and release publication uses Apollo's official image at an immutable
digest. The backend workflow discovers GraphQL subgraphs from Nx application projects
that expose a `schema-check` target. Each discovered project must also expose
`schema-export`, use its Nx project name as the GraphOS subgraph name, and commit
its SDL at `<projectRoot>/schema.graphql`.

Trusted runs check every affected subgraph through one GitHub Actions matrix. The
Docker-based Rover check and publish steps set `APOLLO_CONFIG_HOME=/tmp/rover`
because their container user cannot write the GitHub-mounted default configuration
directory. A stable `Backend verification gate` aggregates local Nx verification
and the optional matrix so branch protection never depends on dynamic job names.
After its first successful caller run, add that exact gate to the caller repository's `main` ruleset; do not require individual matrix children.

After the complete ordered production release passes all remote health checks,
the same serialized release job publishes each affected subgraph's SDL from the
same commit with `--check` and `--no-url`. GraphOS then composes the latest
published SDL from every subgraph into one API schema. `no-url` remains
intentional because GraphOS is used for schema storage and checks, while the
Gateway image contains the statically composed executable supergraph and its
private subgraph routes.

Rover remains the standard path while a release changes one subgraph. Its
`--check` flow does not make several sequential subgraph publications one
atomic update. Production CI therefore rejects a release selecting more than
one subgraph SDL. Before Pixaeron needs a coordinated multi-subgraph release,
replace that loop with one official GraphOS Platform API `publishSubgraphs`
batch; do not copy more Rover jobs.

Trusted frontend runs fetch the composed API schema with `rover graph fetch`.
They never introspect individual services or copy a subgraph SDL. `APOLLO_KEY` is
scoped to the Rover step and is never exposed to npm lifecycle scripts, Webpack,
Docker builds, or application code.

Bootstrap in this order:

1. Create the graph in GraphOS Studio and choose the explicit `production` variant.
2. On a trusted Windows workstation, download Rover 0.41.0 through Apollo's official [installation guide](https://www.apollographql.com/docs/rover/getting-started).
   Use the binary-download option, add it to `PATH`, and authenticate Rover. `config auth` is interactive: paste the personal key at its prompt, not after the command.

```powershell
rover --version
rover config auth
rover config whoami
```

The local profile is for developer commands only. CI uses its repository
`APOLLO_KEY`; that environment variable overrides the local Rover profile.

3. Check out the exact clean backend commit intended as the registry baseline.
   From its repository root, verify the generated SDL before publishing:

```powershell
npm ci
npm run schema:check
rover subgraph publish pixaeron@production `
  --name auth `
  --schema .\apps\auth\schema.graphql `
  --no-url `
  --check
```

4. Confirm the result with read-only commands:

```powershell
rover subgraph list pixaeron@production
rover subgraph check pixaeron@production --name auth --schema .\apps\auth\schema.graphql
rover graph fetch pixaeron@production
```

Manual `subgraph publish` changes registry state and is only for bootstrap or
recovery. Routine publication belongs to the post-health-check CI step.

5. Create separate backend and frontend CI keys. On the current Free plan these
   are graph API keys with full graph access; separation still allows independent
   rotation and revocation. Standard/Enterprise can instead use one backend
   subgraph API key whose resources include every subgraph and variant handled by
   this workflow. Add each new backend subgraph to that key before enabling its CI
   target. Consumer/read-only graph-key roles require Enterprise.

6. Add repository variable `APOLLO_GRAPH_REF=pixaeron@production` and repository
   secret `APOLLO_KEY` to each caller repository.
7. Publish this central CI change and update the backend caller to its full SHA.
8. Dispatch backend service `all`. A manual release cannot target Auth or
   Gateway alone because both must use the same static schema set. CI checks the
   existing baseline, deploys the ordered release, and republishes the exact
   deployed schema only after every health check succeeds.
9. Pull the composed schema in frontend, commit the snapshot/generated client,
   then update the frontend caller to the same central SHA.

Without Router/Apollo telemetry, GraphOS still performs composition, build, and
lint checks, but operation-history checks do not have representative production
traffic. Do not enable asynchronous `--background` checks until the GraphOS
GitHub integration is configured.

## Permissions And Secrets

The caller job provides the maximum permission ceiling because a called
workflow can reduce permissions but cannot elevate them.

- `actions: read` supports workflow/Nx metadata reads.
- `contents: read` supports checkout.
- `id-token: write` allows only `deploy-release` to request a short-lived OIDC
  token; AWS IAM defines the real cloud permissions.
- `packages: write` allows only the `build-images` job to publish immutable
  Docker images to GHCR; `deploy-release` has read-only package access.

Application runtime secrets do not belong in this public repository.
`VPS_HOST`, `VPS_USER`, `VPS_SSH_PRIVATE_KEY`, and `VPS_KNOWN_HOSTS` remain in
the Pixaeron repository/environment. Runtime application values remain in AWS
Systems Manager Parameter Store.

Two different credentials deliberately use the environment name `APOLLO_KEY`:

- the backend and frontend caller repositories each keep a dedicated GitHub
  Actions secret for Rover schema checks, publication, or composed-schema fetch;
- Gateway keeps its separate Router runtime key as the SecureString
  `/pixaeron/production/gateway/APOLLO_KEY` in AWS Systems Manager Parameter
  Store. The ordered deploy reads it only into Gateway's runtime env file.

The Router runtime key is not the backend CI key and must not be copied into the
central workflow. `APOLLO_GRAPH_REF` remains non-secret configuration: callers
supply it as a repository variable, while Gateway receives its runtime value
through its own Parameter Store path. None of these values belongs in the
browser bundle.

The reusable backend `deploy-release` job declares `environment: production`;
its AWS and VPS deployment configuration follows the backend workflow contract. Frontend
Cloudflare deployment remains different: the frontend repository's local deploy
job declares `environment: production` and reads that repository's Cloudflare
environment secret directly.

## Release Activation Status

The runtime-env preflight and phase-aware rollback diagnostic in the current
working tree do not affect an existing release until both immutable central CI
pins are rolled forward.

Activate this change in this order:

1. validate, commit, and publish the `deploy-service` diagnostic change;
2. replace the deploy action SHA inside `pixaeron.yml` with that action commit,
   validate the runtime-env preflight, then commit and publish the workflow;
3. replace the backend caller's reusable-workflow SHA with the final workflow
   commit and verify a complete Pixaeron release.

The deploy action and reusable workflow are separate dependencies. Until step 2,
the workflow still resolves the previously pinned action. Until step 3, the
backend consumer cannot use either central change. A central CI merge by itself
never updates a consumer.

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

- lints workflow files with pinned actionlint 1.7.12;
- ignores only its known false positive for GitHub's newer official
  `concurrency.queue` key;
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

## Official references

- [Rover authentication](https://www.apollographql.com/docs/rover/configuring)
- [Rover subgraph commands](https://www.apollographql.com/docs/rover/commands/subgraphs)
- [Rover graph commands](https://www.apollographql.com/docs/rover/commands/graphs)
- [Publishing schemas to GraphOS](https://www.apollographql.com/docs/graphos/platform/schema-management/delivery/publishing)
- [GraphOS deployment best practices](https://www.apollographql.com/docs/graphos/platform/production-readiness/deployment-best-practices)
- [GitHub Actions concurrency queues](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)
- [GraphOS graph API keys](https://www.apollographql.com/docs/graphos/platform/access-management/api-keys/graph-api-keys)
- [GraphOS subgraph API keys](https://www.apollographql.com/docs/graphos/platform/access-management/api-keys/subgraph-api-keys)
- [Reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)
- [Cloudflare SPA routing](https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/)
- [Cloudflare external CI/CD](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/)
- [Reusable workflow behavior and permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [OIDC token permissions](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub Packages permissions](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions)
