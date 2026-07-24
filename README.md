# CI

Reusable GitHub Actions workflows and project-specific deployment actions.

## Pixaeron

- `.github/workflows/pixaeron.yml` contains the reusable CI/CD workflow.
- `actions/pixaeron/deploy-service` contains the versioned VPS deployment script.

Application repositories must call reusable workflows by a full commit SHA.
Project deployment manifests, Dockerfiles, and Compose files remain versioned
with the application that consumes them.
