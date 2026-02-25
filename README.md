# Notiolink Cron Jobs

Public repository for Notiolink's scheduled cron jobs.

## Overview

This repository contains GitHub Actions workflows that trigger scheduled maintenance tasks for the Notiolink application. All business logic, API endpoints, and sensitive operations remain in the private Notiolink repository.

## Cron Jobs

### 1. Operation Queue Drain

**Schedule**: Every 5 minutes (at 2, 7, 12, 17, ..., 57 minutes past the hour)

**Purpose**: Processes stalled operations in the queue to ensure reliable execution of background tasks.

**Endpoint**: `POST /api/internal/pipeline/operations/actions/drain`

**What it does**:
- Identifies operations that have been stalled for >45 seconds
- Processes up to 200 operations per run
- Scans up to 5000 operations within a 20-second time budget
- Returns before/after snapshots of the queue state
- Sends trace headers (`X-Cron-Source`, `X-Cron-Run-Id`, `X-Cron-Event`, `X-Cron-Chain-Depth`) with each drain request
- Uses `progressHint` when returned by the API, with fallback progress signals from response deltas (`processedEstimate`, backlog, stalled, never-dispatched)
- Guardedly self-dispatches a follow-up drain worker when backlog remains and progress was made
- Stops self-dispatch when backlog is empty, no progress is made, or chain depth reaches 24
- Uses workflow concurrency locking so overlapping drain workers on the same ref do not run in parallel

### 2. Cache Refresh

**Schedule**: Every 10 minutes (at 4, 14, 24, 34, 44, 54 minutes past the hour)

**Purpose**: Refreshes Supabase read models by syncing data from Notion databases.

**Endpoint**: `POST /api/internal/cache/refresh`

**What it does**:
- Fetches latest link and tree data from Notion
- Updates Supabase cache tables
- Ensures read models stay synchronized with source data

## Setup Instructions

### Required Secrets

Configure the following secrets in your GitHub repository settings:

1. **`STALLED_RUNNER_BASE_URL`** (Required)
   - The base URL of your Notiolink deployment
   - Example: `https://your-domain.com`
   - Used to construct the full endpoint URLs for cron jobs

2. **`CRON_SECRET`** (Required)
   - A secure, randomly-generated token for authenticating cron requests
   - Must match the `CRON_SECRET` environment variable in your deployment
   - Example generation: `openssl rand -hex 32`
   - This secret is validated by the API endpoints before processing requests

### Configuring Secrets

1. Navigate to your GitHub repository
2. Go to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Add both `STALLED_RUNNER_BASE_URL` and `CRON_SECRET`
5. Save the secrets

### Manual Execution

Both workflows support manual triggering for testing:

1. Go to the **Actions** tab in your GitHub repository
2. Select the workflow you want to run
3. Click **Run workflow**
4. Choose the branch (if applicable)
5. Click **Run workflow**

For **Operation Queue Drain**, optional manual `workflow_dispatch` inputs are available:
- `chain_depth` (default: `0`)
- `chain_origin` (default: `manual`)

These inputs are primarily for continuity testing/debugging; normal manual runs can use defaults.

## Security

### What's Public

- Workflow configuration files (YAML)
- This documentation
- Execution logs (excluding secrets)

### What Remains Private

All sensitive code stays in the private Notiolink repository:
- ✅ API endpoint implementations
- ✅ Database operations and schema
- ✅ Business logic and algorithms
- ✅ Authentication and authorization logic
- ✅ Notion integration code
- ✅ Supabase connection details

### Security Measures

1. **Bearer Token Authentication**: All cron endpoints require a valid `CRON_SECRET` in the `Authorization` header
2. **Secret Masking**: GitHub Actions automatically masks secrets in logs
3. **Timeout Protection**: Each workflow has a 15-minute timeout to prevent runaway executions
4. **HTTP Validation**: Endpoints validate request methods and reject unauthorized access

## Monitoring

### Checking Workflow Status

1. Go to the **Actions** tab to view recent runs
2. Click on a workflow run to see detailed logs
3. Check the output for status codes and response data

### Expected Response Codes

- **200 OK**: Cron job executed successfully
- **4xx Client Error**: Check your secret configuration
- **5xx Server Error**: Check your deployment logs

### Troubleshooting

**Workflow fails with "Missing required GitHub secret"**
- Verify secrets are configured in repository settings
- Ensure secret names match exactly (case-sensitive)

**Endpoint returns 401 Unauthorized**
- Verify `CRON_SECRET` matches between GitHub and your deployment
- Check that the secret is properly formatted (no extra whitespace)

**Endpoint returns 5xx errors**
- Check your deployment logs for application errors
- Verify your deployment is healthy and accessible
- Ensure the `STALLED_RUNNER_BASE_URL` is correct

## Architecture

```
┌─────────────────────┐      ┌──────────────────────┐      ┌─────────────────┐
│  GitHub Actions     │      │  Notiolink           │      │  Notion API     │
│  (Public Repo)      │─────▶│  Deployment          │─────▶│                 │
│                     │      │  (Private)           │      │                 │
│  - Cron Schedule    │      │                      │      │                 │
│  - HTTP Request     │      │  - Auth Validation   │      │  - Link Data    │
│  - Secret Mgmt      │      │  - Business Logic    │      │  - Tree Data    │
└─────────────────────┘      └──────────────────────┘      └─────────────────┘
         │                            │
         │                            ▼
         │                     ┌──────────────────┐
         │                     │  Supabase        │
         │                     │  (Cache Tables)  │
         │                     └──────────────────┘
         │
         ▼
┌─────────────────────┐
│  GitHub Secrets     │
│                     │
│  - CRON_SECRET      │
│  - BASE_URL         │
└─────────────────────┘
```

## License

This repository is part of the Notiolink project. All rights reserved.

## Support

For issues or questions, please refer to the private Notiolink repository documentation or contact the development team.
