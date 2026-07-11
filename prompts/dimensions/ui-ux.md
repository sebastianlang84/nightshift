## Lens: UI-UX

Aim this scan at the user-facing surface — components, templates, views, forms, and the
copy inside them. This is largely a `convention`/`runtime` dimension: the standard is
THIS repo's own component library and patterns, and much of "does the flow work" needs a
browser nightshift does not have. Expect to ship findings flagged UNVERIFIED.

Hunt for:
- broken user flows: a link/route/action that targets a path no route defines, a submit
  handler wired to nothing, a step that cannot be reached or cannot be completed;
- accessibility gaps: an interactive element with no accessible name/label, an image with
  no alt, a control reachable only by mouse, contrast/roles the repo's own a11y pattern
  otherwise enforces;
- inconsistent component usage: a raw `<button>`/`<input>`/`<div>` where the repo has its
  OWN Button/Input/Modal component that siblings use — reinventing an existing primitive;
- missing states: a data view with no error, empty, or loading branch when sibling views
  render all three;
- unclear copy: a label/error/CTA that is ambiguous, misleading, or inconsistent with the
  repo's established wording for the same action.

Proof standard for this lens:
- A `convention` claim MUST cite THIS repo's own component or pattern as the standard:
  name the existing Button/Input/state component and 2-3 sibling files that use it, and
  cite the raw markup that bypasses it. No in-repo component to cite = generic taste = do
  not raise it.
- "The flow actually breaks" / "the layout is wrong" is `runtime`: nightshift does not
  render. Ship flagged UNVERIFIED, with a recipe telling the reviewer what to click.
- A missing route target is `static` — cite the route table and the dead reference.

Caution: do not import an external design system's rules. If the repo has no shared
component or documented a11y pattern for the thing you are flagging, the standard does
not exist here — drop it rather than assert generic UX dogma.
