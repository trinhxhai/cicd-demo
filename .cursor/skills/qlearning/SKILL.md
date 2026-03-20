---
name: qlearning
description: Runs the qlearning flow for progressive topic learning with persistent notes and Q&A history. Use when the user says "using qlearning flow", asks to follow qlearning, or wants topic-based study notes logged in a structured topic file.
---

# Qlearning Flow

Follow this workflow to teach a topic progressively while maintaining a structured topic file.

## Source of truth

- Read `docs/learning/learning-file.md` first.
- Use [topic-template.md](topic-template.md) when creating a new topic file.

## Trigger phrase

Treat these as strong activation signals:

- `using qlearning flow to ...`
- `follow qlearning flow ...`
- `use qlearning ...`

## Workflow on each request

1. Read `docs/learning/learning-file.md`.
2. Determine the topic file path.
   - If user provides path, use it.
   - If missing, suggest a file in `docs/learning/topics/`.
3. If topic file does not exist, create it from [topic-template.md](topic-template.md).
4. Answer the question clearly and practically.
5. Update the topic file after answering.
6. Preserve prior history unless it is incorrect.

## Required topic file sections

Ensure the topic file always contains:

- Topic
- Current Understanding
- Questions Asked
- Q&A Log
- Key Concepts
- Examples
- Misconceptions Corrected
- Open Questions / Next Questions
- Revision History

## Q&A log format (mandatory)

Use this exact shape:

```markdown
### Q: <my question>
A: <your answer>
- Confidence: <low|medium|high>
- Reasoning: <short explanation of why this answer is correct>
- Related concepts: <comma-separated terms>
```

## Current Understanding rules

Treat `Current Understanding` as the main evolving knowledge body (not a short summary). Keep this internal structure:

- Foundations
- Detailed Mechanics
- My Interest Focus
- Gaps / Uncertainties

For every question:

- Update `Current Understanding`, including small follow-ups.
- Expand detail rather than compressing.
- Keep prior knowledge and refine wording when a better explanation appears.
- Add concrete mini-examples when useful.

## Update rules

- Append new Q&A entries; do not overwrite previous entries.
- Expand/refine `Current Understanding` each turn.
- Add 1-3 useful next questions when relevant.
- Mark uncertainty honestly with confidence and what to verify.
- Prefer concrete examples over abstract explanations.

## Style

- Keep answers concise and structured.
- Use step-by-step bullets for workflows.
- Keep terminology consistent.
- In topic files, prioritize depth in `Current Understanding`.
