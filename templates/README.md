# Podbox GitOps Templates

This directory contains standardized templates for deploying containerized applications to the Podbox infrastructure using a github actions workflow.

## Overview

The Podbox deployment architecture is designed for **Intentional Deployments**. Instead of deploying every single commit, the pipeline requires an explicit version bump in the application's `package.json` to trigger a rollout to the cluster.

### Included Templates

| File | Purpose |
| :--- | :--- |
| `staging.yaml.template` | Kubernetes manifest for the Staging environment (`staging.yourdomain.com`). |
| `prod.yaml.template` | Kubernetes manifest for the Production environment (`yourdomain.com`). |
| `github-action.yml.template` | GitHub Actions workflow that handles building, tagging, and manifest updates. |

---

## Getting Started

### 1. Copy the Templates
Copy the template files into your project repository:
- Manifests go into: `k8s/`
- Workflow goes into: `.github/workflows/`

### 2. Replace Placeholders
Search and replace the following placeholders across all three files:

- `__APP_NAME__`: The name of your application folder (e.g., `blog-service`).
- `__APP_NAME_UPPER__`: The uppercase version of your app name for env vars (e.g., `BLOG_SERVICE`).
- `__NAMESPACE__`: The Kubernetes namespace for the app (usually the repo name).
- `__DOMAIN__`: Your root domain (e.g., `jesseweed.io`).
- `__GITHUB_USER__`: Your GitHub username for the container registry.

### 3. Configure Portainer
1. **Create the Staging/Prod Apps**: In Portainer, create new applications from the `Repository` build method pointing to your new `.yaml` files.
2. **Enable Webhooks**: Enable GitOps updates via Webhook in Portainer and copy the generated URLs.

### 4. Setup GitHub Secrets
Add the Portainer Webhook URLs to your GitHub Repository Secrets:
- `PORTAINER_WEBHOOK_URL___APP_NAME_UPPER___STAGING`
- `PORTAINER_WEBHOOK_URL___APP_NAME_UPPER___PROD`

---

## Deployment Workflow

1. **Local Development**: Run your app locally using `bun dev`.
2. **Feature Branches**: Push code to `develop` to verify the build.
3. **Intentional Release**: 
   - When ready to deploy, increment the `version` in `apps/__APP_NAME__/package.json`.
   - Push to `develop` (Staging) or `main` (Production).
   - The GitHub Action will detect the version change, update the image tag in the YAML, and trigger the Portainer rollout.
