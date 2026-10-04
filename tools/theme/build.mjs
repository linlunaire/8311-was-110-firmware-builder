// Generate only the two theme resources; preserve their notices verbatim.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { transform } from 'lightningcss';
import { minifySync } from 'rolldown/utils';

const check = process.argv[2] === '--check';
if (process.argv.length > 3 || (process.argv[2] && !check)) throw new Error('Use --check or no argument');
const sourceDir = new URL('./', import.meta.url);
const outputDir = new URL('../../files/basic/www/luci-static/resources/', import.meta.url);
for (const extension of ['css', 'js']) {
  const name = `8311-theme.${extension}`;
  const source = fs.readFileSync(new URL(name, sourceDir), 'utf8').replaceAll('\r\n', '\n');
  const notice = source.match(/^\/\*[\s\S]*?\*\//)?.[0];
  if (!notice) throw new Error('Missing theme notice: ' + name);
  const input = source.slice(notice.length);
  let code;
  if (extension === 'css') {
    code = transform({ filename: name, code: Buffer.from(input), minify: true,
      targets: { chrome: 100 << 16, firefox: 100 << 16, safari: 15 << 16 } }).code.toString();
  } else {
    const result = minifySync(name, input, { module: false, compress: true, mangle: true });
    if (result.errors.length) throw new Error('Theme minification failed: ' + name);
    code = result.code;
  }
  const output = notice + '\n' + code.trimEnd() + '\n';
  const target = new URL(name, outputDir);
  if (check) {
    const current = fs.readFileSync(target, 'utf8').replaceAll('\r\n', '\n');
    if (current !== output) throw new Error('Run npm run build --prefix tools/theme: ' + fileURLToPath(target));
  } else fs.writeFileSync(target, output);
  console.log(`${check ? 'Verified' : 'Built'} ${name}: ${Buffer.byteLength(source)} -> ${Buffer.byteLength(output)} bytes`);
}
