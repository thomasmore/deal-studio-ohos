// Rigid-body physics (Jolt) for the 3D world. Units: metres, seconds, kilograms; y is up;
// quaternions are ordered x, y, z, w. A body kind is 0 static, 1 dynamic, 2 kinematic.
// Bodies are named by a dense index that is reused after physRemove.

/**
 * Builds the world once; later calls do nothing. Returns the number of threads used (1 means the
 * caller alone), or 0 when this build has no physics (Jolt was not fetched): treat 0 as
 * "physics not available". maxBodies defaults to 2048, threads to min(3, cores - 1).
 */
export const physInit: (maxBodies?: number, threads?: number) => number
/** Removes every body and forgets pending contacts. Gravity and the bound stay. */
export const physReset: () => void
/** Gravity along y in m/s^2; normally -9.81. */
export const physSetGravity: (y: number) => void
/**
 * The world bound: a dynamic body below minY (m), or beyond +-halfX / +-halfZ (m), is put back at
 * its creation pose with zero velocity. The creation pose is the last physSetPose.
 */
export const physSetBound: (minY: number, halfX: number, halfZ: number) => void
/** A box of half-extents hx, hy, hz (m) at the origin. Returns its index, or -1. */
export const physAddBox: (hx: number, hy: number, hz: number, kind: number) => number
/** A sphere of radius r (m) at the origin. Returns its index, or -1. */
export const physAddSphere: (r: number, kind: number) => number
/** A cylinder with its axis along y, of radius r and half-height halfHeight (m), at the origin. Returns its index, or -1. */
export const physAddCylinder: (r: number, halfHeight: number, kind: number) => number
/** Removes a body and frees its index. */
export const physRemove: (i: number) => void
/** Teleports a body (m, quaternion x y z w) and wakes it; also the pose the world bound resets it to. */
export const physSetPose: (i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number) => void
/**
 * Mass in kg (dynamic bodies only), bounciness 0..1 and friction 0..1+. Bodies start with
 * restitution 0.3, friction 0.5, linear damping 0.05 and angular damping 0.3 (suits dice).
 */
export const physSetMaterial: (i: number, mass: number, restitution: number, friction: number) => void
/** Linear (m/s) and angular (rad/s, about the world axes) velocity; wakes the body and restarts the 8 s sleep cap. */
export const physSetVelocity: (i: number, vx: number, vy: number, vz: number, wx: number, wy: number, wz: number) => void
/**
 * Puts a dynamic body to sleep where it is (zero velocity): it stays put until something awake touches it, or
 * physSetVelocity / physSetPose wakes it. For bodies built resting on something, so a stack stands until hit.
 */
export const physSleep: (i: number) => void
/** Moves a kinematic body to the pose over dt seconds, so it pushes what it touches. Ignored for other kinds. */
export const physMoveKinematic: (i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number, dt: number) => void
/**
 * Advances the world by dt seconds in `substeps` collision steps (default 1). Applies the world
 * bound, and puts every dynamic body to sleep once 8 simulated seconds pass without a
 * physSetVelocity. Returns the milliseconds the step took.
 */
export const physStep: (dt: number, substeps?: number) => number
/**
 * physStep on a thread of its own: returns at once. Every other function waits for it to finish first, so the world
 * is never touched while it runs; physStepEnd waits for it and returns the milliseconds it took (0 if none ran).
 */
export const physStepBegin: (dt: number, substeps?: number) => void
export const physStepEnd: () => number
/**
 * Writes 8 floats per body that moved in the last step (awake, just fell asleep, or reset by the
 * bound) into out: index, px, py, pz, qx, qy, qz, qw. Returns the number of bodies written
 * (at most out.length / 8), or -1 if out is not a Float32Array.
 */
export const physReadAwake: (out: Float32Array) => number
/** Writes px, py, pz, qx, qy, qz, qw of one body into out (7 floats). Returns 1, or 0 if there is no such body. */
export const physReadPose: (i: number, out: Float32Array) => number
/**
 * Takes the contacts that began since the last call: 3 floats each, body a, body b, approach
 * speed (m/s, along the contact normal). Returns the count (at most out.length / 3); contacts
 * beyond that, or beyond an internal 1024, are dropped.
 */
export const physDrainContacts: (out: Float32Array) => number
/** How many dynamic bodies are awake (0 means the scene has settled). */
export const physAwakeDynamic: () => number
