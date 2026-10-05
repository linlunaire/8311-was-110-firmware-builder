// Generate the theme and management resources; preserve their notices verbatim.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { transform } from 'lightningcss';
import { minifySync } from 'rolldown/utils';

const check = process.argv[2] === '--check';
if (process.argv.length > 3 || (process.argv[2] && !check)) throw new Error('Use --check or no argument');
const sourceDir = new URL('./', import.meta.url);
const outputDir = new URL('../../files/basic/www/luci-static/resources/', import.meta.url);
for (const [name, targetName] of [['8311-theme.css', '8311-theme.css'],
  ['8311-theme.js', '8311-theme.js'], ['8311-view.js', 'view/8311.js']]) {
  const source = fs.readFileSync(new URL(name, sourceDir), 'utf8').replaceAll('\r\n', '\n');
  const notice = source.match(/^\/\*[\s\S]*?\*\//)?.[0];
  if (!notice) throw new Error('Missing resource notice: ' + name);
  const input = source.slice(notice.length);
  let code;
  if (name.endsWith('.css')) {
    code = transform({ filename: name, code: Buffer.from(input), minify: true,
      targets: { chrome: 100 << 16, firefox: 100 << 16, safari: 15 << 16 } }).code.toString();
  } else {
    // LuCI templates call the management script's global functions directly.
    const result = minifySync(name, input, { module: false, compress: true, mangle: { toplevel: false } });
    if (result.errors.length) throw new Error('Resource minification failed: ' + name);
    code = result.code;
  }
  const output = notice + '\n' + code.trimEnd() + '\n';
  const target = new URL(targetName, outputDir);
  if (check) {
    const current = fs.readFileSync(target, 'utf8').replaceAll('\r\n', '\n');
    if (current !== output) throw new Error('Run npm run build --prefix tools/theme: ' + fileURLToPath(target));
  } else fs.writeFileSync(target, output);
  console.log(`${check ? 'Verified' : 'Built'} ${name}: ${Buffer.byteLength(source)} -> ${Buffer.byteLength(output)} bytes`);
}
