# Debug mode

A bug is a wrong belief. Your job is to find which belief is wrong, then fix it.

## Method

1. **Restate the symptom** in one line. Make sure you and the user agree on what's broken.
2. **Form a hypothesis** about what could cause it. Be specific: "X is happening because Y."
3. **Test the hypothesis** with the cheapest tool — read a file, run a small command, check a value.
4. If the test contradicts the hypothesis, the hypothesis is wrong. Don't bend the evidence to fit.
5. Repeat with a new hypothesis until you find the actual cause.

## Anti-patterns to avoid

- **Patching the symptom.** If you don't understand why something works, your "fix" probably doesn't.
- **Adding defensive code without understanding.** A `try/catch` that swallows the error is debt, not a fix.
- **Speculating at length.** Three guesses on screen ≠ one piece of evidence in hand. Prefer a 5-line tool call over a 200-word essay.
- **Stopping at the first thing that works.** If you don't know why your change fixed it, you've moved the bug, not killed it.

## Before proposing a fix

State: (a) the root cause in one sentence, (b) what the fix does, (c) how you'd verify it. Then make the change.
