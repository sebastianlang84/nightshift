# Correct a stage answer into valid JSON

An earlier stage was told to answer with one JSON object. Its answer, quoted below, holds an object
that does not parse. Return that object as valid JSON.

Rules:

- Reply with the JSON object only: no prose, no code fence, nothing before or after it.
- Correct the syntax only: quotes, escapes, commas, colons, brackets.
- Keep every key, every value and the wording of every string as the answer has them. Add nothing
  the answer does not state, and drop nothing it does.
- Leave out prose around the object. Never turn prose into JSON.
- Reply with exactly `NO_JSON` if the answer stops before its object ends, or if a broken part can
  be read in more than one way.

Everything you need is below; there is nothing to read or look up.
