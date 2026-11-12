// 从 ComfyUI 原始标志图生成各平台启动图标。
//
//   node tool/build_icons.js
//
// 输入：.tools/raw/logo_app.png（ComfyUI 原始输出，约 800x800）
// 输出：
//   android/app/src/main/res/mipmap-*/ic_launcher.png
//   ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png（由 Contents.json 决定）
//   web/favicon.png、web/icons/*.png
//   windows/runner/resources/app_icon.ico（内嵌 PNG 的手写 ICO 容器）
// 并同步更新 web/manifest.json 的 background_color / theme_color。
//
// 脚本可重复执行（幂等）：每次覆盖生成，输出只取决于原始图。
//
// 渲染方式：
//   - 标准图标：以「图形中心」为心取正方形裁切，边长由图形的最远点推算
//     （图形完整落在图标内切圆内，且不贴边），保留原图米白底纹理。
//   - maskable：按颜色距离把图形抠出来，缩到画布中央约 70%，
//     四周用品牌米白 #F7F5EF 填充，保证被裁切成圆形也不丢内容。
// 所有输出都是方形、居中、不透明（无 alpha 通道）的 PNG。
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const ROOT = path.resolve(__dirname, '..');
const SOURCE = path.join(ROOT, '.tools', 'raw', 'logo_app.png');

// 品牌色
const BRAND_BG = { r: 247, g: 245, b: 239 }; // #F7F5EF 暖米白
const THEME_COLOR = '#24695C'; // 深青绿
const BACKGROUND_COLOR = '#F7F5EF';

const ANDROID_ICONS = [
  ['android/app/src/main/res/mipmap-mdpi/ic_launcher.png', 48],
  ['android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72],
  ['android/app/src/main/res/mipmap-xhdpi/ic_launcher.png', 96],
  ['android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png', 144],
  ['android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', 192],
];

const WEB_ICONS = [
  ['web/favicon.png', 32, false],
  ['web/icons/Icon-192.png', 192, false],
  ['web/icons/Icon-512.png', 512, false],
  ['web/icons/Icon-maskable-192.png', 192, true],
  ['web/icons/Icon-maskable-512.png', 512, true],
];

const WINDOWS_ICO = 'windows/runner/resources/app_icon.ico';
const WINDOWS_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256];

const APPICON_CONTENTS = path.join(
  ROOT,
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
);
const WEB_MANIFEST = path.join(ROOT, 'web/manifest.json');

// maskable：图形占画布中央约 70%，四周用品牌米白填充
const MASKABLE_RATIO = 0.7;
// 标准图标：图形最远点到图形中心的距离 / 画布半径。
// 0.85 表示图形完整落在图标内切圆里（抗圆形裁切），且不贴边。
const STANDARD_SAFE_RATIO = 0.85;
// maskable 安全区：maskable 图标只保证中央 80% 直径的圆形区域可见
// （半径 = 0.4 × 画布边长；留一点余量取 0.39，避免最远点压在边界上）
const MASKABLE_SAFE_RATIO = 0.39;
// 抠图阈值：与背景色的通道差值之和，<= KEY_T0 视为背景，>= KEY_T1 视为图形
const KEY_T0 = 16;
const KEY_T1 = 120;

const written = []; // {path, width, height, bytes, hasAlpha, ok}

function rel(p) {
  return path.relative(ROOT, p).split(path.sep).join('/');
}

/** 读取 iOS Contents.json，解析出每个 filename 对应的像素尺寸 */
function readIosTargets() {
  const json = JSON.parse(fs.readFileSync(APPICON_CONTENTS, 'utf8'));
  const dir = path.dirname(APPICON_CONTENTS);
  const targets = [];
  for (const img of json.images || []) {
    if (!img.filename) continue;
    const base = parseFloat(String(img.size).split('x')[0]);
    const scale = parseFloat(String(img.scale).replace('x', ''));
    if (!Number.isFinite(base) || !Number.isFinite(scale)) continue;
    const px = Math.round(base * scale);
    targets.push({ file: path.join(dir, img.filename), size: px });
  }
  return targets;
}

/**
 * 读取原图像素，估算背景色，并按颜色距离生成图形 alpha 遮罩与包围盒。
 * 返回 null 表示整幅图没有可分离的图形（此时退化为整图缩放）。
 */
