# ANZIM

Anzim is an ant simulator.

## General architecture

The world is a 2D grid of cells which may contain one or more of the
following:

* nest: a nest will produce one ant per turn in which it can consume AF
  units of food; a nest dies if it drops below 0 units of food and there
  are no more ants;
* ant: an ant starts with AF health and will either move away from the
  nest (if not carrying food) or towards the nest (if carrying); at each
  step the ant consumes 1 unit of health and drops AT units of tracer;
  an ant dies if it drops below 0 units of health;
* food: food comes in packages of SF to BF food (by multiples of 2); it
  is picked up by ants and dropped in nests;
* tracer: tracer is dropped by ants and gets halved (round down) at every
  turn by evaporation;

Example parameters:
AF = 256	(ant food/health)
AT = 256	(ant tracer)
SF = 1024	(small food package size)
BF = 8192	(big food package size)

## Limitations and behaviour

A cell can contain at most 1 nest, 2 ants and 2 packages of food of each
size (see also the [Cannibal Rule][#cannibal-rule]).

An ant can carry at most one package of food, and will consume as much
of it as necessary to bring its health back to AF if it drops below
AF/2.

An ant carrying a package of food will pass it to an ant not carrying
food and with not more than half (round up) of its health. Picking up,
dropping (at the nest) or exchanging food costs one turn. One unit of
food can restore one unit of health. Eating food costs one turn, but in
a turn an ant can eat as much food as needed to restore health.

## Motion

Ants move randomly. Cells with higher tracer have higher probability.
Ants will prefer moving in the same direction they came from.
Specifically, each cell will have a weight d×(t+d), where t is the
amount of tracer in the cell and d is the direction weight, ranging from
1 (cell the ant came from) to 32 (cell opposite the one the ant came
from) in multiples of 2

Ants born at the nest will have d=1 for all cells. Ants that just picked
up/dropped/exchanged food will prefer going back (d=32 for the cell they
came from, d=1 for the opposite cell).

## Conflict resolution

### Motion

If more than two ants would move in the same cell, conflict are
resolved according to the following criteria:

1. ants staying in the same cell have precedence;
2. ants being generated have precedence;
3. ants moving in from up, down, left, right have precedence over ants
   moving in from diagonal neighbouring cells;
4. ants with food have higher precedence;
5. ants with lower health have higher precedence;
6. ants for which the destination cell has higher weight have higher
   precedence.
7. ants with a higher ID (‘younger’) have higher precedence;

Some clarifications:

* a nest will not generate an ant if there are two ants staying on it;
* conflict resolution is an iterative process, since ants taking
  precendence over other ants may force the latter to stay, which may
  force other ants to stay, etc;
* on the next turn, ants that had to stay put due to conflict resolution
  will choose their new destination again, without particular preference
  for the location where they failed to move to.

### Food package picking

If two ants are in the same cell, the lowest-health ant will pick the
biggest available food package, and the other ant will pick the next
available package (if any).

If both ants have the same health, and there is only one package of
maximum available capacity, priority follows these criteria:

1. the ant that was already in the cell has precedence;
2. the ant that moved into the cell from up, down, left, right has
   precedence over the ant that moved in from a diagonal neighbouring
   cell;
3. the ant for which the destination cell has higher weight have higher
   precedence.
4. ants with a higher ID (‘younger’) have higher precedence;

## Food generation

The world randomly generates food, using the following algorithm:

* each row and each column keeps track of the total number of food
  packages (regardless of size) not carried by ants;
* each row (resp. column) is weighted as 1 plus the total number of food
  packages in the row (resp. column) and its adjacent (next and
  previous) rows (resp. column);
* at every turn, a row, column pair (R, C) is randomly selected,
  following the respective weights;
* if all food package slots at (R, C) are full, or there is an ant in
  the cell, no food is generated for this turn; otherwise, a pair of
  random numbers (RX, CX) in (-1, 0, 1) are picked;
* if RX = CX = 0 then a food package is generated at cell (R, C),
  otherwise no food is generated for this turn;
* if a food package is generated, its size is randomly picked based on
  the available food package slots.

(Rationale: generate food at a rate of about 1 in 9 turns, food is
generated ‘close’ to existing food.)

(Question: should the generated package have a higher probability of
being ‘close’ in size to the existing/neighbouring packages?)

### Cannibal rule

Dead ants become packages with AF units of food. Dead ants do not count
towards the row/column total, and they cannot be generated during normal
food production. A cell can contain up to two dead ants.

(Rationale: no more than two ants can be dead in a cell, since a dying
ant would pick one of the dead ants as food package and consume it to
restore health.)

## Main loop

1. Food generation
2. Ant generation/motion/action choice
3. Conflict resolution
4. World update


