// 基于本机 ComfyUI（http://127.0.0.1:8188）批量生成应用素材。
//
// 用法：
//   node tool/comfy_generate.js                # 生成 tool/assets.json 中全部素材
//   node tool/comfy_generate.js --only hero    # 只生成 name 匹配的素材
//   node tool/comfy_generate.js --skip-existing
//
// 工作流模板：tool/comfyworkflow.json（由用户提供的 textToImg.json 转成 API 格式）。
// 每个素材会在模板基础上改写正向提示词（18:17）、宽高比（19）、随机种子（18:7）与保存前缀（9）。
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TEMPLATE = path.join(__dirname, 'comfyworkflow.json');
const SPEC = path.join(__dirname, 'assets.json');
const RAW_DIR = path.join(ROOT, '.tools', 'raw');
const SERVER = process.env.COMFY_URL || 'http://127.0.0.1:8188';

const args = process.argv.slice(2);
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null;
const skipExisting = args.includes('--skip-existing');

function clone(o) {
  return JSON.parse(JSON.stringify(o));
}

async function getJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}`);
  return res.json();
}

async function postJson(url, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`POST ${url} -> ${res.status}: ${text}`);
  return JSON.parse(text);
}

function buildPrompt(template, asset) {
  const p = clone(template);
  p['18:17'].inputs.value = asset.prompt;
  p['19'].inputs.aspect_ratio = asset.aspect || '1:1 (Square)';
  p['19'].inputs.megapixels = asset.megapixels ?? 1;
  p['18:7'].inputs.seed = asset.seed ?? Math.floor(Math.random() * 1e15);
  p['9'].inputs.filename_prefix = `guitarbook/${asset.name}`;
  return p;
}

async function waitForResult(promptId, timeoutMs) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const history = await getJson(`${SERVER}/history/${promptId}`);
    const entry = history[promptId];
    if (entry) {
      const status = entry.status || {};
      if (status.status_str === 'error') {
        throw new Error('生成失败: ' + JSON.stringify(status.messages));
      }
      const outputs = entry.outputs || {};
      const saved = outputs['9'] && outputs['9'].images && outputs['9'].images[0];
      if (saved) {
        let finalPrompt = '';
        for (const nodeOut of Object.values(outputs)) {
          if (nodeOut && typeof nodeOut.text === 'string' && nodeOut.text.length > 40) {
            finalPrompt = nodeOut.text;
          }
        }
        return { saved, finalPrompt };
      }
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error('等待生成结果超时');
}

async function download(saved, target) {
  const url = `${SERVER}/view?filename=${encodeURIComponent(saved.filename)}` +
    `&subfolder=${encodeURIComponent(saved.subfolder || '')}` +
    `&type=${encodeURIComponent(saved.type || 'output')}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`下载 ${url} -> ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, buf);
  return buf.length;
}

async function main() {
  const template = JSON.parse(fs.readFileSync(TEMPLATE, 'utf8'));
  const assets = JSON.parse(fs.readFileSync(SPEC, 'utf8'));
  const list = only ? assets.filter((a) => a.name.includes(only)) : assets;
  if (!list.length) {
    console.log('没有匹配的素材');
    return;
  }
  fs.mkdirSync(RAW_DIR, { recursive: true });

  const clientId = 'guitarbook-' + Date.now();
  for (const asset of list) {
    const target = path.join(RAW_DIR, `${asset.name}.png`);
    if (skipExisting && fs.existsSync(target)) {
      console.log(`跳过（已存在） ${asset.name}`);
      continue;
    }
    const prompt = buildPrompt(template, asset);
    const started = Date.now();
    process.stdout.write(`[生成] ${asset.name} … `);
    const queued = await postJson(`${SERVER}/prompt`, { prompt, client_id: clientId });
    const { saved, finalPrompt } = await waitForResult(queued.prompt_id, 900000);
    const bytes = await download(saved, target);
    const seconds = ((Date.now() - started) / 1000).toFixed(1);
    console.log(`完成 ${saved.filename} (${(bytes / 1024).toFixed(0)} KB, ${seconds}s)`);
    if (finalPrompt) {
      fs.writeFileSync(
        path.join(RAW_DIR, `${asset.name}.prompt.txt`),
        finalPrompt,
      );
    }
  }
}

main().catch((err) => {
  console.error('出错：', err.message);
  process.exitCode = 1;
});