async function analyzeSource() {
  const { data, info } = await sharp(SOURCE)
    .flatten({ background: BRAND_BG })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  const at = (x, y) => {
    const i = (y * width + x) * channels;
    return [data[i], data[i + 1], data[i + 2]];
  };
  const corners = [at(1, 1), at(width - 2, 1), at(1, height - 2), at(width - 2, height - 2)];
  const bg = [0, 1, 2].map((ch) =>
    Math.round(corners.reduce((sum, c) => sum + c[ch], 0) / corners.length),
  );
  const alpha = Buffer.alloc(width * height);
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * channels;
      const d =
        Math.abs(data[i] - bg[0]) +
        Math.abs(data[i + 1] - bg[1]) +
        Math.abs(data[i + 2] - bg[2]);
      const a = Math.max(0, Math.min(1, (d - KEY_T0) / (KEY_T1 - KEY_T0)));
      alpha[y * width + x] = Math.round(a * 255);
      if (a > 0.5) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return { width, height, channels, data, bg, alpha, box: null };
  const box = {
    left: minX,
    top: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  };
  // 包围盒几乎铺满整图说明原图是满幅插画，无法分离背景
  box.usable =
    box.width < width * 0.98 && box.height < height * 0.98 && box.width > 4 && box.height > 4;
  if (box.usable) {
    // 图形中心（包围盒中心）到最远图形像素的距离：决定裁切边长与圆形安全区
    const cx = minX + (box.width - 1) / 2;
    const cy = minY + (box.height - 1) / 2;
    let maxDist = 0;
    for (let y = minY; y <= maxY; y++) {
      for (let x = minX; x <= maxX; x++) {
        if (alpha[y * width + x] < 128) continue;
        const d = Math.hypot(x - cx, y - cy);
        if (d > maxDist) maxDist = d;
      }
    }
    box.cx = cx;
    box.cy = cy;
    box.maxDist = maxDist;
  }
  return { width, height, channels, data, bg, alpha, box };
}

/** 标准图标：围绕图形取正方形裁切后缩放到目标尺寸 */
async function renderStandard(size, src) {
  const box = src.box;
  if (!box || !box.usable) {
    // 退路：整图居中裁成正方形
    return sharp(SOURCE)
      .resize(size, size, { fit: 'cover', position: 'centre' })
      .flatten({ background: BRAND_BG })
      .removeAlpha()
      .png({ compressionLevel: 9 })
      .toBuffer();
  }
  const side = Math.min(
    src.width,
    src.height,
    Math.ceil((2 * box.maxDist) / STANDARD_SAFE_RATIO),
  );
  const left = Math.max(0, Math.min(src.width - side, Math.round(box.cx - side / 2)));
  const top = Math.max(0, Math.min(src.height - side, Math.round(box.cy - side / 2)));
  return sharp(SOURCE)
    .extract({ left, top, width: side, height: side })
    .resize(size, size, { fit: 'cover', position: 'centre' })
    .flatten({ background: BRAND_BG })
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toBuffer();
}

/** 抠出图形（带 alpha），返回 PNG buffer 与像素尺寸 */
async function extractMark(src) {
  const box = src.box;
  if (!box || !box.usable) return null;
  const { width: bw, height: bh } = box;
  const rgba = Buffer.alloc(bw * bh * 4);
  for (let y = 0; y < bh; y++) {
    for (let x = 0; x < bw; x++) {
      const si = ((y + box.top) * src.width + (x + box.left)) * src.channels;
      const di = (y * bw + x) * 4;
      rgba[di] = src.data[si];
      rgba[di + 1] = src.data[si + 1];
      rgba[di + 2] = src.data[si + 2];
      rgba[di + 3] = src.alpha[(y + box.top) * src.width + (x + box.left)];
    }
  }
  const buffer = await sharp(rgba, { raw: { width: bw, height: bh, channels: 4 } })
    .png()
    .toBuffer();
  return { buffer, width: bw, height: bh };
}

/** maskable：图形缩到画布中央约 70%，四周填 #F7F5EF */
async function renderMaskable(size, src) {
  const inner = Math.floor(size * MASKABLE_RATIO);
  const mark = await extractMark(src);
  let graphic;
  let gw;
  let gh;
  if (mark) {
    // 缩放比同时受两条约束：
    //   1) 图形最长边不超过画布的 70%
    //   2) 图形最远点落在 maskable 安全圆（直径 80%）之内
    const maxDim = Math.max(mark.width, mark.height);
    const scale = Math.min(
      (size * MASKABLE_RATIO) / maxDim,
      (size * MASKABLE_SAFE_RATIO) / src.box.maxDist,
    );
    gw = Math.max(1, Math.round(mark.width * scale));
    gh = Math.max(1, Math.round(mark.height * scale));
    graphic = await sharp(mark.buffer)
      .resize(gw, gh, { fit: 'fill' })
      .flatten({ background: BRAND_BG })
      .removeAlpha()
      .png()
      .toBuffer();
  } else {
    // 退路：整图缩到 70%
    gw = inner;
    gh = inner;
    graphic = await sharp(SOURCE)
      .resize(gw, gh, { fit: 'cover', position: 'centre' })
      .flatten({ background: BRAND_BG })
      .removeAlpha()
      .png()
      .toBuffer();
  }
  return sharp({
    create: { width: size, height: size, channels: 4, background: { ...BRAND_BG, alpha: 1 } },
  })
    .composite([{ input: graphic, left: Math.floor((size - gw) / 2), top: Math.floor((size - gh) / 2) }])
    .flatten({ background: BRAND_BG })
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toBuffer();
}

