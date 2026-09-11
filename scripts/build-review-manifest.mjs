import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { digest } from './install-review-skills.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
const skills = {};
function visit(base, relative = '') {
  const files = {};
  for (const entry of fs.readdirSync(path.join(base, relative), { withFileTypes: true }).sort((a,b) => a.name.localeCompare(b.name))) {
    const name = relative ? `${relative}/${entry.name}` : entry.name;
    if (entry.isDirectory()) Object.assign(files, visit(base, name));
    else if (entry.isFile()) files[name] = digest(path.join(base, name));
    else throw new Error('配套文件不能是链接');
  }
  return files;
}
for (const name of ['deepseek-consensus-review', 'deepseek-independent-review']) {
  const folder = path.join(root, 'bundled-skills', name);
  fs.writeFileSync(path.join(folder, 'VERSION'), `${version}\n`);
  skills[name] = visit(folder);
}
fs.writeFileSync(path.join(root, 'bundled-skills/manifest.json'), JSON.stringify({ schemaVersion: 1, version, skills }, null, 2) + '\n');
console.log(`已生成 ${version} 配套文件清单`);
