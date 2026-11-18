/**
 * Whether a request asks for 3D in so many words. Only then is anything built on a ui.World -- a game on the surface
 * route (AgentSurface), a section the agent writes (AgentCustom): dice, planets or a tower asked for without it are drawn
 * flat, since the person may well want them in 2D (user, 2026-11-16). Pure, so the host checks load it under node.
 *
 * "3D" counts on its own, not inside a longer Latin word ("3Dish") nor as dice notation ("3d6", "3 d20"), and right
 * before Chinese ("3D骰子"), where a word boundary would see none. "3-dimensional" counts as "three-dimensional" does.
 * A 3D printer is a machine, not a 3D picture: "3D-printed", "3D printer" and "3D printing" do not count.
 */
const ASKS_3D: RegExp = new RegExp('((^|[^A-Za-z0-9])3[ -]?d(?![A-Za-z0-9])(?![ -]?print)|(^|[^A-Za-z0-9])(3|three)[ -]?dimension\\w*|三维|立体)', 'i')

export function asksFor3D(prompt: string): boolean {
  return ASKS_3D.test(prompt)
}
