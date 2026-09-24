# personal.example/

A template for your own private notes. Copy it and fill it in:

```bash
cp -R personal.example personal
```

`personal/` is in `.gitignore`, so what you write there stays on your machine: serial numbers,
display UUIDs, the remaps stored on your keyboard, backups you took, anything about your
workplace. The public docs stay generic; `personal/` is where your machine's specifics go.

| File | Fill in |
|------|---------|
| `machine.md` | your hardware, displays and their layout, installed software |
| `keyboard.md` | your keyboard, and every remap stored in its firmware |
| `notes.md` | backups you took, permissions you granted, constraints of your environment |

An agent working on this repo reads `personal/` when it exists, so it knows your machine
without that knowledge ever reaching GitHub.
