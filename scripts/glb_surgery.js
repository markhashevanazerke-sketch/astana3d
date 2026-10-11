// Surgery on polygon_mini_free.glb: remove triangles (by index) whose world
// centroid falls inside a static-vehicle box. Vertices/attributes are kept
// untouched; only the index arrays are rewritten. Output: a new .glb file.
//
// World transform of the island in the game:  world = model * 3 + (6.3, 26.25, 13.19)
const fs = require('fs');
const SRC = 'C:/Users/Леново/kazakh-3d/godot/assets/polygon_mini_free.glb';
const OUT = 'C:/Users/Леново/kazakh-3d/godot/assets/polygon_mini_free_clean.glb';
const SCALE = 3.0;
const OFF = [6.3, 26.25, 13.19];

// World-space XZ boxes of the baked-in parked vehicles (Y is ignored: the
// whole car column is removed — roof, body, wheels).
const BOXES = [
	['lot_van_ne', 11.5, -14.5, 16.5, -10.0],
	['lot_blue', 5.0, -11.0, 10.0, -6.5],
	['lot_white', 1.5, -6.0, 6.0, -2.0],
	['lot_orange', 7.5, -4.0, 12.5, 0.5],
	['lot_yellow_w', -5.0, -2.5, -0.5, 1.5],
	['lot_van_sw', -4.5, 0.0, -1.5, 3.0],
	['plaza_red_car', -26.5, 25.0, -24.0, 27.5],
	['taxi_w_road', -6.0, 37.0, -2.5, 43.0],
	['dark_w_pave', 0.8, 35.0, 4.0, 38.5],
	['blue_main_road', 4.8, 59.5, 7.5, 63.0],
	['dark_e_pave_1', 12.0, 60.0, 15.5, 63.0],
	['blue_e_pave', 16.5, 59.0, 19.5, 62.5],
	['dark_e_pave_2', 17.0, 39.5, 20.5, 42.5],
].map(([name, x0, z0, x1, z1]) => ({
	name,
	// converted to model space
	mx0: (x0 - OFF[0]) / SCALE, mz0: (z0 - OFF[2]) / SCALE,
	mx1: (x1 - OFF[0]) / SCALE, mz1: (z1 - OFF[2]) / SCALE,
}));

function toWorld(mx, my, mz) {
	// node "Sketchfab_model" carries a -90 deg X rotation: (x, y, z) -> (x, z, -y)
	// then MiniCity: world = model * 3 + (6.3, 26.25, 13.19)
	return [mx * SCALE + OFF[0], my * SCALE + OFF[1], mz * SCALE + OFF[2]];
}

function worldXZ(cx, cy, cz) {
	const rx = cx; // rotation (x, y, z) -> (x, z, -y)
	const rz = -cy;
	return [rx * SCALE + OFF[0], rz * SCALE + OFF[2]];
}

function inAnyBox(wx, wz) {
	for (const b of BOXES) {
		// model-space test is cheaper: convert box bounds already done above
		const mx = (wx - OFF[0]) / SCALE;
		const mz = (wz - OFF[2]) / SCALE;
		if (mx >= b.mx0 && mx <= b.mx1 && mz >= b.mz0 && mz <= b.mz1) return b.name;
	}
	return null;
}

const buf = fs.readFileSync(SRC);
const jsonLen = buf.readUInt32LE(12);
const json = JSON.parse(buf.slice(20, 20 + jsonLen).toString('utf8'));
let binStart = 20 + jsonLen + 8; // +8: the BIN chunk header itself
while (binStart % 4 !== 0) binStart++;
const binData = buf.slice(binStart, binStart + json.buffers[0].byteLength);
console.log('binStart', binStart, 'binData', binData.length);

