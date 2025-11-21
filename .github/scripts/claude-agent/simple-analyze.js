#!/usr/bin/env node
/**
 * Simplified Claude Code Agent
 * Makes direct API calls to analyze the codebase
 */

import { execSync } from 'child_process';
import * as fs from 'fs';

const CONFIG = {
  apiUrl: 'http://llm-proxy.keiretsu.ts.net/v1/messages',
  apiKey: 'sk-na',
  model: 'claude-sonnet-4-5',
  maxTokens: 4096,
  timeout: 300000
};

console.log('🤖 Simplified Claude Code Agent\n');

// Get repository summary
function getRepoSummary() {
  try {
    const files = execSync('find . -type f -name "*.yaml" -o -name "*.yml" | head -20', { encoding: 'utf-8' });
    const fileCount = execSync('find . -type f | wc -l', { encoding: 'utf-8' }).trim();
    return { files: files.trim().split('\n'), totalFiles: fileCount };
  } catch (error) {
    return { files: [], totalFiles: '0' };
  }
}

// Get Kubernetes cluster info
function getK8sInfo() {
  try {
    const pods = execSync('kubectl get pods -A --limit=10 2>&1', { encoding: 'utf-8', timeout: 10000 });
    const events = execSync('kubectl get events -A --sort-by=\'.lastTimestamp\' | tail -10 2>&1', { encoding: 'utf-8', timeout: 10000 });
    return { pods, events };
  } catch (error) {
    return { pods: 'Unable to query pods', events: 'Unable to query events' };
  }
}

async function analyze() {
  const repo = getRepoSummary();
  const k8s = getK8sInfo();

  const prompt = `Analyze this Kubernetes manifests repository for issues:

Repository: ${repo.totalFiles} total files
Sample files: ${repo.files.slice(0, 10).join(', ')}

Kubernetes Cluster Status:
${k8s.pods}

Recent Events:
${k8s.events}

Please provide a brief analysis in JSON format:
{
  "bugs": [{"file": "path", "line": "1", "description": "issue", "severity": "high|medium|low", "recommendation": "fix"}],
  "summary": "Brief overview",
  "recommendations": ["rec1", "rec2"],
  "k8s_status": {"nodes": "info", "pods": "info", "issues": ["issue1"]}
}`;

  console.log('Sending request to Claude API...\n');

  const response = await fetch(CONFIG.apiUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'anthropic-version': '2023-06-01',
      'x-api-key': CONFIG.apiKey
    },
    body: JSON.stringify({
      model: CONFIG.model,
      max_tokens: CONFIG.maxTokens,
      messages: [{
        role: 'user',
        content: prompt
      }]
    }),
    signal: AbortSignal.timeout(CONFIG.timeout)
  });

  if (!response.ok) {
    throw new Error(`API request failed: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  const text = data.content[0].text;

  console.log('Response received:\n', text.substring(0, 500), '...\n');

  // Extract JSON
  let jsonStr = text;
  if (text.includes('```json')) {
    jsonStr = text.split('```json')[1].split('```')[0].trim();
  } else if (text.includes('```')) {
    jsonStr = text.split('```')[1].split('```')[0].trim();
  }

  const results = JSON.parse(jsonStr);
  results.metadata = {
    timestamp: new Date().toISOString(),
    model: CONFIG.model
  };

  fs.writeFileSync('analysis-results.json', JSON.stringify(results, null, 2));
  console.log('✅ Analysis complete! Results saved to analysis-results.json');

  // Summary
  console.log('\n═══ SUMMARY ═══');
  console.log(`Bugs: ${results.bugs?.length || 0}`);
  console.log(`Summary: ${results.summary}`);
  if (results.k8s_status) {
    console.log(`K8s: ${results.k8s_status.pods}`);
  }

  return results;
}

analyze().catch(error => {
  console.error('❌ Error:', error.message);
  process.exit(1);
});
