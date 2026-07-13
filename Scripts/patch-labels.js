#!/usr/bin/env node
'use strict';

const OPEN_CODE_LABELS = {
  'glm-5': 'GLM-5',
  'glm-5.1': 'GLM-5.1',
  'glm-5.2': 'GLM-5.2',
  'kimi-k2.5': 'Kimi K2.5',
  'kimi-k2.6': 'Kimi K2.6',
  'kimi-k2.7-code': 'Kimi K2.7 Code',
  'mimo-v2-pro': 'MiMo V2 Pro',
  'mimo-v2-omni': 'MiMo V2 Omni',
  'mimo-v2.5-pro': 'MiMo V2.5 Pro',
  'mimo-v2.5': 'MiMo V2.5',
  'minimax-m2.5': 'MiniMax M2.5',
  'minimax-m2.7': 'MiniMax M2.7',
  'minimax-m3': 'MiniMax M3',
  'qwen3.5-plus': 'Qwen 3.5 Plus',
  'qwen3.6-plus': 'Qwen 3.6 Plus',
  'qwen3.7-plus': 'Qwen 3.7 Plus',
  'qwen3.7-max': 'Qwen 3.7 Max',
  'deepseek-v4-pro': 'DeepSeek V4 Pro',
  'deepseek-v4-flash': 'DeepSeek V4 Flash',
  'hy3-preview': 'HY3 Preview',
};

function labelFor(model) {
  if (model.startsWith('gpt-')) {
    return model
      .replace(/^gpt-/, '')
      .split('-')
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(' ');
  }
  return OPEN_CODE_LABELS[model] || model;
}

function groupPoints(points) {
  const grouped = new Map();
  for (const point of points) {
    const [model, effort] = point.split(':');
    if (!grouped.has(model)) {
      grouped.set(model, []);
    }
    grouped.get(model).push(effort);
  }
  return grouped;
}

function formatEfforts(efforts) {
  const meaningful = efforts.filter((effort) => effort !== 'none');
  if (meaningful.length === 0) {
    return '';
  }
  return ` (${meaningful.join(', ')})`;
}

function formatPointSection(title, pointsStr) {
  const points = pointsStr.split('\n').filter(Boolean);
  if (points.length === 0) {
    return [];
  }

  const lines = [title];
  for (const [model, efforts] of groupPoints(points)) {
    if (model.startsWith('gpt-')) {
      lines.push(`  - ${labelFor(model)} (${efforts.join(', ')})`);
    } else {
      lines.push(`  - ${labelFor(model)}${formatEfforts(efforts)}`);
    }
  }
  return lines;
}

function formatCatalog(activePointsStr, availablePointsStr) {
  const lines = ['=== Patch complete! ===', ''];
  lines.push(
    ...formatPointSection('Active slider (default):', activePointsStr),
    '',
    ...formatPointSection('Available in Settings (not on slider by default):', availablePointsStr)
  );
  return lines.join('\n').replace(/\n+$/u, '');
}

module.exports = {
  OPEN_CODE_LABELS,
  labelFor,
  formatCatalog,
};

if (require.main === module) {
  const command = process.argv[2];
  if (command === 'catalog') {
    process.stdout.write(`${formatCatalog(process.argv[3], process.argv[4])}\n`);
  } else if (command === 'label') {
    process.stdout.write(`${labelFor(process.argv[3])}\n`);
  } else {
    process.stderr.write('Usage: patch-labels.js catalog <active-points> <available-points>\n');
    process.exit(1);
  }
}
