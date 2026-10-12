// How much the toolbar gives up so that what it shows fits in it.
//
// The steps used to be widths in the stylesheet: under 880 px the buttons lost their words, under 760 px the
// menus became one. Those numbers were a guess at how wide the words are, and the guess was low: with every word
// on, the Graph's toolbar needs about 1080 px in the font it was measured in, so between the two it ran out of
// its own box and over whatever was beside it. A width cannot be right for every font and every label. So the
// toolbar is measured instead: a step at a time, until it holds what it shows.
//
//   0  everything
//   1  the buttons that have an icon lose their words, and the note goes
//   2  Group, Density, Show, Expand and Fold become one menu, "View options"
//   3  the zoom figure and the name of the Timeline's range go; their buttons stay

export const FIT_MAX = 3;

/**
 * The first step at which the toolbar holds what it shows.
 * @param overflows (step) => boolean — puts the step on and says whether the toolbar still runs over
 * @returns 0…max; max when nothing more can be given up, whether or not it fits
 */
export function fitLevel(overflows, max = FIT_MAX) {
  for (let step = 0; step < max; step += 1) if (!overflows(step)) return step;
  return max;
}

/**
 * Does a row run over? Asked of the boxes, not of scrollWidth: a browser may leave the row's own end padding out
 * of scrollWidth, and the last button would sit against the edge before anything was said.
 * @param box   { right, padRight } of the row
 * @param ends  the right edge of each thing shown in it
 */
export function runsOver(box, ends) {
  const limit = box.right - (box.padRight ?? 0);
  return ends.some((right) => right > limit + 0.5);
}
