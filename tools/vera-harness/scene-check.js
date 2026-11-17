// The maths of ui.Transform (VeraMotion.ets): pose arrays, interpolation, matrices.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const m = loadVera('VeraMotion')
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-6, (msg || '') + ' ' + a + ' vs ' + b)

assert.deepEqual(m.poseFromArray([]), [0, 0, 0, 0, 0, 0, 1, 1])
assert.deepEqual(m.poseFromArray([10, 20]), [10, 20, 0, 0, 0, 0, 1, 1])
assert.equal(m.poseFromArray([NaN, 5, Infinity]).join(), [0, 5, 0, 0, 0, 0, 1, 1].join())
assert.equal(m.poseFromArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 9]).length, 8)

const a = m.poseFromArray([0, 720]), b = m.poseFromArray([0, 810])
assert.equal(m.lerpPose(a, b, 0)[1], 720); assert.equal(m.lerpPose(a, b, 1)[1], 810); close(m.lerpPose(a, b, 0.5)[1], 765, 'a mid-way angle is by value')
assert.equal(m.lerpPose(a, b, 7)[1], 810); assert.equal(m.lerpPose(a, b, NaN)[1], 720)
assert.equal(m.easeOutCubic(0), 0); assert.equal(m.easeOutCubic(1), 1); assert.ok(m.easeOutCubic(0.5) > 0.5)

const I = m.identityMatrix()
assert.deepEqual(m.poseMatrix(m.poseFromArray([])), I)
// 90 degrees about Y takes +z (the front) to +x; about X takes +z to -y
let r = m.poseMatrix(m.poseFromArray([0, 90]))
close(r[2], 1, 'front -> +x'); close(r[10], 0, 'front no longer faces the viewer')
r = m.poseMatrix(m.poseFromArray([90, 0]))
close(r[6], -1, 'front -> -y about X')
// a chain is parent * child; identity is neutral
const p = m.poseMatrix(m.poseFromArray([30, 40, 50, 1, 2, 3, 1.5]))
assert.deepEqual(m.multiplyMatrices(I, p).map(x => +x.toFixed(9)), p.map(x => +x.toFixed(9)))

// a body that spins and travels is one pose: it turns about ITS OWN centre and is then moved, it does not orbit the origin
{
  for (const spin of [0, 37, 90, 211]) {
    const body = m.poseMatrix(m.poseFromArray([spin, spin * 2, spin / 3, 70, -20, 40]))
    close(body[3], 70, 'x stays where it was moved'); close(body[7], -20, 'y'); close(body[11], 40, 'z')
  }
}
// the pixel conversion scales the distances only, the column-major order puts the translation at 12..14 and perspective at 11
assert.deepEqual(m.poseToPixels([1, 2, 3, 4, 5, 6, 7, 8], 3), [1, 2, 3, 12, 15, 18, 7, 8])
const cm = m.columnMajor(m.poseMatrix(m.poseFromArray([0, 0, 0, 7, 8, 9])))
assert.deepEqual([cm[12], cm[13], cm[14], cm[15]], [7, 8, 9, 1])
assert.equal(m.columnMajor(m.perspectiveMatrix(400))[11], -1 / 400); assert.equal(m.columnMajor(m.perspectiveMatrix(0))[11], 0)
assert.equal(m.TRANSFORM_DISTANCE, 900)
console.log('scene-check ok')