function readAccessorFloats(acc) {
	const bv = json.bufferViews[acc.bufferView];
	const base = (bv.byteOffset || 0) + (acc.byteOffset || 0);
	const itemSize = 12; // VEC3 float
	const stride = bv.byteStride || itemSize;
	const out = new Float32Array(acc.count * 3);
	for (let i = 0; i < acc.count; i++) {
		const b = base + i * stride;
		out[i * 3 + 0] = binData.readFloatLE(b);
		out[i * 3 + 1] = binData.readFloatLE(b + 4);
		out[i * 3 + 2] = binData.readFloatLE(b + 8);
	}
	return out;
}

function readAccessorUint32(acc) {
	const bv = json.bufferViews[acc.bufferView];
	const stride = bv.byteStride || 4;
	const base = (bv.byteOffset || 0) + (acc.byteOffset || 0);
	const out = new Uint32Array(acc.count);
	for (let i = 0; i < acc.count; i++) {
		out[i] = binData.readUInt32LE(base + i * stride);
	}
	return out;
}

function readAccessorNormals(acc) {
	const bv = json.bufferViews[acc.bufferView];
	const base = (bv.byteOffset || 0) + (acc.byteOffset || 0);
	const stride = bv.byteStride || 12;
	const out = new Float32Array(acc.count * 3);
	for (let i = 0; i < acc.count; i++) {
		const b = base + i * stride;
		out[i * 3 + 0] = binData.readFloatLE(b);
		out[i * 3 + 1] = binData.readFloatLE(b + 4);
		out[i * 3 + 2] = binData.readFloatLE(b + 8);
	}
	return out;
}

const report = [];
let totalRemoved = 0;
const newIndexData = []; // per mesh: Uint32Array of kept indices
let newIdxOffset = 0;
const origIdxBlockLen = json.bufferViews[0].byteLength;

json.meshes.forEach((m, mi) => {
	const p = m.primitives[0];
	if (p.indices === undefined) throw new Error('mesh ' + mi + ' has no indices');
	const idxAcc = json.accessors[p.indices];
	const posAcc = json.accessors[p.attributes.POSITION];
	const nrmAcc = json.accessors[p.attributes.NORMAL];
	const idx = readAccessorUint32(idxAcc);
	const pos = readAccessorFloats(posAcc);
	const nrm = readAccessorNormals(nrmAcc);
	const triCount = idx.length / 3;
	// pass 1: triangles inside a box, with world centroid Y and world up-normal.
	// world transform: rotation (x,y,z)->(x,z,-y), then *3 + offset.
	const members = new Array(triCount).fill(null);
	const boxFloorY = new Array(BOXES.length).fill(Infinity);
	for (let t = 0; t < triCount; t++) {
		const i0 = idx[t * 3], i1 = idx[t * 3 + 1], i2 = idx[t * 3 + 2];
		const cx = (pos[i0 * 3] + pos[i1 * 3] + pos[i2 * 3]) / 3.0;
		const cy = (pos[i0 * 3 + 1] + pos[i1 * 3 + 1] + pos[i2 * 3 + 1]) / 3.0;
		const cz = (pos[i0 * 3 + 2] + pos[i1 * 3 + 2] + pos[i2 * 3 + 2]) / 3.0;
		const wx = cx * SCALE + OFF[0];
		const wy = cz * SCALE + OFF[1]; // world Y = model Z (the root rotates X by -90 deg)
		const wz = -cy * SCALE + OFF[2];
		const ny = (nrm[i0 * 3 + 2] + nrm[i1 * 3 + 2] + nrm[i2 * 3 + 2]) / 3.0; // world up = model +Z
		for (let bi = 0; bi < BOXES.length; bi++) {
			const b = BOXES[bi];
			const mx = (wx - OFF[0]) / SCALE;
			const mz = (wz - OFF[2]) / SCALE;
			if (mx >= b.mx0 && mx <= b.mx1 && mz >= b.mz0 && mz <= b.mz1) {
				members[t] = { wy, ny, box: bi };
				if (ny > 0.9 && wy < boxFloorY[bi]) boxFloorY[bi] = wy;
				break;
			}
		}
	}
	// floor level per box: lowest upward-facing surface (the pavement top);
	// fall back to the lowest member if a box has no flat top (pure car).
	const kept = [];
	let removed = 0;
	const removedByBox = {};
	for (let t = 0; t < triCount; t++) {
		const mem = members[t];
		if (mem) {
			let floorY = boxFloorY[mem.box];
			if (!isFinite(floorY)) {
				// no upward-facing member: remove everything in the box
				removed++;
				removedByBox[BOXES[mem.box].name] = (removedByBox[BOXES[mem.box].name] || 0) + 1;
				continue;
			}
			const isPavement = mem.ny > 0.9 && Math.abs(mem.wy - floorY) < 0.15;
			if (isPavement) {
				kept.push(idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]);
			} else {
				removed++;
				removedByBox[BOXES[mem.box].name] = (removedByBox[BOXES[mem.box].name] || 0) + 1;
			}
			continue;
		}
		kept.push(idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]);
	}
	const keptArr = new Uint32Array(kept);
	idxAcc.count = kept.length;
	newIndexData.push(keptArr);
	report.push({ mesh: m.name, tris: triCount, removed, kept: keptArr.length / 3, byBox: removedByBox });
	totalRemoved += removed;
	newIdxOffset += keptArr.length * 4;
});

