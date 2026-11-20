# 3D worlds: what was verified on the phone

A summary of the phone runs behind textures, particles and models in PR #58 (2026-11-18/19, SGT-AL00, system-signed
`com.vera.probe.dyn`). The raw session reports (screenshots' pixel counts, hilog extracts, per-capture tables, about
200k lines of JSON) were kept out of the repository; this file is what they established. The spike that came before
them is `results/world-spike-phase0-2026-11-18.json`.

Pixel analysis was quantitative (changed pixels in a region, palette fits), not a visual or aesthetic sign-off.

## Textures (`scene.paint` material patterns)

- **Pass.** All eleven patterns render on box, sphere, cylinder, shape, hull, table and floor, and the three hand proofs
  (`world-textures-floor`, `-table`, `-parts-glow`) swap patterns and colours as written.
- A red/blue swap in textured glow spheres was found on the first run and fixed by giving the pixel map an explicit
  `RGBA_8888` source format (cache key `tex_v2`); the retest passed.
- Generation: three short prompts, the model used a pattern in all three. It sometimes picks `marble` where another
  pattern fits better.

## Particles (`scene.burst`, automatic sparks, dust, debris and smoke)

- **Accepted, with a bounded fallback.** Zero alpha is invisible, every burst expires back to the exact baseline, and
  particles cast no floor shadow while ordinary bodies still do.
- Over a sky (or stars, a trail, a glow halo) partial alpha composes incorrectly on the platform. There the renderer
  draws particles opaque, shrinking them with their alpha instead of fading them. Without a backdrop native alpha is used.
- Load: 300 awake bodies with 256 live particles hold callback medians of 56 to 57 fps over two fresh 34 s windows (an
  earlier build, before the particle path was tightened, gave 44). These are app callback rates, not GPU frame rates.
- The first burst after the world opens waits for the particle pool to be prepared (about 1.9 s cold, 0.3 s warm).
- Generation: the first three prompts failed on DNS. Three more after the network came back gave two programs that
  compiled and played (one used `scene.burst`) and one P0003 play failure.

## Models (`scene.model`, 36 GLB from `rawfile/models`)

- **Pass for visibility, removal and re-adding.** All 36 appear, disappear and come back pixel-identical. Source loads
  take 4 to 8 ms, imports 0 to 4 ms, and a second instance comes from the cache.
- A blocker found on the way (imported models invisible after an update) was a bad rawfile descriptor and was fixed.
- Generation: of three prompts, two produced programs and one of those used `scene.model`; one failed P0011 (the player
  hardly moved).

## Memory

Eight retire-and-reopen cycles on one page showed no large steady growth. That does not prove there is no leak.

## Not signed off

- Correct translucent colour over a backdrop (a platform composition defect; see the fallback above).
- How the scenes look, and every model in a generated scene on the device.
- How often the model chooses textures, particles and models on its own: the generation samples above are small.
