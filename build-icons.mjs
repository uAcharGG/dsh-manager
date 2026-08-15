// Build dsh-whale.ico from the shipped dsh favicon.svg (black whale, white in dark mode).
// Renders PNGs at the classic Windows icon sizes with sharp, then packs them
// into an ICO (Vista+ PNG-compressed entries, 256 -> 0 in the header).
import { createRequire } from 'node:module'
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
// Resolve sharp straight from the dsh checkout's pnpm store, since this
// launcher directory carries no dependencies of its own.
const require = createRequire('D:/AI/DeepSeekHarness/deepseek-harness/node_modules/.pnpm/sharp@0.35.3_@types+node@22.20.0/node_modules/sharp/package.json')
const sharp = require('sharp')

const svgPath = join(here, 'assets', 'dsh-whale.svg')
const icoPath = join(here, 'assets', 'dsh-whale.ico')
const sizes = [16, 24, 32, 48, 64, 128, 256]

const rendered = []
for (const size of sizes) {
  const data = await sharp(svgPath, { density: 300 })
    .resize(size, size)
    .png()
    .toBuffer()
  rendered.push({ size, data })
  console.log(`rendered ${size}x${size} (${data.length} bytes)`)
}

// ── ICO container ────────────────────────────────────────────────────────────
const header = Buffer.alloc(6)
header.writeUInt16LE(0, 0) // reserved
header.writeUInt16LE(1, 2) // type: icon
header.writeUInt16LE(rendered.length, 4)

const entries = []
const images = []
let offset = 6 + rendered.length * 16
for (const { size, data } of rendered) {
  const e = Buffer.alloc(16)
  e.writeUInt8(size >= 256 ? 0 : size, 0) // width (0 = 256)
  e.writeUInt8(size >= 256 ? 0 : size, 1) // height (0 = 256)
  e.writeUInt8(0, 2) // palette
  e.writeUInt8(0, 3) // reserved
  e.writeUInt16LE(1, 4) // color planes
  e.writeUInt16LE(32, 6) // bits per pixel
  e.writeUInt32LE(data.length, 8) // bytes in resource
  e.writeUInt32LE(offset, 12) // image offset
  entries.push(e)
  images.push(data)
  offset += data.length
}

writeFileSync(icoPath, Buffer.concat([header, ...entries, ...images]))
console.log(`wrote ${icoPath} (${offset} bytes)`)
