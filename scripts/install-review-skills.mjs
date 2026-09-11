import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const checkout = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const names = ['deepseek-consensus-review', 'deepseek-independent-review'];
export const digest = file => createHash('sha256').update(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n')).digest('hex');
function safeFile(root, relative) {
  if (!/^[A-Za-z0-9_.\/-]+$/.test(relative) || relative.split('/').some(p => !p || p === '.' || p === '..')) throw new Error('配套文件路径无效');
  const result = path.resolve(root, relative);
  if (!result.startsWith(path.resolve(root) + path.sep)) throw new Error('配套文件路径越界');
  return result;
}
function noLinks(root) {
  if (!fs.existsSync(root)) return;
  const stat = fs.lstatSync(root);
  if (stat.isSymbolicLink()) throw new Error('安装目录包含链接，保留原目录，未替换');
  if (stat.isDirectory()) for (const name of fs.readdirSync(root)) noLinks(path.join(root, name));
}
export function installReviewSkills(skillsRoot, { check = false, packageRoot = path.join(checkout, 'bundled-skills') } = {}) {
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, 'manifest.json'), 'utf8'));
  if (manifest.schemaVersion !== 1 || !/^\d+\.\d+\.\d+$/.test(manifest.version) || Object.keys(manifest.skills).sort().join() !== [...names].sort().join()) throw new Error('配套安装清单无效');
  const root = path.resolve(skillsRoot);
  const reports = [];
  // Validate the complete package before changing either installed skill.
  for (const name of names) {
    const entries = Object.entries(manifest.skills[name]);
    if (!entries.some(([f]) => f === 'SKILL.md') || !entries.some(([f]) => f === 'scripts/session_binding.ps1')) throw new Error('配套安装清单缺少核心文件');
    for (const [relative, hash] of entries) {
      const file = safeFile(path.join(packageRoot, name), relative);
      if (!fs.existsSync(file) || digest(file) !== hash) throw new Error(`安装包不完整或文件校验失败：${name}/${relative}`);
    }
    const missing = entries.filter(([relative, hash]) => {
      const file = safeFile(path.join(root, name), relative);
      return !fs.existsSync(file) || digest(file) !== hash;
    }).map(([relative]) => relative);
    reports.push({ name, version: manifest.version, complete: !missing.length, missing });
  }
  if (check) return { ok: reports.every(r => r.complete), version: manifest.version, skills: reports };
  fs.mkdirSync(root, { recursive: true });
  if (fs.lstatSync(root).isSymbolicLink()) throw new Error('安装根目录不能是链接');
  for (const name of names) noLinks(path.join(root, name));
  const transaction = randomUUID();
  const staged = [], committed = [];
  try {
    for (const name of names) {
      const target = path.join(root, name), stage = path.join(root, `.c2c-stage-${transaction}-${name}`);
      const backup = path.join(root, `.c2c-backup-${transaction}-${name}`);
      fs.mkdirSync(stage);
      staged.push(stage);
      if (fs.existsSync(target)) fs.cpSync(target, stage, { recursive: true });
      for (const [relative, hash] of Object.entries(manifest.skills[name])) {
        const source = safeFile(path.join(packageRoot, name), relative), file = safeFile(stage, relative);
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.copyFileSync(source, file);
        if (digest(file) !== hash) throw new Error(`安装后校验失败：${name}/${relative}`);
      }
      const existed = fs.existsSync(target);
      if (existed) fs.renameSync(target, backup);
      try { fs.renameSync(stage, target); }
      catch (e) { if (existed) fs.renameSync(backup, target); throw e; }
      committed.push({ target, backup, existed });
    }
  } catch (error) {
    for (const item of committed.reverse()) {
      fs.renameSync(item.target, `${item.target}.failed-${transaction}`);
      if (item.existed) fs.renameSync(item.backup, item.target);
    }
    throw error;
  } finally {
    for (const stage of staged) if (fs.existsSync(stage)) fs.rmSync(stage, { recursive: true });
  }
  return { ok: true, version: manifest.version, skills: names, backups: committed.filter(x => x.existed).map(x => x.backup) };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const index = process.argv.indexOf('--skills-root');
    const root = index < 0 ? path.join(process.env.CODEX_HOME ?? path.join(os.homedir(), '.codex'), 'skills') : process.argv[index + 1];
    if (!root) throw new Error('缺少安装目录');
    const result = installReviewSkills(root, { check: process.argv.includes('--check') });
    console.log(JSON.stringify(result));
    if (!result.ok) process.exitCode = 1;
  } catch (error) { console.log(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; }
}