/** 写出一个 PNG（保证 3 通道、不透明），并回读校验 */
async function writePng(buffer, outFile, expectSize) {
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  await sharp(buffer)
    .flatten({ background: BRAND_BG })
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toFile(outFile);
  const meta = await sharp(outFile).metadata();
  const bytes = fs.statSync(outFile).size;
  const ok =
    meta.width === expectSize && meta.height === expectSize && meta.hasAlpha === false;
  written.push({
    path: rel(outFile),
    width: meta.width,
    height: meta.height,
    bytes,
    hasAlpha: meta.hasAlpha === true,
    ok,
  });
  if (!ok) {
    throw new Error(
      `校验失败 ${rel(outFile)}: ${meta.width}x${meta.height} hasAlpha=${meta.hasAlpha}`,
    );
  }
  return meta;
}

/** 手写最小 ICO 容器（Vista+ 支持内嵌 PNG） */
function buildIco(images) {
  const count = images.length;
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // type = icon
  header.writeUInt16LE(count, 4); // image count
  const dir = Buffer.alloc(16 * count);
  let offset = 6 + 16 * count;
  images.forEach((img, i) => {
    const o = i * 16;
    const dim = img.size >= 256 ? 0 : img.size; // 256 写作 0
    dir.writeUInt8(dim, o); // width
    dir.writeUInt8(dim, o + 1); // height
    dir.writeUInt8(0, o + 2); // color count
    dir.writeUInt8(0, o + 3); // reserved
    dir.writeUInt16LE(1, o + 4); // planes
    dir.writeUInt16LE(32, o + 6); // bit count
    dir.writeUInt32LE(img.buffer.length, o + 8); // bytes in res
    dir.writeUInt32LE(offset, o + 12); // image offset
    offset += img.buffer.length;
  });
  return Buffer.concat([header, dir, ...images.map((i) => i.buffer)]);
}

/** 回读校验 ICO 结构 */
function verifyIco(file, expectedSizes) {
  const buf = fs.readFileSync(file);
  const reserved = buf.readUInt16LE(0);
  const type = buf.readUInt16LE(2);
  const count = buf.readUInt16LE(4);
  const sizes = [];
  for (let i = 0; i < count; i++) {
    const o = 6 + i * 16;
    const w = buf.readUInt8(o) || 256;
    const h = buf.readUInt8(o + 1) || 256;
    const bytesInRes = buf.readUInt32LE(o + 8);
    const imageOffset = buf.readUInt32LE(o + 12);
    const slice = buf.subarray(imageOffset, imageOffset + bytesInRes);
    const isPng =
      slice.length > 8 &&
      slice[0] === 0x89 &&
      slice[1] === 0x50 &&
      slice[2] === 0x4e &&
      slice[3] === 0x47;
    sizes.push({ w, h, bytesInRes, isPng });
  }
  const ok =
    reserved === 0 &&
    type === 1 &&
    count === expectedSizes.length &&
    sizes.every(
      (s, i) => s.w === expectedSizes[i] && s.h === expectedSizes[i] && s.isPng,
    );
  return { reserved, type, count, sizes, ok };
}

/** 更新 web/manifest.json 的配色字段，其余字段与换行风格保持不变 */
function updateWebManifest() {
  const raw = fs.readFileSync(WEB_MANIFEST, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const json = JSON.parse(raw);
  json.background_color = BACKGROUND_COLOR;
  json.theme_color = THEME_COLOR;
  const body = JSON.stringify(json, null, 4).replace(/\r?\n/g, eol);
  fs.writeFileSync(WEB_MANIFEST, body + (raw.endsWith('\n') ? eol : ''), 'utf8');
  return { background_color: json.background_color, theme_color: json.theme_color };
}

function fmtSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  return `${(bytes / 1024).toFixed(1)} KB`;
}

