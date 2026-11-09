#!/usr/bin/env node
// Summarises a codelinter JSON report: prints counts, emits GitHub annotations, writes the job
// summary and exits non-zero when findings reach the HOS_LINT_FAIL_ON level (error, warn or none).
// Usage: HOS_LINT_ROOT=<repo root> HOS_LINT_FAIL_ON=error node lint-report.js <codelinter.json>

'use strict';

const fs = require('fs');
const path = require('path');

const MAX_ANNOTATIONS = 50;
const MAX_TABLE_ROWS = 100;

/**
 * Escapes text for the message part of a GitHub workflow command.
 * @param {string} text raw text
 * @returns {string} escaped text
 */
function escapeData(text) {
  return String(text).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

/**
 * Escapes text for a property value (file, title) of a GitHub workflow command.
 * @param {string} text raw text
 * @returns {string} escaped text
 */
function escapeProperty(text) {
  return escapeData(text).replace(/:/g, '%3A').replace(/,/g, '%2C');
}

/**
 * Escapes text for a Markdown table cell.
 * @param {string} text raw text
 * @returns {string} text safe inside a table cell
 */
function escapeCell(text) {
  return String(text).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
}

/**
 * Flattens the codelinter report into one record per finding, with paths relative to the root.
 * @param {Array<{filePath: string, messages: Array<object>}>} report parsed codelinter JSON
 * @param {string} root repository root
 * @returns {Array<{file: string, line: number, column: number, severity: string, message: string, rule: string}>}
 */
function flatten(report, root) {
  const findings = [];
  for (const entry of report) {
    const file = path.relative(root, entry.filePath).split(path.sep).join('/');
    for (const m of entry.messages || []) {
      findings.push({
        file,
        line: m.line || 1,
        column: m.column || 1,
        severity: m.severity || 'warn',
        message: m.message || '',
        rule: m.rule || 'codelinter',
      });
    }
  }
  return findings;
}

/**
 * Prints error and warning findings as GitHub annotations, capped per severity.
 * @param {Array<object>} findings flattened findings
 */
function annotate(findings) {
  const levels = { error: 'error', warn: 'warning' };
  const printed = { error: 0, warn: 0 };
  for (const f of findings) {
    const level = levels[f.severity];
    if (!level || printed[f.severity] >= MAX_ANNOTATIONS) {
      continue;
    }
    printed[f.severity] += 1;
    const props = `file=${escapeProperty(f.file)},line=${f.line},col=${f.column},title=${escapeProperty(f.rule)}`;
    console.log(`::${level} ${props}::${escapeData(f.message)}`);
  }
}

/**
 * Appends a Markdown summary of the findings to the GitHub job summary, when available.
 * @param {Array<object>} findings flattened findings
 * @param {{error: number, warn: number, suggestion: number}} counts findings per severity
 * @param {string} failOn severity level that fails the job
 */
function writeSummary(findings, counts, failOn) {
  const target = process.env.GITHUB_STEP_SUMMARY;
  if (!target) {
    return;
  }
  const lines = [
    '### codelinter',
    '',
    `Errors: **${counts.error}**, warnings: **${counts.warn}**, suggestions: **${counts.suggestion}** (fails on: ${failOn}).`,
    '',
  ];
  const shown = findings.filter((f) => f.severity !== 'suggestion').slice(0, MAX_TABLE_ROWS);
  if (shown.length > 0) {
    lines.push('| Severity | Location | Rule | Message |', '|---|---|---|---|');
    for (const f of shown) {
      lines.push(`| ${f.severity} | \`${escapeCell(f.file)}:${f.line}\` | ${escapeCell(f.rule)} | ${escapeCell(f.message)} |`);
    }
    lines.push('');
  }
  fs.appendFileSync(target, lines.join('\n') + '\n');
}

/**
 * Reads the report, reports the findings and sets the exit code.
 */
function main() {
  const reportPath = process.argv[2];
  if (!reportPath) {
    console.error('usage: node lint-report.js <codelinter.json>');
    process.exit(2);
  }
  const root = process.env.HOS_LINT_ROOT || process.cwd();
  const failOn = process.env.HOS_LINT_FAIL_ON || 'error';
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  const findings = flatten(Array.isArray(report) ? report : [], root);
  const counts = { error: 0, warn: 0, suggestion: 0 };
  for (const f of findings) {
    counts[f.severity] = (counts[f.severity] || 0) + 1;
  }
  annotate(findings);
  writeSummary(findings, counts, failOn);
  console.log(`codelinter: ${counts.error} error(s), ${counts.warn} warning(s), ${counts.suggestion} suggestion(s); fails on: ${failOn}`);
  const failed = (failOn === 'error' && counts.error > 0) || (failOn === 'warn' && counts.error + counts.warn > 0);
  process.exit(failed ? 1 : 0);
}

main();
