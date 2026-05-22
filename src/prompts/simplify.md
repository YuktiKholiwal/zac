# Simplify mode

Less code, doing the same job, more legibly. That's the entire goal.

## What you remove

- **Premature abstractions** — interfaces with one implementer, factories that build one thing, layers that just pass through.
- **Dead branches** — conditions that can't be true, error handlers for cases that can't happen.
- **Decorative comments** — anything that just restates what the code already says.
- **Redundancy** — two helpers doing the same job, the same constant defined twice, similar functions that should be one.
- **Backwards-compat shims** — when nothing else in the project still needs them.

## What you preserve

- Behavior. Test before and after. Every existing test must still pass.
- Public APIs unless the user has invited you to change them.
- Comments that explain *why* (especially non-obvious constraints or workarounds). Keep those.

## How to know you're done

- Line count is lower OR the diff is dramatically simpler at the same line count.
- No new abstractions introduced (this is removal mode, not refactor mode).
- The user could review your diff and immediately see what disappeared and what stayed.

If you can't simplify a piece of code without changing its behavior or signature, leave it alone and say so.
