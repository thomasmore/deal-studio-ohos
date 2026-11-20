import { hash3, surfaceSeed } from './VeraNoise'

export const PARTICLE_KINDS: string[][] = [
  ['sparks', 'small fast bright flecks thrown outward, falling and quickly fading'],
  ['smoke', 'soft expanding puffs that drift outward and rise as they fade'],
  ['dust', 'low spreading clouds that slow quickly and settle as they fade'],
  ['debris', 'solid fragments thrown upward and outward, falling under gravity'],
  ['confetti', 'light colourful flakes that spread upward, then fall slowly through air drag'],
]

export const MAX_PARTICLES: number = 256
export const MAX_BURSTS: number = 16
export const DUST_MIN_SPEED: number = 3

export function particleKind(name: string): boolean {
  for (let entry of PARTICLE_KINDS) { if (entry[0] === name) { return true } }
  return false
}

export class ParticleBurst {
  kind: string = ''
  seed: number = 0
  origin: number[] = [0, 0, 0]
  color: string = ''
}

export class ParticleSpec {
  origin: number[] = [0, 0, 0]
  velocity: number[] = [0, 0, 0]
  acceleration: number[] = [0, -9.81, 0]
  drag: number = 0
  lifeS: number = 1
  sizeM: number = 0.05
  endSizeM: number = 0
  alpha: number = 1
  color: string = ''
  kind: string = ''
}

export class ParticlePose {
  position: number[] = [0, 0, 0]
  sizeM: number = 0
  alpha: number = 0
  alive: boolean = false
  color: string = ''
  kind: string = ''
}

export function burstParticles(kind: string, seed: number, origin: number[], color: string): ParticleSpec[] {
  if (!particleKind(kind) || origin.length < 3 || !Number.isFinite(origin[0]) ||
    !Number.isFinite(origin[1]) || !Number.isFinite(origin[2])) { return [] }
  let count = 24
  if (kind === 'smoke') { count = 18 }
  else if (kind === 'dust') { count = 22 }
  else if (kind === 'debris') { count = 28 }
  else if (kind === 'confetti') { count = 32 }
  let salt = surfaceSeed(kind) ^ (seed >>> 0)
  let particles: ParticleSpec[] = []
  for (let i = 0; i < count; i++) {
    let angle = hash3(i, 0, 0, salt) * 2 * Math.PI
    let speed = hash3(i, 1, 0, salt)
    let lift = hash3(i, 2, 0, salt)
    let life = hash3(i, 3, 0, salt)
    let size = hash3(i, 4, 0, salt)
    let p = new ParticleSpec()
    p.origin = origin.slice(0, 3)
    p.kind = kind
    p.color = color
    let radial = 1.2 + 2.4 * speed
    let upward = 0.5 + 2.5 * lift
    p.drag = 0.35
    p.lifeS = 0.35 + 0.55 * life
    p.sizeM = 0.025 + 0.025 * size
    if (kind === 'smoke') {
      radial = 0.15 + 0.35 * speed
      upward = 0.4 + 0.5 * lift
      p.acceleration = [0, 0.4, 0]
      p.drag = 0.75
      p.lifeS = 1.5 + 1.2 * life
      p.sizeM = 0.1 + 0.08 * size
      p.endSizeM = p.sizeM * 3
      p.alpha = 0.55
    } else if (kind === 'dust') {
      radial = 0.5 + 1.2 * speed
      upward = 0.1 + 0.5 * lift
      p.acceleration = [0, -0.8, 0]
      p.drag = 2.4
      p.lifeS = 0.6 + 0.8 * life
      p.sizeM = 0.055 + 0.045 * size
      p.endSizeM = p.sizeM * 2.4
      p.alpha = 0.5
    } else if (kind === 'debris') {
      radial = 0.8 + 2 * speed
      upward = 1 + 2.8 * lift
      p.drag = 0.2
      p.lifeS = 0.65 + 0.8 * life
      p.sizeM = 0.045 + 0.045 * size
      p.endSizeM = p.sizeM * 0.35
    } else if (kind === 'confetti') {
      radial = 0.5 + 1.5 * speed
      upward = 1.8 + 2 * lift
      p.acceleration = [0, -3.2, 0]
      p.drag = 2.8
      p.lifeS = 1.4 + 1.4 * life
      p.sizeM = 0.035 + 0.035 * size
      p.endSizeM = p.sizeM * 0.65
    }
    p.velocity = [Math.cos(angle) * radial, upward, Math.sin(angle) * radial]
    particles.push(p)
  }
  return particles
}

