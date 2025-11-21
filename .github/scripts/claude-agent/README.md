# Claude Code Agent - Kubernetes Analysis

Automated code analysis agent powered by Claude Code that runs on every commit and has access to your Kubernetes cluster via Tailscale.

## Features

- **Automated Code Review**: Analyzes code for bugs, security vulnerabilities, and quality issues on every commit
- **Kubernetes Integration**: Custom MCP tools for kubectl access to check cluster health
- **Secure Network Access**: Connects via Tailscale using workload identity federation (no long-lived secrets)
- **PR Integration**: Posts analysis results as PR comments
- **Comprehensive Analysis**: Scans code, manifests, and cluster status

## Architecture

```
GitHub Actions (OIDC)
    ↓
Tailscale Token Exchange
    ↓
Tailscale Network
    ↓
    ├─→ Code Repository (file analysis)
    └─→ Kubernetes Cluster (kubectl via Tailscale)
         ↓
    Claude Code Agent
         ↓
    Analysis Results → PR Comments
```

## Setup

### 1. Required GitHub Secrets

Configure these secrets in your GitHub repository settings:

- `TS_OAUTH_CLIENT_ID` - Your Tailscale OAuth client ID
- `TS_OAUTH_SECRET` - Your Tailscale OAuth client secret
- `LLM_PROXY_API_KEY` - API key for your LLM proxy (http://llm-proxy.keiretsu.ts.net)

### 2. Tailscale Configuration

1. Create OAuth client with `auth_keys` scope
2. Configure ACLs to allow `tag:ci` and `tag:claude-agent`
3. Ensure Kubernetes operator is running with API server proxy enabled
4. Set up workload identity federation (OIDC)

### 3. Kubernetes Setup

Ensure you have:
- Tailscale Kubernetes operator installed
- API server proxy configured: `tailscale-operator` or `ottawa-k8s-operator.keiretsu.ts.net`
- Proper RBAC permissions for the CI service account

## Usage

### Automatic Triggers

The workflow runs automatically on:
- Push to `main` branch
- Pull request opened or updated

### Manual Trigger

Run manually via GitHub Actions UI with workflow_dispatch:
```bash
gh workflow run claude-code-analysis.yml
```

### Local Testing

Install dependencies:
```bash
cd .github/scripts/claude-agent
npm install
```

Set environment variables:
```bash
export ANTHROPIC_BASE_URL=http://llm-proxy.keiretsu.ts.net
export ANTHROPIC_AUTH_TOKEN=your-token
export API_TIMEOUT_MS=3000000
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

Connect to Kubernetes:
```bash
tailscale configure kubeconfig ottawa-k8s-operator.keiretsu.ts.net
```

Run analysis:
```bash
node analyze.js
```

## Configuration

Configuration is via environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `ANTHROPIC_BASE_URL` | LLM proxy endpoint | `http://llm-proxy.keiretsu.ts.net` |
| `ANTHROPIC_AUTH_TOKEN` | API authentication token | Required |
| `API_TIMEOUT_MS` | API request timeout | `3000000` (50 min) |
| `CLAUDE_MODEL` | Claude model to use | `claude-sonnet-4-5` |

## Custom MCP Tools

The agent includes custom Kubernetes tools:

### kubectl_get
Query Kubernetes resources (pods, services, deployments, nodes, etc.)

```javascript
{
  resource_type: 'pods',
  namespace: 'default',
  output_format: 'json',
  all_namespaces: false
}
```

### kubectl_logs
Get logs from a Kubernetes pod

```javascript
{
  pod_name: 'my-pod',
  namespace: 'default',
  container: 'app',  // optional
  tail: 100
}
```

### kubectl_describe
Get detailed resource information

```javascript
{
  resource_type: 'pod',
  resource_name: 'my-pod',
  namespace: 'default'
}
```

### kubectl_events
Get recent cluster events

```javascript
{
  namespace: 'default',
  all_namespaces: true
}
```

## Output Format

The agent produces a JSON file (`analysis-results.json`):

```json
{
  "bugs": [
    {
      "file": "path/to/file.yaml",
      "line": "42",
      "description": "Issue description",
      "severity": "high",
      "recommendation": "How to fix"
    }
  ],
  "summary": "Brief overview of findings",
  "recommendations": ["Recommendation 1", "Recommendation 2"],
  "k8s_status": {
    "nodes": "3 healthy nodes",
    "pods": "45 running, 2 failed",
    "issues": ["Issue found in cluster"]
  },
  "metadata": {
    "timestamp": "2025-01-20T00:00:00.000Z",
    "repository": "/path/to/repo",
    "agent_version": "1.0.0"
  }
}
```

## Security Considerations

- **No Long-Lived Secrets**: Uses OIDC workload identity federation
- **Least Privilege**: Agent only has read access to cluster
- **Network Isolation**: All communication over private Tailscale network
- **Ephemeral Nodes**: GitHub Action runners create temporary Tailscale nodes
- **Read-Only Analysis**: Agent does not modify code or cluster resources

## Troubleshooting

### Connection Issues

Check Tailscale connectivity:
```bash
kubectl cluster-info
tailscale status
```

### Analysis Failures

Check agent logs in GitHub Actions:
```bash
gh run view --log
```

Test locally with verbose output:
```bash
NODE_DEBUG=* node analyze.js
```

### Kubernetes Access

Verify kubectl configuration:
```bash
kubectl get nodes
kubectl get pods -A
```

Check Tailscale kubeconfig:
```bash
cat ~/.kube/config
```

## Development

### Adding New Tools

Create a new tool in `analyze.js`:

```javascript
const myToolSchema = z.object({
  param1: z.string(),
  param2: z.number().optional()
});

const myTool = tool(
  'tool_name',
  'Tool description',
  myToolSchema,
  async (args) => {
    // Implementation
    return { success: true, result: 'data' };
  }
);

server.addTool(myTool);
```

### Modifying Analysis Prompt

Edit the `analysisPrompt` in `analyzeRepository()` function to customize what the agent looks for.

### Adjusting Workflow

Modify `.github/workflows/claude-code-analysis.yml` to:
- Change trigger conditions
- Add additional steps
- Customize PR comment format
- Adjust failure conditions

## License

Same as parent repository.
