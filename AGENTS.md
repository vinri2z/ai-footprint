# Agent Instructions

Four rules for working in this repo.

## 1. Stop making silent assumptions

When you hit ambiguity, ask before assuming. Surface the tradeoffs explicitly instead of picking an interpretation and building on top of it. A wrong assumption made in line two becomes a debugging problem 200 lines later.

## 2. Stop over-engineering

Write the minimum code that solves the actual problem. No abstraction layers for single-use code. No clever patterns that make future maintenance harder. A config parser is a function, not a plugin architecture.

## 3. Stop causing collateral damage

Only touch files and functions directly related to the task. Don't reformat comments, rename variables, or adjust imports in files you weren't asked to change. If something adjacent looks wrong, flag it — don't silently fix it.

## 4. Stay honest about what you don't know

Say "I'm not sure" when you're not sure. Don't invent APIs, patterns, or library features. Flag uncertainty explicitly rather than producing confident output that's wrong.
