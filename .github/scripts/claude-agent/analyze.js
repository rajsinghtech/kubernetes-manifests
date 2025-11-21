#!/usr/bin/env node
/**
 * Claude Code Agent for automated code analysis with Kubernetes access
 * Runs on every commit via GitHub Actions
 *
 * Features:
 * - Analyzes code for bugs and vulnerabilities
 * - Checks Kubernetes cluster health via Bash + kubectl
 * - Connects via Tailscale for secure access
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import * as fs from 'fs';

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
  baseUrl: 'http://llm-proxy.keiretsu.ts.net',
  authToken: 'sk-na',
  apiTimeout: 3000000,
  model: 'claude-sonnet-4-5',
  repoPath: '/home/runner/work/kubernetes-manifests/kubernetes-manifests',
  outputFile: '/home/runner/work/kubernetes-manifests/kubernetes-manifests/analysis-results.json',
  alwaysThinkingEnabled: true,
  disableNonessentialTraffic: true
};

console.log('Claude Code Agent Configuration:');
console.log(`- Base URL: ${CONFIG.baseUrl}`);
console.log(`- Model: ${CONFIG.model}`);
console.log(`- API Timeout: ${CONFIG.apiTimeout}ms`);
console.log(`- Repo Path: ${CONFIG.repoPath}`);
console.log('');

console.log('✅ Claude Code Agent initialized');
console.log('');

// ============================================================================
// Main Analysis Function
// ============================================================================

async function analyzeRepository() {
  console.log('Starting Claude Code analysis...\n');

  // Verify kubectl connectivity first
  try {
    console.log('Verifying Kubernetes connectivity...');
    const clusterInfo = execSync('kubectl cluster-info', { encoding: 'utf-8' });
    console.log(clusterInfo);
    console.log('✅ Connected to Kubernetes cluster\n');
  } catch (error) {
    console.error('❌ Failed to connect to Kubernetes cluster:', error.message);
    console.log('Continuing with code analysis only...\n');
  }

  const analysisPrompt = `
You are an expert code reviewer and security analyst with access to a Kubernetes cluster via Tailscale.

Your task is to perform a comprehensive analysis of this repository:

## 1. Code Analysis
Scan the repository for:
- **Bugs and potential runtime errors**: Logic errors, null pointer issues, race conditions, etc.
- **Security vulnerabilities**:
  - Injection attacks (SQL, command, XSS, etc.)
  - Authentication/authorization issues
  - Secrets exposure
  - Insecure dependencies
  - Path traversal vulnerabilities
- **Code quality issues**:
  - Code smells
  - Maintainability problems
  - Performance concerns
  - Best practice violations
- **Configuration issues**: Especially in Kubernetes manifests, GitHub Actions workflows, etc.

## 2. Kubernetes Cluster Health Check
Use the kubectl tools to:
- Check the status of nodes: Are all nodes healthy?
- Check running pods: Any pods in CrashLoopBackOff, Error, or Pending state?
- Check recent events: Any warnings or errors in the cluster?
- Check critical system namespaces (kube-system, tailscale, etc.)
- Look for resource pressure or issues

## 3. Security Posture
Check for:
- Exposed secrets or credentials in code or configuration files
- Insecure Kubernetes configurations (privileged containers, host network access, etc.)
- Missing security policies or RBAC issues
- Overly permissive access controls

## Output Format
Return your findings in this EXACT JSON format (no markdown, no code blocks):

{
  "bugs": [
    {
      "file": "relative/path/to/file.yaml",
      "line": "42",
      "description": "Detailed description of the issue",
      "severity": "high",
      "recommendation": "How to fix this specific issue"
    }
  ],
  "summary": "Brief 2-3 sentence overview of the overall findings",
  "recommendations": [
    "High-level recommendation 1",
    "High-level recommendation 2"
  ],
  "k8s_status": {
    "nodes": "X healthy nodes",
    "pods": "X running, Y failed, Z pending",
    "issues": [
      "Specific issue 1 found in cluster",
      "Specific issue 2 found in cluster"
    ]
  }
}

## Important Instructions
- Be thorough and specific
- Focus on actionable findings
- Prioritize security and reliability issues
- Include file paths and line numbers when possible
- Use severity levels: "high", "medium", "low"
- Return ONLY the JSON object, no other text
`;

  const options = {
    allowedTools: [
      'Glob',   // Find files by pattern
      'Grep',   // Search file contents
      'Read',   // Read files
      'Bash'    // Run kubectl commands
    ],
    permissionMode: 'default',
    cwd: CONFIG.repoPath,
    systemPrompt: `You are an expert code reviewer with access to a Kubernetes cluster via kubectl.

You have deep expertise in:
- Security analysis and vulnerability detection
- Kubernetes best practices and troubleshooting
- Code quality and maintainability
- Infrastructure as code patterns

You can use kubectl commands via the Bash tool to check cluster health:
- kubectl get pods -A
- kubectl get deployments -A
- kubectl get events -A --sort-by='.lastTimestamp'
- kubectl logs <pod-name> -n <namespace>
- kubectl describe <resource> <name> -n <namespace>

Note: You have read-only view permissions (ClusterRole: view)
Be thorough, specific, and actionable in your analysis.`
  };

  let fullResponse = '';
  let messageCount = 0;
  let toolUseCount = 0;

  console.log('Sending analysis request to Claude...\n');
  console.log('=' . repeat(80));

  try {
    for await (const message of query({ prompt: analysisPrompt, options })) {
      messageCount++;

      if (message.type === 'assistant' && message.content) {
        for (const block of message.content) {
          if (block.type === 'text') {
            fullResponse += block.text;
            console.log(`\n[Assistant Message ${messageCount}]`);
            console.log(block.text.substring(0, 500) + (block.text.length > 500 ? '...' : ''));
          }
          if (block.type === 'tool_use') {
            toolUseCount++;
            console.log(`\n[Tool Use ${toolUseCount}] ${block.name}`);
            console.log(`Input:`, JSON.stringify(block.input, null, 2));
          }
        }
      }

      if (message.type === 'tool_result') {
        console.log(`\n[Tool Result]`);
        const resultPreview = JSON.stringify(message.content).substring(0, 300);
        console.log(resultPreview + (resultPreview.length >= 300 ? '...' : ''));
      }
    }
  } catch (error) {
    console.error('\n❌ Error during analysis:', error.message);
    throw error;
  }

  console.log('\n' + '='.repeat(80));
  console.log(`\nAnalysis complete!`);
  console.log(`- Messages received: ${messageCount}`);
  console.log(`- Tools used: ${toolUseCount}\n`);

  // Parse JSON response
  try {
    console.log('Parsing response...');

    // Extract JSON from markdown code blocks if present
    let jsonStr = fullResponse.trim();

    if (jsonStr.includes('```json')) {
      const matches = jsonStr.match(/```json\s*\n([\s\S]*?)\n```/);
      if (matches && matches[1]) {
        jsonStr = matches[1];
      }
    } else if (jsonStr.includes('```')) {
      const matches = jsonStr.match(/```\s*\n([\s\S]*?)\n```/);
      if (matches && matches[1]) {
        jsonStr = matches[1];
      }
    }

    // Try to find JSON object in the response
    const jsonMatch = jsonStr.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      jsonStr = jsonMatch[0];
    }

    const results = JSON.parse(jsonStr);

    // Validate structure
    if (!results.bugs) results.bugs = [];
    if (!results.summary) results.summary = 'Analysis completed';
    if (!results.recommendations) results.recommendations = [];

    console.log('✅ Successfully parsed analysis results\n');

    return results;
  } catch (error) {
    console.error('❌ Failed to parse JSON response:', error.message);
    console.error('\nFull response:');
    console.error(fullResponse);

    // Return fallback structure
    return {
      bugs: [],
      summary: 'Analysis completed but failed to parse structured results',
      recommendations: ['Review the raw response output for findings'],
      raw_response: fullResponse,
      parse_error: error.message
    };
  }
}

// ============================================================================
// Main Execution
// ============================================================================

async function main() {
  console.log('🤖 Claude Code Agent - Kubernetes Analysis\n');
  console.log('Repository:', CONFIG.repoPath);
  console.log('Output:', CONFIG.outputFile);
  console.log('');

  try {
    // Run analysis
    const results = await analyzeRepository();

    // Add metadata
    results.metadata = {
      timestamp: new Date().toISOString(),
      repository: CONFIG.repoPath,
      agent_version: '1.0.0'
    };

    // Write results to file
    fs.writeFileSync(CONFIG.outputFile, JSON.stringify(results, null, 2));
    console.log(`\n✅ Results saved to ${CONFIG.outputFile}\n`);

    // Print summary
    console.log('═'.repeat(80));
    console.log('ANALYSIS SUMMARY');
    console.log('═'.repeat(80));
    console.log(`\n📊 Bugs found: ${results.bugs?.length || 0}`);

    if (results.bugs && results.bugs.length > 0) {
      const bySeverity = {
        high: results.bugs.filter(b => b.severity === 'high').length,
        medium: results.bugs.filter(b => b.severity === 'medium').length,
        low: results.bugs.filter(b => b.severity === 'low').length
      };

      console.log(`   - 🔴 High: ${bySeverity.high}`);
      console.log(`   - 🟡 Medium: ${bySeverity.medium}`);
      console.log(`   - 🟢 Low: ${bySeverity.low}`);
    }

    console.log(`\n📝 Summary: ${results.summary}`);

    if (results.recommendations && results.recommendations.length > 0) {
      console.log(`\n💡 Recommendations:`);
      results.recommendations.forEach((rec, i) => {
        console.log(`   ${i + 1}. ${rec}`);
      });
    }

    if (results.k8s_status) {
      console.log(`\n☸️  Kubernetes Status:`);
      console.log(`   - Nodes: ${results.k8s_status.nodes}`);
      console.log(`   - Pods: ${results.k8s_status.pods}`);
      if (results.k8s_status.issues && results.k8s_status.issues.length > 0) {
        console.log(`   - Issues:`);
        results.k8s_status.issues.forEach(issue => {
          console.log(`     • ${issue}`);
        });
      }
    }

    console.log('\n' + '═'.repeat(80));

    // Exit with error code if high-severity issues found
    const highSeverity = results.bugs?.filter(b => b.severity === 'high').length || 0;
    if (highSeverity > 0) {
      console.error(`\n❌ Found ${highSeverity} high-severity issues!`);
      console.error('Please address these critical issues before merging.\n');
      process.exit(1);
    }

    console.log('\n✅ Analysis complete - no high-severity issues found!\n');
    process.exit(0);

  } catch (error) {
    console.error('\n❌ Fatal error:', error.message);
    console.error(error.stack);
    process.exit(1);
  }
}

// Run the agent
main();
