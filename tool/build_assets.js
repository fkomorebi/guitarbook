// 把 ComfyUI 原始输出裁剪/缩放成应用可用的图片资源。
//
//   node tool/build_assets.js
//
// 输入：.tools/raw/<name>.png（ComfyUI 原始输出）
// 输出：assets/images/<name>.webp（应用内使用）
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const ROOT = path.resolve(__dirname, '..');
const RAW_DIR = path.join(ROOT, '.tools', 'raw');
const OUT_DIR = path.join(ROOT, 'assets', 'images');

// 目标尺寸：hero 宽幅，工具插画方形，标志方形。
const TARGETS = {
  hero_home: { width: 1280, height: 720 },
  logo_app: { width: 512, height: 512 },
};
const DEFAULT_SQUARE = { width: 512, height: 512 };

// 逐素材的裁剪区域（相对原图宽高的比例），用于去掉生成图的多余留白。
// logo_app 原图 800x800，图形主体包围盒为 x 253..552 / y 172..614，
// 取以主体中心为心的正方形并留出约 6% 边距，避免圆形裁切时切掉笔画。
const CROPS = {
  logo_app: { left: 0.2088, top: 0.1975, width: 0.5875, height: 0.5875 },
};

async function build(name) {
  const src = path.join(RAW_DIR, `${name}.png`);
  if (!fs.existsSync(src)) {
    console.log(`跳过（缺少原始图） ${name}`);
    return;
  }
  const target = TARGETS[name] || DEFAULT_SQUARE;
  const out = path.join(OUT_DIR, `${name}.webp`);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  let pipeline = sharp(src);
  const crop = CROPS[name];
  if (crop) {
    const meta = await pipeline.metadata();
    const left = Math.round(crop.left * meta.width);
    const top = Math.round(crop.top * meta.height);
    pipeline = pipeline.extract({
      left,
      top,
      width: Math.round(crop.width * meta.width),
      height: Math.round(crop.height * meta.height),
    });
  }
  await pipeline
    .resize(target.width, target.height, { fit: 'cover', position: 'centre' })
    .webp({ quality: 88, effort: 6 })
    .toFile(out);
  const stat = fs.statSync(out);
  console.log(
    `输出 ${path.relative(ROOT, out)} ${target.width}x${target.height} ${(stat.size / 1024).toFixed(0)} KB`,
  );
}

async function main() {
  if (!fs.existsSync(RAW_DIR)) {
    console.log('没有 .tools/raw 目录，请先运行 tool/comfy_generate.js');
    return;
  }
  const names = fs
    .readdirSync(RAW_DIR)
    .filter((f) => f.endsWith('.png'))
    .map((f) => f.replace(/\.png$/, ''));
  for (const name of names) {
    await build(name);
  }
}

main().catch((err) => {
  console.error('出错：', err);
  process.exitCode = 1;
});
