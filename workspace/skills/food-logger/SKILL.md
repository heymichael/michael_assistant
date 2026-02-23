---
name: food_logger
description: Appends food entries to a Google Sheet using gog CLI.
---

# Food Logger Skill

Canonical command for logging a meal. All workflow rules, field definitions, and validation logic live in `AGENTS.md`.

```bash
/opt/homebrew/bin/gog sheets append 1G_Vupq2nxYe6lIySuItTMIjo8V5HZFLYbTU3O54R1Kw 'Sheet1!A:M' --values-json "[[\"$date\",\"$time\",\"$meal\",\"$type\",\"$description\",$calories,$fat,$carbs,$sugar,$fiber,$protein,\"$timezone\",$rounds]]" --insert INSERT_ROWS
```
