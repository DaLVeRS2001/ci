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
  gitleaks.yml           secret scan over this repository's full history

actions/pixaeron/deploy-service/
  action.yml         exposes the versioned script path to a workflow job
  deploy-service.sh  remote per-service deployment and rollback implementation

actions/pixaeron/scripts/
  action.yml               exposes the versioned pipeline script directory
  validate-manifest.sh     deployment manifest validation
  validate-compose.sh      rendered Compose validation
  build-deploy-matrix.sh   deployment/GraphOS matrices and the selection summary
  prepare-runtime-envs.sh  Parameter Store reads, masking, staged runtime envs
  deploy-ordered.sh        one Compose install per release, then the service loop
```

There is intentionally no anticipated `actions/shared` abstraction. Shared
actions should be added only after another project has real duplicate
mechanics.

This repository carries `.gitattributes` with `* text=auto eol=lf` plus explicit
shell and workflow entries, so a Windows workstation cannot commit CRLF into a
script that runs on a Linux runner.

## Pixaeron Ownership Boundary

The Pixaeron application repository owns files that must change atomically with
application code:

```text
.github/workflows/ci.yml       event triggers and caller permission ceiling
.github/deploy-services.json   deployable Nx project metadata
docker-compose.production.yaml application-host runtime model
docker-compose.worker.yaml     worker-host runtime model
apps/*/Dockerfile              service image definitions
```

This repository owns:

```text
.github/workflows/pixaeron.yml
.github/workflows/gitleaks.yml
actions/pixaeron/deploy-service/action.yml
actions/pixaeron/deploy-service/deploy-service.sh
actions/pixaeron/scripts/action.yml
actions/pixaeron/scripts/*.sh
```

The reusable workflow runs in the caller repository context. Its
`actions/checkout` steps therefore check out Pixaeron, not this repository.
A reusable workflow does not check out its own repository, so nothing under
`actions/` is reachable from `pixaeron.yml` by path. Both composite actions are
referenced separately by a full commit SHA, which is what makes GitHub download
the action and its co-located shell scripts from this repository. This is the
reason the extracted pipeline scripts live behind an action rather than in a
plain directory.

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

1. starts isolated PostgreSQL 18 and Redis 8 service containers, then creates
   the separate Notifications database and role inside the CI PostgreSQL service;
2. checks out the complete Pixaeron history;
3. validates `.github/deploy-services.json`, including unique deployment and
   image identifiers, safe environment-key fields, and Dockerfiles inside the repository;
4. renders and validates one Compose file per deployment host — the manifest's
   `host` field routes each service to `application` or `worker` — including the
   exact manifest image assigned to every service;
5. installs Node.js 24 dependencies with `npm ci`;
6. on pull requests and pushes, checks protobuf compatibility and runs affected
   lint, test, build, e2e, GraphQL schema, and database-integration targets. A
   manual run checks a non-`main` branch's protobuf contract against
   `origin/main`, runs lint, test, and e2e across the whole Nx workspace, then
   runs build, GraphQL schema, and database-integration checks only for the
   selected deployable projects. On `main`, it does not compare the checked-out
   commit with itself as a contract baseline;
7. builds affected deployable Dockerfiles on pull requests. Gateway's Nx build
   already builds its Dockerfile, so the separate smoke loop does not build it a
   second time. The Notifications image runs a container-level smoke test against
   a fresh PostgreSQL 18 database,
   exercises the real gRPC wire contract on the private command network, proves
   that the command alias is unreachable from the egress network, and verifies
   that a failed database bootstrap terminates the process;
8. validates that every discovered subgraph has one manifest row before the single
   Gateway row, and, when Notifications is present, verifies its private Compose
   topology, command-network-only gRPC bind, deployment order, runtime endpoint,
   and absence of host ports; it then
   returns affected deployment and GraphOS subgraph matrices;
9. runs a synchronous GraphOS check for every affected subgraph in a separate secret-bearing matrix job on trusted runs;
10. reports one stable `Backend verification gate` for branch protection and deployment dependencies.

Production rollout is split into three explicit jobs and runs only after
successful verification, outside pull requests, for `refs/heads/main`:

1. `build-images` builds every selected service in a matrix and pushes only the
   immutable `sha-<pixaeron-commit>` tag to GHCR. Production CI neither
   publishes nor deploys a mutable `latest` tag. Missing image-tag variables
   resolve to the deliberately nonexistent `sha-not-configured` fallback, so a
   manual production Compose run fails closed instead of pulling an unrelated image.
2. One `deploy-release` job starts only after the complete image matrix
   succeeds. It enters the caller's protected `production` environment,
   validates the required production configuration, obtains temporary AWS
   credentials through GitHub OIDC, and validates every manifest service's
   Parameter Store hierarchy before changing a container,
   stages all mode-0600 runtime env files, and then deploys only the selected
   services sequentially. After every remote health check succeeds, the same
   job publishes each affected subgraph SDL from the deployed commit with
   GraphOS checks enabled.
3. `release-outcome` closes the loop on manual runs. `build-deploy-matrix.sh`
   writes the deployment selection to the step summary, `deploy-release`
   exposes a `released` output, and this job turns a `workflow_dispatch`
   release on `main` that deployed nothing into a RED run instead of a
   misleading green one. On any other ref it explains that the dispatch was
   verification-only. It is scoped to `workflow_dispatch`, so pull requests and
   pushes to `main` are untouched.

An explicit release dispatch that changes nothing is a contradiction, not a
success. The guard exists because a green run is the only signal an operator
reads before assuming production carries the new commit.

### Skipped Jobs Propagate, And The Gate Does Not Stop Them

Every job downstream of `graphos-check` must begin its `if` with
`!cancelled() &&`. This is not defensive noise; it repairs a real production
defect that the `release-outcome` guard caught on its first run.

`notifications` is not a GraphOS subgraph. A release that selects only
Notifications therefore leaves `selected_subgraphs` empty,
`graphos_check_required` false and `graphos-check` SKIPPED. When a job declares
an `if` without a status check function, GitHub inserts an implicit `success()`,
and a skipped ancestor makes that expression false. The skip then travels
transitively down the chain: `build-images` and `deploy-release` were skipped
too, and the run finished GREEN having deployed nothing. `verification-gate` did
not stop it, because its own `always()` rescues only itself and says nothing
about the jobs that depend on it. This is actions/runner#2205, open since 2022.

Two earlier diagnoses were wrong and are recorded here so they are not retried.
It was not an empty deployment matrix: `service=notifications` selects exactly
one row. It was not specific to `workflow_dispatch` either: a push to `main`
touching only non-subgraph services skipped its release the same way and stayed
green.

### Ordered Release And Rollback

The application-owned deployment manifest provides a unique integer
`deploymentOrder`. The workflow sorts by that field before deployment. The
current manifest assigns Notifications order 5, Auth order 10, and Gateway
order 100. Notifications is therefore made healthy before Auth, while Gateway
and its static Router supergraph are replaced last. CI requires exactly one Gateway
row, exactly one manifest row for every discovered subgraph, and a lower order
for every subgraph. When Notifications is present, CI also requires exactly one
Auth row and fails unless Notifications has the lower deployment order. A push that affects a subgraph automatically adds Gateway
to the release selection even if the Nx dependency graph is incomplete.
Notifications is not a GraphQL subgraph, so it participates in image,
runtime-env, migration, and ordered deployment matrices without entering the
GraphOS matrix.
When another service is added, its manifest row joins the image matrix and the
same ordered release without another copied deploy job.

`deploy-release` owns the single non-cancelling `pixaeron-production`
concurrency queue for both deployment and GraphOS publication. Once it acquires
the queue, its stale-main guard compares the workflow commit with the current
remote `main`; an older queued run exits without changing production and writes
an explicit notice and job summary. A manual release of a GraphQL subgraph or
Gateway must use `service=all`, because either
partial release could leave the static Gateway supergraph out of sync. Manual
releases of unrelated non-subgraph services may remain service-specific.

Before the first release step, CI uploads every validated runtime env. A missing
live env is bootstrapped from that staged copy so Compose can resolve the whole
project; an existing live env is not replaced until its service is selected for
deployment.

A Compose file is a whole-host artifact, not a per-service one, so each host's
file is installed ONCE per release before the service loop. `deploy-ordered.sh`
copies it to every host this release touches, keeps exactly one
`<compose-file>.release-rollback` baseline per host, iterates the ordered
services across hosts, and discards the baselines after the last service
succeeds. A `failure()` step at release level restores them. Restoring
the stack file per service was the earlier defect: a mid-release failure could
restore a baseline that no longer matched the services already deployed.
Because the baseline is now release-scoped, a failed release leaves the
pre-release Compose file on disk, and rerunning the same commit behaves like a
first run rather than resuming from a half-installed model.

`deploy-service.sh` therefore no longer touches the Compose file at all. For
every selected release step it backs up only the live env files, validates the
Compose service definition, pulls the immutable image and dependencies, runs an
optional backward-compatible migration, and waits for health. On failure it
reports the failed phase before rollback and restores the prior service
image/configuration, restarting the service with `--no-deps` so a rollback
cannot re-resolve dependencies against a stack that is mid-release. If no prior
image exists, rollback removes the failed new service container. An `always()`
final step attempts to remove staged runtime env copies after successful,
failed, or cancelled releases; cleanup failures are warnings. Old labeled
service images are pruned only after success.

Rollback is deliberately per service, not a distributed transaction. If
Notifications and Auth are healthy and a later Gateway deployment fails, those
services remain on the new version. Every cross-service change must therefore use expand/contract: deploy
a backward-compatible provider first, deploy its consumers afterward, and
remove the old contract only in a later release. This keeps rollback readable
without a custom cross-service rollback framework.

## Pipeline Scripts

Five run blocks moved out of `pixaeron.yml` into `actions/pixaeron/scripts/`,
taking the workflow from 1046 to 638 lines: `validate-manifest.sh`,
`validate-compose.sh`, `build-deploy-matrix.sh`, `prepare-runtime-envs.sh`,
`deploy-ordered.sh`, `cleanup-release-staging.sh`, and the shared
`deployment-hosts.sh`, roughly 500 lines of bash in total. Blocks of 23 lines or
fewer deliberately stayed inline, because extracting one of those trades a
single YAML line for three lines of script plumbing.

Two consequences of the move are easy to get wrong.

Linting had to be replaced, not inherited. actionlint runs shellcheck only over
`run:` blocks, so moving that bash into files would have silently removed
static analysis from every extracted line. `validate.yml` therefore runs
shellcheck directly over every `*.sh` under `actions/`. Before this change even
`deploy-service.sh` was only checked with `bash -n`, which catches syntax
errors and nothing else.

Editing any script now needs a two-step repin, because the action pin and the
workflow pin are independent immutable dependencies and both must be rolled
forward. The ordered procedure is under `Release Activation` below and is not
repeated here; what matters at this point is what each half-done attempt leaves
behind.

Commit the script and stop, and the workflow still resolves the previously
pinned copy of the action, so the change appears to have had no effect. Repin
the action inside `pixaeron.yml` and stop, and this repository is correct while
the backend caller still runs the older workflow. Neither failure is visible in
a green run, because both pins still resolve to valid, older code; only reading
the pinned SHAs reveals which code actually ran.

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

The gate runs under `always()`, which guarantees that the gate itself reports a
result when `graphos-check` is skipped. It guarantees nothing about the jobs
that list the gate in `needs`: `always()` rescues only the job it is written on.
Every downstream job must carry its own status check function, which is why
`build-images` and `deploy-release` start with `!cancelled() &&`.

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

The application deployment manifest declares the SSM paths that CI reads, but
it does not provision AWS IAM. Before activating a manifest path, extend the
caller's deployment role with `ssm:GetParametersByPath` for that exact path.
The runtime preflight fails closed before deployment when the role is missing
that permission. The Notifications manifest reads
`/pixaeron/production/notifications`, requires its database URL, recipient HMAC
key, and dedicated AWS runtime credentials to be `SecureString`, and writes them
only to the mode-0600 Notifications runtime env file. Its database-integration
target runs against a distinct PostgreSQL database; it never reuses Auth schema
or migrations.

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

## Public Repositories And Log Exposure

All three Pixaeron repositories are public and always have been. The
consequence that matters here is that their Actions logs are public too: anyone
can read every line a workflow prints, in this repository and in both consumers.

`prepare-runtime-envs.sh` therefore emits `::add-mask::` for every SecureString
value it reads from Parameter Store, before that value can reach any later step.
The CI-generated `JWT_PRIVATE_KEY_BASE64` was already masked. Masking is a last
line of defence, not a licence to print secrets: a value that is never echoed
cannot be unmasked by a formatting accident either.

Deploy logs published before that change expose the Lightsail database hostname.
That is not a credential on its own, the instance is not publicly reachable, and
the database password has since been rotated.

Gitleaks over the full history of all three repositories found two hits, both
the same dead value: a placeholder-shaped `JWT_SECRET` in the backend
`.env.example` at two 2026-07-07 commits, from before any production
infrastructure existed. It was never live, the Auth schema no longer accepts
`JWT_SECRET` at all, and the stale Parameter Store entry has been deleted. Both
hits are suppressed by fingerprint in the backend `.gitleaksignore`. The
frontend and this repository are clean.

Suppress by fingerprint, never by path or rule: a path-wide exclusion would also
hide the next real leak in that file.

## Release Activation

A change to anything under `actions/` does not affect an existing release until
both immutable pins are rolled forward. This is the standing rule for every such
change, not a status note about one of them.

Activate any action change in this order:

1. validate, commit, and publish the action change itself;
2. replace that action's SHA inside `pixaeron.yml`, validate, then commit and
   publish the workflow;
3. replace the backend caller's reusable-workflow SHA with the final workflow
   commit and verify a complete Pixaeron release.

The actions and the reusable workflow are separate dependencies. Until step 2,
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

### Action update

This applies to both `actions/pixaeron/deploy-service` and
`actions/pixaeron/scripts`. The actions and the reusable workflow use separate
immutable pins, so follow the three ordered steps under `Release Activation`
above, taking the action's commit SHA at step 1 and the resulting workflow
commit SHA at step 2, and land the caller bump in its own pull request.

This two-stage sequence prevents a mutable branch from silently replacing the
scripts used by an already-reviewed Pixaeron workflow. A one-line fix to a
pipeline script is therefore never a one-commit change.

## Validation

`Validate CI repository` runs on pull requests and pushes to `main`. It:

- lints workflow files with pinned actionlint 1.7.12;
- runs `bash -n` against every `*.sh` under `actions/`;
- runs shellcheck directly over every `*.sh` under `actions/`;
- invokes both composite actions locally;
- verifies that they return an existing deployment script path and a scripts
  directory containing all five pipeline scripts.

The direct shellcheck step is not redundant with actionlint. actionlint only
reaches shell that is written inline in a `run:` block, so a script file is
invisible to it.

`Secret scan` runs separately, on every push and pull request, executing
gitleaks pinned by image digest over the full history. This repository is clean.

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

## Official References

- [Rover authentication](https://www.apollographql.com/docs/rover/configuring)
- [Rover subgraph commands](https://www.apollographql.com/docs/rover/commands/subgraphs)
- [Rover graph commands](https://www.apollographql.com/docs/rover/commands/graphs)
- [Publishing schemas to GraphOS](https://www.apollographql.com/docs/graphos/platform/schema-management/delivery/publishing)
- [GraphOS deployment best practices](https://www.apollographql.com/docs/graphos/platform/production-readiness/deployment-best-practices)
- [GitHub Actions concurrency queues](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)
- [Job status check functions](https://docs.github.com/en/actions/reference/workflows-and-actions/expressions#status-check-functions)
- [Skipped dependent jobs, actions/runner#2205](https://github.com/actions/runner/issues/2205)
- [GraphOS graph API keys](https://www.apollographql.com/docs/graphos/platform/access-management/api-keys/graph-api-keys)
- [GraphOS subgraph API keys](https://www.apollographql.com/docs/graphos/platform/access-management/api-keys/subgraph-api-keys)
- [Reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)
- [Cloudflare SPA routing](https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/)
- [Cloudflare external CI/CD](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/)
- [Reusable workflow behavior and permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [OIDC token permissions](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub Packages permissions](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions)