export function particlePose(p: ParticleSpec, ageS: number, floorY: number | null = null): ParticlePose {
  let pose = new ParticlePose()
  pose.color = p.color
  pose.kind = p.kind
  pose.position = p.origin.slice(0, 3)
  if (!Number.isFinite(p.lifeS) || p.lifeS <= 0) { return pose }
  let age = Number.isNaN(ageS) ? 0 : Math.max(0, ageS)
  let t = Math.min(p.lifeS, age)
  let progress = t / p.lifeS
  let drag = Number.isFinite(p.drag) ? Math.max(0, p.drag) : 0
  let travel = t
  let fall = t * t * 0.5
  if (drag > 0) {
    let u = drag * t
    if (u < 0.001) {
      travel = t * (1 - u / 2 + u * u / 6 - u * u * u / 24)
      fall = t * t * (0.5 - u / 6 + u * u / 24 - u * u * u / 120)
    } else {
      travel = (1 - Math.exp(-u)) / drag
      fall = (t - travel) / drag
    }
  }
  for (let axis = 0; axis < 3; axis++) {
    pose.position[axis] += p.velocity[axis] * travel + p.acceleration[axis] * fall
  }
  pose.alive = age < p.lifeS
  if (pose.alive) {
    pose.sizeM = Math.max(0, p.sizeM + (p.endSizeM - p.sizeM) * progress)
    let fade = 1 - progress
    if (p.kind === 'sparks') { fade *= fade }
    else if (p.kind === 'smoke' || p.kind === 'dust') { fade = Math.pow(fade, 1.5) }
    pose.alpha = Math.max(0, Math.min(1, p.alpha * fade))
  }
  if (floorY !== null && Number.isFinite(floorY)) {
    pose.position[1] = Math.max(pose.position[1], floorY + pose.sizeM * 0.5)
  }
  return pose
}

class ActiveBurst {
  particles: ParticleSpec[] = []
  ageS: number = 0
  fresh: boolean = true
}

export class ParticlePool {
  private bursts: ActiveBurst[] = []
  private floorY: number | null = null

  emit(request: ParticleBurst): void {
    let particles = burstParticles(request.kind, request.seed, request.origin, request.color)
    if (particles.length === 0) { return }
    let burst = new ActiveBurst()
    burst.particles = particles
    this.bursts.push(burst)
    while (this.bursts.length > MAX_BURSTS || this.particleCount() > MAX_PARTICLES) { this.bursts.shift() }
  }

  advance(dtS: number, floorY: number | null = null): void {
    this.floorY = floorY
    let dt = Number.isFinite(dtS) ? Math.max(0, dtS) : 0
    let active: ActiveBurst[] = []
    for (let burst of this.bursts) {
      if (burst.fresh) { burst.fresh = false }
      else { burst.ageS += dt }
      let living: ParticleSpec[] = []
      for (let p of burst.particles) { if (burst.ageS < p.lifeS) { living.push(p) } }
      burst.particles = living
      if (living.length > 0) { active.push(burst) }
    }
    this.bursts = active
  }

  poses(): ParticlePose[] {
    let poses: ParticlePose[] = []
    for (let burst of this.bursts) {
      for (let p of burst.particles) { poses.push(particlePose(p, burst.ageS, this.floorY)) }
    }
    return poses
  }

  needsFrames(): boolean { return this.bursts.length > 0 }

  clear(): void {
    this.bursts = []
    this.floorY = null
  }

  particleCount(): number {
    let count = 0
    for (let burst of this.bursts) { count += burst.particles.length }
    return count
  }

  burstCount(): number { return this.bursts.length }
}
