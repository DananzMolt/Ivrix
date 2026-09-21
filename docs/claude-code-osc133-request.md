# Upstream ask: OSC 133 input marking around the Claude Code composer

Draft of a feature request to file against `anthropics/claude-code`. Kept in
the repo so the terminal-side half and the ask that unblocks it stay together.

---

**Title:** Mark the composer's input with OSC 133 `B` so terminals can treat it as an edit buffer

**Body:**

### What I'm asking for

Emit `OSC 133;B` (`\x1b]133;B\x07`) at the point where the composer's editable
text begins, and `OSC 133;C` when it ends, on each redraw of the input box.

That's the whole request. No new protocol, no negotiation, no change to how
Claude Code handles keys.

### Why

OSC 133 is the semantic prompt marking already spoken by zsh, fish, bash, and
PowerShell shell-integration hooks, and understood by Ghostty, kitty, WezTerm,
iTerm2, and VS Code's terminal. The `B` mark means "user input starts here".

Terminals use it to tell a command line apart from the output around it, which
is what enables things like click-to-move-cursor, jump-to-previous-prompt, and
selecting a command without its prompt characters.

Claude Code draws its composer as ordinary program output, so to a terminal
every cell of it is indistinguishable from transcript text. The terminal can
see a box and a cursor; it cannot tell which cells you can edit.

### The concrete case

I maintain [Ivrix](https://github.com/DananzMolt/Ivrix), a Ghostty-based
terminal focused on Hebrew and RTL. It has a feature where selecting text at a
prompt and typing replaces the selection, the way any text editor behaves.
There is no terminal protocol for "replace the selection", so it's emulated:
move the cursor to the selection start with arrow keys, issue one forward
delete per selected position, then let the keystroke through as an insert.

That arithmetic needs to know which cells are input, because the count of
arrows has to match the count of editable positions. `B` marks are what supply
that. At a shell prompt it works in both English and Hebrew. In Claude Code it
is inert, because there are no marks to count against — and inert is the
correct outcome, since guessing where somebody else's input box begins and
issuing deletes based on the guess would corrupt what the user typed.

With `B` marks the same machinery would work in Claude Code with no
Claude-specific code on the terminal side, and the same is true for every other
OSC 133-aware terminal and every other feature they build on it.

### Why marks rather than the terminal guessing

A terminal could try to infer the composer region from the box-drawing
characters and cursor position. I deliberately did not, because a
misidentification edits the user's real input. A mark is an assertion by the
application that owns the buffer; a heuristic is the terminal betting on
someone else's layout, and it will eventually lose.

### Notes on the alternate screen

Claude Code takes the alternate screen (`CSI ?1049h`). Some terminals veto OSC
133 there on the theory that a full-screen application implements its own
editing.

That veto is a reasonable default and Ghostty ships it. It's also a proxy for
the real question. I've changed Ivrix so that selection editing keys off the
presence of input marks rather than off which screen is active
([commit](https://github.com/DananzMolt/ghostty/commit/f3f6bd8)): an
application that emits no marks is refused exactly as before, and one that
marks its input is trusted, on either screen. So on Ivrix this works the day
Claude Code emits the marks.

I don't know how other terminals would treat marks on the alternate screen, and
that's worth checking before anyone depends on it. But it's a terminal-side
question, and emitting the marks is correct regardless: it costs a handful of
bytes per redraw and is ignored by everything that doesn't care.

### Sketch

Around wherever the composer's editable region is rendered:

```
\x1b]133;B\x07   <the user's text>   \x1b]133;C\x07
```

Worth guarding behind the same check as any other escape output (not a dumb
terminal, not piped, `TERM` sane), and it should be safe to emit
unconditionally otherwise: terminals that don't understand OSC 133 ignore the
sequence.

### Prior art

- [OSC 133 / FinalTerm shell integration spec](https://iterm2.com/documentation-escape-codes.html)
- [Ghostty shell integration docs](https://ghostty.org/docs/features/shell-integration)
- [VS Code terminal shell integration](https://code.visualstudio.com/docs/terminal/shell-integration)