async function main() {
  if (!fs.existsSync(SOURCE)) {
    console.error(`缺少原始图：${rel(SOURCE)}`);
    console.error('请先运行 tool/comfy_generate.js 生成 logo_app.png，再运行本脚本。');
    process.exitCode = 1;
    return;
  }

  const srcMeta = await sharp(SOURCE).metadata();
  console.log(
    `原图 ${rel(SOURCE)} ${srcMeta.width}x${srcMeta.height} ` +
      `hasAlpha=${srcMeta.hasAlpha === true} ${fmtSize(fs.statSync(SOURCE).size)}`,
  );

  const src = await analyzeSource();
  let maskableRatio = MASKABLE_RATIO;
  if (src.box) {
    const cropSide = Math.min(
      src.width,
      src.height,
      Math.ceil((2 * src.box.maxDist) / STANDARD_SAFE_RATIO),
    );
    console.log(
      `图形包围盒 ${src.box.width}x${src.box.height} @ (${src.box.left},${src.box.top})，` +
        `背景估计 rgb(${src.bg.join(',')})，可分离=${src.box.usable}`,
    );
    const maskScale = Math.min(
      (512 * MASKABLE_RATIO) / Math.max(src.box.width, src.box.height),
      (512 * MASKABLE_SAFE_RATIO) / src.box.maxDist,
    );
    maskableRatio = (src.box.height * maskScale) / 512;
    console.log(
      `图形最远点距中心 ${src.box.maxDist.toFixed(1)}px → 标准图标裁切 ${cropSide}x${cropSide}` +
        `（图形约占画布高度 ${Math.round((src.box.height / cropSide) * 100)}%，` +
        `完整落在内切圆内），maskable 图形约占画布高度 ` +
        `${Math.round((src.box.height * maskScale / 512) * 100)}%`,
    );
  } else {
    console.log('未检测到图形像素，maskable 将退化为整图缩放。');
  }

  // Android
  for (const [file, size] of ANDROID_ICONS) {
    const buf = await renderStandard(size, src);
    await writePng(buf, path.join(ROOT, file), size);
  }

  // iOS
  for (const t of readIosTargets()) {
    const buf = await renderStandard(t.size, src);
    await writePng(buf, t.file, t.size);
  }

  // Web
  for (const [file, size, maskable] of WEB_ICONS) {
    const buf = maskable ? await renderMaskable(size, src) : await renderStandard(size, src);
    await writePng(buf, path.join(ROOT, file), size);
  }

  // Windows ICO
  const icoImages = [];
  for (const size of WINDOWS_ICO_SIZES) {
    icoImages.push({ size, buffer: await renderStandard(size, src) });
  }
  const icoFile = path.join(ROOT, WINDOWS_ICO);
  fs.mkdirSync(path.dirname(icoFile), { recursive: true });
  fs.writeFileSync(icoFile, buildIco(icoImages));
  const icoCheck = verifyIco(icoFile, WINDOWS_ICO_SIZES);
  if (!icoCheck.ok) {
    throw new Error(`ICO 校验失败：${JSON.stringify(icoCheck)}`);
  }
  written.push({
    path: rel(icoFile),
    width: 'multi',
    height: 'multi',
    bytes: fs.statSync(icoFile).size,
    hasAlpha: false,
    ok: true,
  });

  const manifest = updateWebManifest();

  // 清单输出
  const pad = (s, n) => String(s).padEnd(n, ' ');
  console.log('');
  console.log('生成清单');
  console.log(
    pad('文件', 64) + pad('尺寸', 12) + pad('体积', 12) + pad('alpha', 8) + '校验',
  );
  console.log('-'.repeat(108));
  let total = 0;
  for (const w of written) {
    total += w.bytes;
    console.log(
      pad(w.path, 64) +
        pad(`${w.width}x${w.height}`, 12) +
        pad(fmtSize(w.bytes), 12) +
        pad(w.hasAlpha ? 'yes' : 'no', 8) +
        (w.ok ? 'OK' : 'FAIL'),
    );
  }
  console.log('-'.repeat(108));
  console.log(
    `共 ${written.length} 个文件，总体积 ${fmtSize(total)}；` +
      `maskable 图形占比 ${Math.round(maskableRatio * 100)}%，` +
      `manifest background_color=${manifest.background_color} theme_color=${manifest.theme_color}`,
  );
  console.log(
    `ICO 内嵌尺寸：${icoCheck.sizes.map((s) => `${s.w}x${s.h}`).join(', ')}（全部为 PNG 负载）`,
  );
}

main().catch((err) => {
  console.error('出错：', err);
  process.exitCode = 1;
});