// Rebuild the index block (first bufferView holds all indices)
const idxBv = json.bufferViews[0];
const newIdxBlock = Buffer.alloc(newIdxOffset);
{
	let off = 0;
	for (const arr of newIndexData) {
		for (let i = 0; i < arr.length; i++) {
			newIdxBlock.writeUInt32LE(arr[i], off);
			off += 4;
		}
	}
}
// update accessor byteOffsets inside the index block
{
	let off = 0;
	json.meshes.forEach((m, mi) => {
		const acc = json.accessors[m.primitives[0].indices];
		const bv = json.bufferViews[acc.bufferView];
		if (!bv.byteOffset) { // index block only (bv[0])
			acc.byteOffset = off;
			off += newIndexData[mi].length * 4;
		}
	});
}
idxBv.byteLength = newIdxBlock.length;

// The index block shrank: every other bufferView's absolute byteOffset
// inside the buffer shifts up by the same delta.
var shift = origIdxBlockLen - newIdxBlock.length;
for (const bv of json.bufferViews) {
	if (bv.byteOffset) bv.byteOffset -= shift;
}

// New BIN = new index block + the rest of the original BIN (unchanged)
const rest = binData.slice(origIdxBlockLen);
let newBin = Buffer.concat([newIdxBlock, rest]);
const padLen = (4 - (newBin.length % 4)) % 4;
if (padLen > 0) newBin = Buffer.concat([newBin, Buffer.alloc(padLen)]);
json.buffers[0].byteLength = newBin.length;

// Serialize JSON chunk
let jsonStr = JSON.stringify(json);
while (jsonStr.length % 4 !== 0) jsonStr += ' ';
const jsonBuf = Buffer.from(jsonStr, 'utf8');

const total = 12 + 8 + jsonBuf.length + 8 + newBin.length;
const out = Buffer.alloc(total);
out.writeUInt32LE(0x46546c67, 0);
out.writeUInt32LE(2, 4);
out.writeUInt32LE(total, 8);
out.writeUInt32LE(jsonBuf.length, 12);
out.writeUInt32LE(0x4E4F534A, 16);
jsonBuf.copy(out, 20);
let o = 20 + jsonBuf.length;
out.writeUInt32LE(newBin.length, o);
out.writeUInt32LE(0x004E4942, o + 4);
newBin.copy(out, o + 8);
fs.writeFileSync(OUT, out);
// make the mtime unambiguously newer so Godot's importer re-imports it
const fut = new Date(Date.now() + 15000);
fs.utimesSync(OUT, fut, fut);
console.log('written', OUT, out.length, 'bytes');
console.log('total triangles removed:', totalRemoved);
for (const r of report) {
	console.log(`${r.mesh}: ${r.tris} -> ${r.kept} (removed ${r.removed})`, JSON.stringify(r.byBox));
}
