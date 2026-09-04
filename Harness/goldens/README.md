# Simulation goldens

Each file holds the digest of the simulation's own output — the stream of lit
segments it emits — for a fixed seed, movement mode, size and frame count.

These exist because the renderer comparison cannot detect a simulation
regression. `compare` feeds the identical frame data to both renderers, so a
simulation that produces wrong output makes both of them agree on it and
reports a match. The digest is the only check that looks at what the simulation
actually decided.

Regenerate ONLY when a change is intended to alter the animation, and look at
`isoharness sheet` output before you do. A digest that changes without you
meaning it is the regression this directory exists to catch.

    bash Harness/record-goldens.sh
